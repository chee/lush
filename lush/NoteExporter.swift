import Foundation
import CoreText
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
enum NoteExporter {

    // MARK: - Public entry point (macOS)

    #if os(macOS)
    private struct FetchedAsset: Sendable {
        let url: String
        let data: Data
        let name: String
    }

    static func exportAndSave(noteUrl: String, title: String, model: NotesModel) async {
        model.exportsInFlight += 1
        defer { model.exportsInFlight -= 1 }
        guard let snapshot = await model.spansSnapshot(for: noteUrl) else {
            model.status = "Couldn't export note"
            return
        }
        let spans = SpanNode.decodeList(snapshot.spansJson)

        var fetched: [FetchedAsset] = []
        var usedNames = Set<String>()
        for span in spans {
            guard case .block(let b) = span, b.isEmbedBlock, let assetUrl = b.embedUrl else { continue }
            guard let data = await model.assetBytes(assetUrl) else { continue }
            let info = await model.assetInfo(assetUrl)
            // names come from synced docs; strip anything path-like
            var name = (info?.name ?? "").components(separatedBy: "/").last ?? ""
            while name.hasPrefix(".") { name.removeFirst() }
            if name.isEmpty { name = "attachment" }
            let original = name
            var suffix = 2
            while usedNames.contains(name.lowercased()) {
                let ext = (original as NSString).pathExtension
                let base = (original as NSString).deletingPathExtension
                name = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
                suffix += 1
            }
            usedNames.insert(name.lowercased())
            fetched.append(FetchedAsset(url: assetUrl, data: data, name: name))
        }

        let safeName = title.isEmpty ? "note" : title

        if fetched.isEmpty {
            let html = buildHTML(title: title, spans: spans, assetResolver: .none)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.html]
            panel.nameFieldStringValue = safeName + ".html"
            panel.begin { response in
                guard response == .OK, let dest = panel.url else { return }
                Task.detached {
                    try? html.write(to: dest, atomically: true, encoding: .utf8)
                }
            }
        } else {
            var pathMap: [String: String] = [:]
            for asset in fetched { pathMap[asset.url] = "assets/\(asset.name)" }

            let html = buildHTML(title: title, spans: spans, assetResolver: .relativePaths(pathMap))

            let archive = await Task.detached { () -> URL? in
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lush-export-\(UUID().uuidString)", isDirectory: true)
                let assetsDir = tmp.appendingPathComponent("assets", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
                    try Data(html.utf8).write(to: tmp.appendingPathComponent("index.html"))
                    for asset in fetched {
                        try asset.data.write(to: assetsDir.appendingPathComponent(asset.name))
                    }
                } catch {
                    try? FileManager.default.removeItem(at: tmp)
                    return nil
                }

                let zipTmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lush-\(UUID().uuidString).zip")
                guard zipDirectory(tmp, to: zipTmp) else {
                    try? FileManager.default.removeItem(at: tmp)
                    try? FileManager.default.removeItem(at: zipTmp)
                    return nil
                }
                try? FileManager.default.removeItem(at: tmp)
                return zipTmp
            }.value
            guard let zipTmp = archive else {
                let alert = NSAlert()
                alert.messageText = "Export failed"
                alert.informativeText = "The note archive could not be created."
                alert.runModal()
                return
            }

            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "zip") ?? .data]
            panel.nameFieldStringValue = safeName + ".zip"
            panel.begin { response in
                let dest = response == .OK ? panel.url : nil
                Task.detached {
                    defer { try? FileManager.default.removeItem(at: zipTmp) }
                    guard let dest else { return }
                    let fm = FileManager.default
                    if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
                    try? fm.moveItem(at: zipTmp, to: dest)
                }
            }
        }
    }

    nonisolated private static func zipDirectory(_ dir: URL, to output: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", output.path, "."]
        process.currentDirectoryURL = dir
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
    #endif

    // MARK: - HTML builder

    /// `assetPaths` maps an asset url to where its file sits, so the pictures
    /// ride as references. Inlining their bytes is only for a document that
    /// has to stand on its own — see `htmlDocument`.
    static func htmlFragment(from spans: [SpanNode], assetPaths: [String: String] = [:]) -> String {
        htmlBody(
            from: spans,
            assetResolver: assetPaths.isEmpty ? .none : .relativePaths(assetPaths)
        )
    }

    static func htmlDocument(title: String, spans: [SpanNode], inlineImages: [String: Data] = [:]) -> String {
        buildHTML(
            title: title,
            spans: spans,
            assetResolver: inlineImages.isEmpty ? .none : .inlineImages(inlineImages)
        )
    }

    static func rtfData(from spans: [SpanNode]) throws -> Data {
        let attributed = documentAttributed(from: spans)
        return try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    // MARK: - Attributed document

    /// An asset packed for a rich text attachment: the file itself, and the
    /// size the note draws it at so a photo pastes at the size it looks
    /// rather than at its full pixel count.
    struct Attachment {
        let file: FileWrapper
        let size: CGSize?
    }

    /// The spans as a document rather than as the editor's view of one. The
    /// theme's ink and paper go — a note written in the dark should not paste
    /// as white text on white paper — list items pick up the marker text and
    /// the list structure Cocoa's rich text keeps them in, and any asset we
    /// were handed becomes an attachment holding its own file.
    static func documentAttributed(
        from spans: [SpanNode],
        attachments: [String: Attachment] = [:]
    ) -> NSAttributedString {
        let text = NSMutableAttributedString(
            attributedString: RichText.attributed(from: spans, cache: AssetCache())
        )
        attach(attachments, in: text)
        markLists(in: text)
        documentColors(in: text)
        return text
    }

    private static func attach(
        _ attachments: [String: Attachment],
        in text: NSMutableAttributedString
    ) {
        guard !attachments.isEmpty else { return }
        var edits: [(NSRange, NSTextAttachment)] = []
        text.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: text.length)
        ) { value, range, _ in
            guard value != nil,
                  let box = text.attribute(.amBlock, at: range.location, effectiveRange: nil) as? BlockBox,
                  let url = box.value.embedUrl,
                  let asset = attachments[url]
            else { return }
            let attachment = NSTextAttachment()
            attachment.fileWrapper = asset.file
            if let size = asset.size {
                attachment.bounds = CGRect(origin: .zero, size: RichText.fitted(size))
            }
            edits.append((range, attachment))
        }
        for (range, attachment) in edits {
            text.addAttribute(.attachment, value: attachment, range: range)
        }
    }

    private static let listMarkerFormats: [String: NSTextList.MarkerFormat] = [
        "unordered-list-item": .disc,
        "ordered-list-item": .decimal,
    ]

    private static func todoMarker(_ state: TodoState) -> String {
        switch state {
        case .open: return "\u{2610}"
        case .checked: return "\u{2611}"
        case .canceled: return "\u{2612}"
        case .pending: return "\u{25D0}"
        }
    }

    /// Cocoa keeps a list item's marker in the text and the list it belongs to
    /// in the paragraph style. The editor draws its own markers instead, so
    /// the attributed string it builds has neither and a list would arrive
    /// somewhere else as bare indented lines.
    private static func markLists(in text: NSMutableAttributedString) {
        let string = text.string as NSString
        var items: [(paragraph: NSRange, marker: String, lists: [NSTextList])] = []
        var ordinals: [Int: Int] = [:]
        var location = 0
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            guard paragraph.length > 0 else { break }
            location = NSMaxRange(paragraph)
            guard let box = text.attribute(
                .amBlock,
                at: paragraph.location,
                effectiveRange: nil
            ) as? BlockBox else { continue }
            let block = box.value
            let depth = block.parents.count
            guard listMarkerFormats[block.type] != nil || block.type == "todo-list-item" else {
                ordinals = [:]
                continue
            }
            ordinals = ordinals.filter { $0.key <= depth }
            let marker: String
            let format: NSTextList.MarkerFormat
            switch block.type {
            case "ordered-list-item":
                let ordinal = (ordinals[depth] ?? 0) + 1
                ordinals[depth] = ordinal
                marker = "\(ordinal)."
                format = .decimal
            case "todo-list-item":
                ordinals[depth] = 0
                marker = todoMarker(block.todoState)
                format = .init(marker)
            default:
                ordinals[depth] = 0
                marker = "\u{2022}"
                format = .disc
            }
            var lists = block.parents.map {
                NSTextList(markerFormat: listMarkerFormats[$0] ?? .disc, options: 0)
            }
            lists.append(NSTextList(markerFormat: format, options: 0))
            items.append((paragraph, marker, lists))
        }
        // back to front: an insert moves everything after it
        for item in items.reversed() {
            let style = (text.attribute(
                .paragraphStyle,
                at: item.paragraph.location,
                effectiveRange: nil
            ) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            style.textLists = item.lists
            text.addAttribute(.paragraphStyle, value: style, range: item.paragraph)
            var attributes = text.attributes(at: item.paragraph.location, effectiveRange: nil)
            attributes.removeValue(forKey: .link)
            attributes.removeValue(forKey: .attachment)
            text.insert(
                NSAttributedString(string: "\t\(item.marker)\t", attributes: attributes),
                at: item.paragraph.location
            )
        }
    }

    private static let documentLinkColor = PColor(rgb: 0x0563C1)
    private static let documentCodePaper = PColor(rgb: 0x000000, alpha: 0.06)

    /// The editor's colours are the theme's, and the theme moves with the
    /// window. A document keeps none of that: its text lands in whatever
    /// colour the thing reading it draws text in, and the few runs that do
    /// need a colour of their own carry one that works on paper.
    private static func documentColors(in text: NSMutableAttributedString) {
        let whole = NSRange(location: 0, length: text.length)
        text.removeAttribute(.foregroundColor, range: whole)
        text.removeAttribute(.backgroundColor, range: whole)
        var edits: [(NSRange, [NSAttributedString.Key: Any])] = []
        text.enumerateAttribute(.amHighlight, in: whole) { value, range, _ in
            guard let name = value as? String else { return }
            let pair = Highlight.documentPair(name)
            edits.append((range, [.foregroundColor: pair.ink, .backgroundColor: pair.paper]))
        }
        text.enumerateAttribute(.amCode, in: whole) { value, range, _ in
            guard value != nil else { return }
            edits.append((range, [.backgroundColor: documentCodePaper]))
        }
        // a PDF draws no link styling of its own, and the readers that do
        // draw their own only agree on blue and underlined
        text.enumerateAttribute(.link, in: whole) { value, range, _ in
            guard value != nil else { return }
            edits.append((range, [
                .foregroundColor: documentLinkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]))
        }
        for (range, attributes) in edits {
            text.addAttributes(attributes, range: range)
        }
    }

    enum ExportError: Error {
        case pdfContext
    }

    static func pdfData(from spans: [SpanNode], title: String) throws -> Data {
        let attributed = documentAttributed(from: spans)
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let inset = mediaBox.insetBy(dx: 54, dy: 54)
        let data = NSMutableData()
        let info = [kCGPDFContextTitle as String: title] as CFDictionary
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info)
        else { throw ExportError.pdfContext }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let path = CGPath(rect: inset, transform: nil)
        var location = 0
        repeat {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: location, length: 0),
                path,
                nil
            )
            CTFrameDraw(frame, context)
            context.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }
            location += visible.length
        } while location < attributed.length
        context.closePDF()
        return data as Data
    }

    private enum AssetResolver {
        case none
        case relativePaths([String: String])
        case inlineImages([String: Data])
    }

    private static func buildHTML(title: String, spans: [SpanNode], assetResolver: AssetResolver) -> String {
        let body = htmlBody(from: spans, assetResolver: assetResolver)
        let escaped = escape(title.isEmpty ? "Untitled" : title)
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escaped)</title>
        </head>
        <body>
        <article>
        \(body)</article>
        </body>
        </html>
        """
    }

    // MARK: - Segment rendering

    private enum Segment {
        case simple(BlockValue, [(String, [String: JSONValue])])
        case table([SpanNode])
        case columns([SpanNode])
    }

    private static func segmentize(_ spans: [SpanNode]) -> [Segment] {
        var segments: [Segment] = []
        var i = 0
        while i < spans.count {
            guard case .block(let b) = spans[i] else { i += 1; continue }
            if b.type == "table" || b.type == "columns" {
                let root = b.type
                var j = i + 1
                while j < spans.count {
                    if case .block(let child) = spans[j], child.parents.first != root { break }
                    j += 1
                }
                let slice = Array(spans[i..<j])
                segments.append(root == "table" ? .table(slice) : .columns(slice))
                i = j
                continue
            }
            var runs: [(String, [String: JSONValue])] = []
            var j = i + 1
            while j < spans.count {
                if case .block = spans[j] { break }
                if case .text(let t, let m) = spans[j] { runs.append((t, m)) }
                j += 1
            }
            if b.type == "code-block",
               case .simple(let previous, let previousRuns)? = segments.last,
               previous.type == "code-block",
               previous.codeLanguage == b.codeLanguage,
               previous.parents == b.parents {
                segments[segments.count - 1] = .simple(previous, previousRuns + [("\n", [:])] + runs)
            } else {
                segments.append(.simple(b, runs))
            }
            i = j
        }
        return segments
    }

    private static func htmlBody(from spans: [SpanNode], assetResolver: AssetResolver) -> String {
        let segments = segmentize(spans)
        var out = ""
        var openLists: [(tag: String, depth: Int)] = []
        var openBlockquotePath: [String]?

        func closeLists(to depth: Int = -1) {
            while let last = openLists.last, last.depth > depth {
                out += "</li></\(last.tag)>\n"
                openLists.removeLast()
            }
        }

        func enterBlockquote(_ path: [String]?) {
            guard path != openBlockquotePath else { return }
            closeLists()
            if openBlockquotePath != nil { out += "</blockquote>\n" }
            if path != nil { out += "<blockquote>\n" }
            openBlockquotePath = path
        }

        for segment in segments {
            switch segment {
            case .simple(let b, let runs):
                if b.type == "context" { continue }
                if b.type == "calendar-event" { continue }
                enterBlockquote(b.blockquotePath)
                if b.isEmbedBlock {
                    closeLists()
                    if b.type == "html", let source = b.htmlSource {
                        out += source + "\n"
                    } else if b.embedUrl != nil {
                        out += assetTag(block: b, assetResolver: assetResolver) + "\n"
                    }
                    continue
                }
                let content = runs.map { applyMarks(escape($0.0), marks: $0.1) }.joined()
                let isList = b.type == "unordered-list-item" || b.type == "ordered-list-item"
                    || b.type == "todo-list-item"
                let depth = b.parents.count
                let listTag = b.type == "ordered-list-item" ? "ol" : "ul"
                // A to-do exports as a disabled checkbox, so the list reads
                // the same in a browser as it does in the app.
                var item = content
                if b.type == "todo-list-item" {
                    let state = b.todoState
                    item = "<input type=\"checkbox\" disabled\(state == .checked ? " checked" : "")"
                        + "\(state == .pending ? " indeterminate" : "")> "
                        + (state == .canceled ? "<s>" + content + "</s>" : content)
                }
                if isList {
                    while let last = openLists.last, last.depth > depth {
                        out += "</li></\(last.tag)>\n"
                        openLists.removeLast()
                    }
                    if let last = openLists.last, last.depth == depth, last.tag != listTag {
                        out += "</li></\(last.tag)>\n"
                        openLists.removeLast()
                    }
                    if let last = openLists.last, last.depth == depth {
                        out += "</li>\n<li>\(item)"
                    } else {
                        out += "<\(listTag)>\n<li>\(item)"
                        openLists.append((tag: listTag, depth: depth))
                    }
                } else {
                    closeLists()
                    if b.blockquotePath != nil {
                        out += "<p>\(content)</p>\n"
                        continue
                    }
                    switch b.type {
                    case "heading":
                        let level = min(max(b.headingLevel ?? 1, 1), 6)
                        out += "<h\(level)>\(content)</h\(level)>\n"
                    case "code-block":
                        out += "<pre><code>\(content)</code></pre>\n"
                    default:
                        out += "<p>\(content)</p>\n"
                    }
                }
            case .table(let subSpans):
                enterBlockquote(nil)
                closeLists()
                out += tableHTML(RichText.parseTable(subSpans), assetResolver: assetResolver) + "\n"
            case .columns(let subSpans):
                enterBlockquote(nil)
                closeLists()
                let columns = RichText.parseColumns(subSpans)
                out += "<div class=\"columns\">\n"
                for col in columns {
                    out += "<div class=\"column\">\n"
                    out += htmlBody(from: col, assetResolver: assetResolver)
                    out += "</div>\n"
                }
                out += "</div>\n"
            }
        }
        closeLists()
        enterBlockquote(nil)
        return out
    }

    private static func applyMarks(_ text: String, marks: [String: JSONValue]) -> String {
        var out = text
        if case .bool(true)? = marks["code"] { out = "<code>\(out)</code>" }
        if case .bool(true)? = marks["strong"] { out = "<strong>\(out)</strong>" }
        if case .bool(true)? = marks["em"] { out = "<em>\(out)</em>" }
        if case .bool(true)? = marks["underline"] { out = "<u>\(out)</u>" }
        if case .bool(true)? = marks["strikethrough"] { out = "<s>\(out)</s>" }
        if case .bool(true)? = marks["superscript"] { out = "<sup>\(out)</sup>" }
        if case .bool(true)? = marks["subscript"] { out = "<sub>\(out)</sub>" }
        if let name = marks["highlight"]?.stringValue {
            out = "<mark data-color=\"\(escape(name))\">\(out)</mark>"
        }
        if let link = marks["link"]?.stringValue {
            out = "<a href=\"\(escape(link))\">\(out)</a>"
        }
        return out
    }

    private static func assetTag(block: BlockValue, assetResolver: AssetResolver) -> String {
        guard let url = block.embedUrl else { return "" }
        switch assetResolver {
        case .none:
            return "<p><em>[attachment]</em></p>"
        case .relativePaths(let pathMap):
            guard let path = pathMap[url] else { return "<p><em>[attachment]</em></p>" }
            let name = escape((path as NSString).lastPathComponent)
            let ext = (path as NSString).pathExtension.lowercased()
            let src = escape(path)
            if AssetCache.videoExtensions.contains(ext) {
                return "<video controls src=\"\(src)\"></video>"
            } else if AssetCache.audioExtensions.contains(ext) {
                return "<audio controls src=\"\(src)\"></audio>"
            } else if ["jpg", "jpeg", "png", "gif", "webp", "avif", "heic", "heif"].contains(ext) {
                let alt = escape(block.altText.isEmpty ? (path as NSString).lastPathComponent : block.altText)
                return "<img src=\"\(src)\" alt=\"\(alt)\">"
            } else {
                return "<a href=\"\(src)\">\(name)</a>"
            }
        case .inlineImages(let images):
            guard let data = images[url] else {
                return block.altText.isEmpty ? "" : "<p>\(escape(block.altText))</p>"
            }
            let mime = AssetCache.imageType(of: data)?.preferredMIMEType ?? "image/png"
            let src = "data:\(mime);base64,\(data.base64EncodedString())"
            return "<img src=\"\(src)\" alt=\"\(escape(block.altText))\">"
        }
    }

    private static func tableHTML(_ grid: TableGrid, assetResolver: AssetResolver) -> String {
        var out = "<table>\n"
        for (rowIdx, row) in grid.rows.enumerated() {
            out += "<tr>\n"
            let cellTag = grid.hasHeader && rowIdx == 0 ? "th" : "td"
            for cell in row {
                out += "<\(cellTag)>\(htmlBody(from: cell, assetResolver: assetResolver))</\(cellTag)>\n"
            }
            out += "</tr>\n"
        }
        out += "</table>"
        return out
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
