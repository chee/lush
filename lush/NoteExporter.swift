import Foundation
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
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

    static func htmlFragment(from spans: [SpanNode], inlineImages: [String: Data] = [:]) -> String {
        htmlBody(
            from: spans,
            assetResolver: inlineImages.isEmpty ? .none : .inlineImages(inlineImages)
        )
    }

    static func rtfData(from spans: [SpanNode]) throws -> Data {
        let attributed = RichText.attributed(from: spans, cache: AssetCache())
        return try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
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
            let src = "data:image/png;base64,\(data.base64EncodedString())"
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
