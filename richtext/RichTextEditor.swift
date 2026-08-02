import SwiftUI
import Observation
import UniformTypeIdentifiers
import AVFoundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct HtmlBlockHandle: Identifiable {
    let id = UUID()
    let box: BlockBox
    let html: String
}

enum EditorSheet: Identifiable {
    case audio(assetUrl: String, fileURL: URL, name: String)
    case video(fileURL: URL, name: String)
    case html(HtmlBlockHandle)
    case info(assetUrl: String, name: String, image: PImage?)
    case patchworkCreate

    var id: String {
        switch self {
        case .audio(let url, _, _): "audio-\(url)"
        case .video(let url, _): "video-\(url.path)"
        case .html(let handle): "html-\(handle.id)"
        case .info(let url, _, _): "info-\(url)"
        case .patchworkCreate: "patchwork-create"
        }
    }
}

@MainActor @Observable
final class EditorController {
    var currentStyleKey: String = "paragraph"
    var strongActive = false
    var emActive = false
    var codeActive = false
    var highlightActive: String?
    var recorderVisible = false
    var sheet: EditorSheet?
    #if os(iOS)
    var photoPickerVisible = false
    var filePickerVisible = false
    #endif
    @ObservationIgnored weak var core: EditorCore?

    func applyStyle(_ key: String) {
        core?.applyBlockStyle(BlockValue.fromStyleKey(key))
    }

    func toggleStrong() { core?.toggleMark("strong") }
    func toggleEm() { core?.toggleMark("em") }
    func toggleCode() { core?.toggleMark("code") }
    func applyHighlight(_ name: String?) { core?.setHighlight(name) }
    func insertTable() { core?.insertTable() }
    func insertHtmlBlock() { core?.insertHtmlBlock() }
    func insertPatchworkDoc() { sheet = .patchworkCreate }

    func insertPatchworkEmbed(url: String, tool: String?) {
        core?.insertPatchworkEmbed(url: url, tool: tool)
    }

    func attachImageFromPanel() {
        #if os(macOS)
        core?.attachFromPanel(imagesOnly: true)
        #else
        photoPickerVisible = true
        #endif
    }

    func attachFileFromPanel() {
        #if os(macOS)
        core?.attachFromPanel(imagesOnly: false)
        #else
        filePickerVisible = true
        #endif
    }

    func insertData(_ data: Data, name: String) {
        let ext = (name as NSString).pathExtension.lowercased()
        _ = core?.incomingData(
            data,
            fileExtension: ext.isEmpty ? "bin" : ext,
            suggestedName: name
        )
    }

    func insertRecording(data: Data, name: String) {
        core?.insertAsset(data: data, name: name, fileExtension: "m4a", mime: "audio/mp4")
    }

    func saveHtml(_ handle: HtmlBlockHandle, html: String) {
        core?.updateHtmlBlock(handle.box, html: html)
    }

    func replaceTrimmedAudio(assetUrl: String, data: Data, name: String) {
        core?.replaceAsset(
            oldUrl: assetUrl,
            data: data,
            name: name,
            fileExtension: "m4a",
            mime: "audio/mp4"
        )
    }

    func assetVision(_ url: String) async -> AssetVision? {
        guard let core else { return nil }
        return await core.model.assetVision(url)
    }
}

@MainActor
protocol EditorTextViewLike: AnyObject {
    var pStorage: NSTextStorage? { get }
    var pSelectedRange: NSRange { get set }
    var pTypingAttributes: [NSAttributedString.Key: Any] { get set }
    var pLayoutManager: NSLayoutManager? { get }
    var pTextContainer: NSTextContainer? { get }
    var pTextOrigin: CGPoint { get }
    var pSelf: PView { get }
    func pInsertText(_ text: String)
    func pReplace(_ range: NSRange, with attributed: NSAttributedString)
}

/// Draws bullet / number markers in the margin for list items. The markers
/// are pure decoration — they never exist in the text, so the automerge
/// round-trip can't be corrupted by them.
final class ListMarkerLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        let str = storage.string as NSString
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var location = charRange.location
        while location < NSMaxRange(charRange) {
            let paragraph = str.paragraphRange(for: NSRange(location: location, length: 0))
            if paragraph.length == 0 { break }
            defer { location = NSMaxRange(paragraph) }
            guard let box = storage.attribute(.amBlock, at: paragraph.location, effectiveRange: nil) as? BlockBox
            else { continue }
            let block = box.value
            let isBullet = block.type == "unordered-list-item"
            let isNumber = block.type == "ordered-list-item"
            guard isBullet || isNumber else { continue }

            let glyphIndex = glyphIndexForCharacter(at: paragraph.location)
            let lineRect = lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let baseline = origin.y + lineRect.minY + self.location(forGlyphAt: glyphIndex).y
            let indent = (storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
                as? NSParagraphStyle)?.firstLineHeadIndent ?? 20
            let itemFont = storage.attribute(.font, at: paragraph.location, effectiveRange: nil)
                as? PFont ?? PFont.systemFont(ofSize: RichText.bodySize)
            if isBullet {
                let diameter: CGFloat = 6.5
                let rect = CGRect(
                    x: origin.x + indent - diameter - 5,
                    y: baseline - itemFont.xHeight / 2 - diameter / 2,
                    width: diameter,
                    height: diameter
                )
                PColor.pSecondaryLabel.setFill()
                #if os(macOS)
                NSBezierPath(ovalIn: rect).fill()
                #else
                UIBezierPath(ovalIn: rect).fill()
                #endif
            } else {
                let marker = "\(ordinal(of: paragraph.location, in: storage, str: str))."
                let font = PFont.monospacedDigitSystemFont(ofSize: RichText.bodySize, weight: .regular)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: PColor.pSecondaryLabel,
                ]
                let size = marker.size(withAttributes: attrs)
                let point = CGPoint(
                    x: origin.x + indent - size.width - 5,
                    y: baseline - font.ascender
                )
                marker.draw(at: point, withAttributes: attrs)
            }
        }
    }

    /// 1-based position among the contiguous run of ordered items with the
    /// same nesting.
    private func ordinal(of location: Int, in storage: NSTextStorage, str: NSString) -> Int {
        guard let box = storage.attribute(.amBlock, at: location, effectiveRange: nil) as? BlockBox
        else { return 1 }
        let parents = box.value.parents
        var count = 1
        var cursor = location
        while cursor > 0 {
            let previous = str.paragraphRange(for: NSRange(location: cursor - 1, length: 0))
            guard previous.length > 0,
                  let prevBox = storage.attribute(.amBlock, at: previous.location, effectiveRange: nil) as? BlockBox,
                  prevBox.value.type == "ordered-list-item",
                  prevBox.value.parents == parents
            else { break }
            count += 1
            cursor = previous.location
        }
        return count
    }
}

@MainActor
final class EditorCore {
    weak var view: (any EditorTextViewLike)?
    let model: NotesModel
    let controller: EditorController
    var noteUrl: String

    private var saveTask: Task<Void, Never>?
    private var lastKnownJSON = ""
    private let cache = AssetCache()

    let inline = InlineViewManager()

    init(noteUrl: String, model: NotesModel, controller: EditorController) {
        self.noteUrl = noteUrl
        self.model = model
        self.controller = controller
        controller.core = self
        inline.core = self
        model.noteChanged = { [weak self] url in
            self?.remoteChanged(url)
        }
    }

    // MARK: loading

    func switchTo(_ url: String) {
        pushNow()
        noteUrl = url
        load()
    }

    func load() {
        let url = noteUrl
        Task { [weak self] in
            guard let self else { return }
            let json = await self.model.spansJSON(for: url)
            guard self.noteUrl == url else { return }
            let spans = SpanNode.decodeList(json)
            await self.fetchMissingAssets(in: spans)
            guard self.noteUrl == url else { return }
            self.apply(spans: spans)
        }
    }

    private func fetchMissingAssets(in spans: [SpanNode]) async {
        for node in spans {
            guard case .block(let block) = node,
                  block.isEmbedBlock,
                  let url = block.embedUrl,
                  url.hasPrefix("automerge:"),
                  cache.images[url] == nil, cache.names[url] == nil,
                  !cache.patchworkDocs.contains(url)
            else { continue }
            guard let data = await model.assetBytes(url) else {
                // present locally but not a file asset → a patchwork doc
                if let info = await model.assetInfo(url), info.mimeType.isEmpty {
                    cache.patchworkDocs.insert(url)
                }
                continue
            }
            if let image = PImage(data: data) {
                cache.images[url] = image
            } else {
                let info = await model.assetInfo(url)
                let name = info?.name.isEmpty == false ? info!.name : "attachment"
                cache.names[url] = name
                if AssetCache.kind(forName: name) == "video" {
                    await prepareVideo(url: url, name: name, data: data)
                }
            }
        }
    }

    func isPatchworkDoc(_ url: String) -> Bool {
        cache.patchworkDocs.contains(url)
    }

    func inlineVideoSize(for url: String) -> CGSize? {
        guard let thumb = cache.videoThumbs[url] else { return nil }
        return RichText.fitted(thumb.size)
    }

    func videoFileURL(for url: String) -> URL? {
        cache.fileURLs[url]
    }

    func insertPatchworkEmbed(url: String, tool: String?) {
        cache.patchworkDocs.insert(url)
        var block = BlockValue.embed(url: url)
        if let tool, !tool.isEmpty {
            block.attrs["tool"] = .string(tool)
        }
        insertBlockAttachment(RichText.embedAttachment(for: block, cache: cache))
        inline.setNeedsReconcile()
    }

    private func prepareVideo(url: String, name: String, data: Data) async {
        guard let fileURL = Self.mediaFile(for: url, name: name, data: data) else { return }
        cache.fileURLs[url] = fileURL
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 840, height: 680)
        if let (cgImage, _) = try? await generator.image(at: .init(seconds: 0.1, preferredTimescale: 600)) {
            #if os(macOS)
            let poster = NSImage(cgImage: cgImage, size: .zero)
            #else
            let poster = UIImage(cgImage: cgImage)
            #endif
            cache.videoThumbs[url] = PImage.playBadged(poster)
        }
    }

    static func mediaFile(for assetUrl: String, name: String, data: Data) -> URL? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AssetMedia", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = assetUrl.replacingOccurrences(of: "automerge:", with: "")
            .replacingOccurrences(of: "/", with: "_")
        let file = dir.appendingPathComponent("\(safe)-\(name)")
        if !FileManager.default.fileExists(atPath: file.path) {
            guard (try? data.write(to: file)) != nil else { return nil }
        }
        return file
    }

    private func apply(spans: [SpanNode]) {
        guard let view, let storage = view.pStorage else { return }
        let attributed = RichText.attributed(from: spans, cache: cache)
        let selection = view.pSelectedRange
        storage.setAttributedString(attributed)
        let location = min(selection.location, attributed.length)
        view.pSelectedRange = NSRange(location: location, length: 0)
        if attributed.length == 0 {
            // Notes-style: an empty note starts with a Title line.
            view.pTypingAttributes = RichText.attributes(block: .heading(level: 1), marks: [:])
        }
        lastKnownJSON = SpanNode.encodeList(RichText.spans(from: attributed))
        refreshFormattingState()
        inline.setNeedsReconcile()
    }

    private func remoteChanged(_ url: String) {
        guard url == noteUrl else { return }
        Task { [weak self] in
            guard let self else { return }
            let json = await self.model.spansJSON(for: url)
            guard self.noteUrl == url else { return }
            let spans = SpanNode.decodeList(json)
            await self.fetchMissingAssets(in: spans)
            guard self.noteUrl == url else { return }
            let canonical = SpanNode.encodeList(spans)
            if canonical != self.lastKnownJSON {
                self.apply(spans: spans)
            }
        }
    }

    // MARK: saving

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.pushNow()
        }
    }

    func pushNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let storage = view?.pStorage else { return }
        let typing = typingBlock()
        let spans = RichText.spans(from: storage, trailingBlock: typing.isAtomic ? nil : typing)
        let json = SpanNode.encodeList(spans)
        guard json != lastKnownJSON else { return }
        lastKnownJSON = json
        let url = noteUrl
        let title = RichText.title(from: spans)
        Task {
            await model.updateSpans(url, json: json)
            await model.updateTitleIfNeeded(url, title: title)
        }
    }

    // MARK: formatting

    func refreshFormattingState() {
        guard let view else { return }
        var typing = view.pTypingAttributes
        if typing[.amTableBox] != nil || typing[.attachment] != nil
            || (typing[.amBlock] as? BlockBox)?.value.isAtomic == true {
            // typing next to an attachment must never inherit its attributes,
            // or the typed text would vanish into the atomic block on save
            view.pTypingAttributes = RichText.attributes(block: .paragraph, marks: [:])
        } else if typing[.amDisplayOnly] != nil {
            typing.removeValue(forKey: .amDisplayOnly)
            view.pTypingAttributes = typing
        }
        let block = blockAtSelection()
        controller.currentStyleKey = block.styleKey
        let marks = marksAtSelection()
        controller.strongActive = marks["strong"] != nil
        controller.emActive = marks["em"] != nil
        controller.codeActive = marks["code"] != nil
        controller.highlightActive = marks["highlight"]?.stringValue
    }

    private func marksAtSelection() -> [String: JSONValue] {
        guard let view else { return [:] }
        let selection = view.pSelectedRange
        let block = blockAtSelection()
        if let storage = view.pStorage, storage.length > 0,
           selection.location > 0 || selection.length > 0 {
            let index = min(
                max(selection.location, 1) - (selection.length == 0 ? 1 : 0),
                storage.length - 1
            )
            return RichText.marks(
                from: storage.attributes(at: index, effectiveRange: nil),
                block: block
            )
        }
        return RichText.marks(from: view.pTypingAttributes, block: block)
    }

    func blockAtSelection() -> BlockValue {
        guard let view, let storage = view.pStorage else { return .paragraph }
        let selection = view.pSelectedRange
        if storage.length == 0 {
            return typingBlock()
        }
        let index = min(selection.location, storage.length - 1)
        if let box = storage.attribute(.amBlock, at: index, effectiveRange: nil) as? BlockBox {
            return box.value
        }
        return typingBlock()
    }

    private func typingBlock() -> BlockValue {
        guard let view, let box = view.pTypingAttributes[.amBlock] as? BlockBox else {
            return .paragraph
        }
        return box.value
    }

    func applyBlockStyle(_ block: BlockValue) {
        guard let view, let storage = view.pStorage else { return }
        let str = storage.string as NSString
        let selection = view.pSelectedRange
        let newTypingAttributes = RichText.attributes(block: block, marks: [:])
        if storage.length == 0 {
            view.pTypingAttributes = newTypingAttributes
            refreshFormattingState()
            return
        }
        let paragraphRange = str.paragraphRange(for: selection)
        if paragraphRange.length > 0 {
            storage.beginEditing()
            storage.enumerateAttributes(in: paragraphRange) { runAttrs, runRange, _ in
                let oldBlock = (runAttrs[.amBlock] as? BlockBox)?.value ?? .paragraph
                guard !oldBlock.isAtomic, runAttrs[.amTableBox] == nil else { return }
                let marks = RichText.marks(from: runAttrs, block: oldBlock)
                storage.setAttributes(
                    RichText.attributes(block: block, marks: marks),
                    range: runRange
                )
            }
            storage.endEditing()
        }
        view.pTypingAttributes = newTypingAttributes
        view.pSelectedRange = selection
        refreshFormattingState()
        scheduleSave()
    }

    func toggleMark(_ mark: String) {
        let turningOn = marksAtSelection()[mark] == nil
        applyMark(mark, value: turningOn ? .bool(true) : nil)
    }

    func setHighlight(_ name: String?) {
        applyMark("highlight", value: name.map { .string($0) })
    }

    private func applyMark(_ mark: String, value: JSONValue?) {
        guard let view, let storage = view.pStorage else { return }
        let selection = view.pSelectedRange
        if selection.length == 0 {
            let block = typingBlock()
            var marks = RichText.marks(from: view.pTypingAttributes, block: block)
            marks[mark] = value
            view.pTypingAttributes = RichText.attributes(block: block, marks: marks)
            refreshFormattingState()
            return
        }
        storage.beginEditing()
        storage.enumerateAttributes(in: selection) { runAttrs, runRange, _ in
            let block = (runAttrs[.amBlock] as? BlockBox)?.value ?? .paragraph
            guard !block.isAtomic, runAttrs[.amTableBox] == nil else { return }
            var marks = RichText.marks(from: runAttrs, block: block)
            marks[mark] = value
            var newAttrs = RichText.attributes(block: block, marks: marks)
            if let link = runAttrs[.link], marks["link"] == nil {
                newAttrs[.link] = link
            }
            storage.setAttributes(newAttrs, range: runRange)
        }
        storage.endEditing()
        view.pSelectedRange = selection
        refreshFormattingState()
        scheduleSave()
    }

    /// Custom Return behavior. Returns true when handled.
    func handleReturn() -> Bool {
        guard let view, let storage = view.pStorage else { return false }
        let block = blockAtSelection()
        let str = storage.string as NSString
        let paragraph = str.paragraphRange(for: view.pSelectedRange)
        let paragraphText = (paragraph.length > 0 ? str.substring(with: paragraph) : "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let continuing = block.type == "unordered-list-item"
            || block.type == "ordered-list-item"
            || block.type == "blockquote"
            || block.type == "code-block"
        if continuing, paragraphText.isEmpty {
            // Return on an empty continuing block leaves it, like Notes.
            applyBlockStyle(.paragraph)
            return true
        }
        if block.type == "heading" || block.isAtomic {
            view.pInsertText("\n")
            view.pTypingAttributes = RichText.attributes(block: .paragraph, marks: [:])
            refreshFormattingState()
            return true
        }
        // paragraphs, lists, quotes and code blocks continue their block
        return false
    }

    /// Markdown-style prefixes: typing a space after `-`, `1.`, `#`…`###`
    /// or `>` at the start of a paragraph converts the block.
    func handleMarkdownTrigger(at location: Int) -> Bool {
        guard let view, let storage = view.pStorage else { return false }
        guard view.pSelectedRange.length == 0 else { return false }
        let block = blockAtSelection()
        guard block.type == "paragraph" else { return false }
        let str = storage.string as NSString
        let paragraph = str.paragraphRange(for: NSRange(location: location, length: 0))
        guard location > paragraph.location else { return false }
        let prefixRange = NSRange(
            location: paragraph.location,
            length: location - paragraph.location
        )
        guard prefixRange.length <= 4 else { return false }
        let prefix = str.substring(with: prefixRange)
        let newBlock: BlockValue
        switch prefix {
        case "-", "*": newBlock = BlockValue(type: "unordered-list-item")
        case ">": newBlock = BlockValue(type: "blockquote")
        case "#": newBlock = .heading(level: 1)
        case "##": newBlock = .heading(level: 2)
        case "###": newBlock = .heading(level: 3)
        default:
            guard prefix.count >= 2, prefix.hasSuffix("."),
                  prefix.dropLast().allSatisfy(\.isNumber)
            else { return false }
            newBlock = BlockValue(type: "ordered-list-item")
        }
        view.pReplace(prefixRange, with: NSAttributedString(
            string: "",
            attributes: view.pTypingAttributes
        ))
        view.pSelectedRange = NSRange(location: paragraph.location, length: 0)
        applyBlockStyle(newBlock)
        return true
    }

    // MARK: attachment interaction

    @discardableResult
    func openAttachment(at charIndex: Int, includeImages: Bool = true) -> Bool {
        guard let storage = view?.pStorage, charIndex < storage.length else { return false }
        let attrs = storage.attributes(at: charIndex, effectiveRange: nil)
        guard attrs[.amTableBox] == nil else { return false }
        guard let box = attrs[.amBlock] as? BlockBox, box.value.isEmbedBlock else { return false }
        let block = box.value
        if block.type == "html" {
            controller.sheet = .html(HtmlBlockHandle(box: box, html: block.htmlSource ?? ""))
            return true
        }
        guard let url = block.embedUrl else { return false }
        if let image = cache.images[url] {
            guard includeImages else { return false }
            controller.sheet = .info(assetUrl: url, name: cache.names[url] ?? "Image", image: image)
            return true
        }
        let name = cache.names[url] ?? "attachment"
        let kind = AssetCache.kind(forName: name)
        guard kind == "audio" || kind == "video" else { return false }
        Task { [weak self] in
            guard let self else { return }
            var fileURL = self.cache.fileURLs[url]
            if fileURL == nil, let data = await self.model.assetBytes(url) {
                fileURL = Self.mediaFile(for: url, name: name, data: data)
                self.cache.fileURLs[url] = fileURL
            }
            guard let fileURL else { return }
            self.controller.sheet = kind == "audio"
                ? .audio(assetUrl: url, fileURL: fileURL, name: name)
                : .video(fileURL: fileURL, name: name)
        }
        return true
    }

    func updateHtmlBlock(_ box: BlockBox, html: String) {
        guard let storage = view?.pStorage else { return }
        guard let range = range(whereBlockBox: box, in: storage) else { return }
        let newBlock = BlockValue.html(html)
        storage.replaceCharacters(
            in: range,
            with: RichText.embedAttachment(for: newBlock, cache: cache)
        )
        scheduleSave()
    }

    func replaceAsset(oldUrl: String, data: Data, name: String, fileExtension: String, mime: String) {
        Task { [weak self] in
            guard let self else { return }
            guard let newUrl = await self.model.createAsset(
                data: data,
                name: name,
                fileExtension: fileExtension,
                mimeType: mime
            ) else { return }
            self.cache.names[newUrl] = name
            self.cache.fileURLs[newUrl] = Self.mediaFile(for: newUrl, name: name, data: data)
            guard let storage = self.view?.pStorage else { return }
            var target: NSRange?
            storage.enumerateAttribute(
                .amBlock,
                in: NSRange(location: 0, length: storage.length)
            ) { value, range, stop in
                guard let box = value as? BlockBox,
                      box.value.isEmbedBlock,
                      box.value.embedUrl == oldUrl
                else { return }
                target = range
                stop.pointee = true
            }
            guard let target else { return }
            let newBlock = BlockValue.embed(url: newUrl)
            storage.replaceCharacters(
                in: target,
                with: RichText.embedAttachment(for: newBlock, cache: self.cache)
            )
            self.scheduleSave()
            self.transcribeIfAudio(url: newUrl, data: data, name: name)
        }
    }

    private func range(whereBlockBox box: BlockBox, in storage: NSTextStorage) -> NSRange? {
        var found: NSRange?
        storage.enumerateAttribute(
            .amBlock,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            if (value as? BlockBox) === box {
                found = range
                stop.pointee = true
            }
        }
        return found
    }


    // MARK: attachments

    /// Route pasted/dropped data. Returns true when consumed.
    func incomingData(_ data: Data, fileExtension: String, suggestedName: String?) -> Bool {
        let ext = fileExtension.lowercased()
        let name = suggestedName
            ?? "attachment-\(Int(Date().timeIntervalSince1970)).\(ext)"
        insertAsset(data: data, name: name, fileExtension: ext, mime: Self.mime(for: ext))
        return true
    }

    static func mime(for ext: String) -> String {
        UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    func attachFromPanel(imagesOnly: Bool) {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = imagesOnly ? [.image] : [.item]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let data = try? Data(contentsOf: url)
            else { return }
            let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension.lowercased()
            Task { @MainActor in
                _ = self?.incomingData(data, fileExtension: ext, suggestedName: url.lastPathComponent)
            }
        }
        #endif
    }

    func insertAsset(data: Data, name: String, fileExtension: String, mime: String) {
        Task { [weak self] in
            guard let self else { return }
            guard let url = await self.model.createAsset(
                data: data,
                name: name,
                fileExtension: fileExtension,
                mimeType: mime
            ) else { return }
            if let image = PImage(data: data) {
                self.cache.images[url] = image
                // vision metadata in the background; searchable once written
                Task.detached { [weak model = self.model] in
                    if let result = await VisionAnalyzer.analyze(data) {
                        await model?.updateAssetVision(
                            url,
                            description: result.description,
                            ocr: result.ocr
                        )
                    }
                }
            } else {
                self.cache.names[url] = name
                if AssetCache.kind(forName: name) == "video" {
                    await self.prepareVideo(url: url, name: name, data: data)
                }
                self.transcribeIfAudio(url: url, data: data, name: name)
            }
            self.insertEmbedBlock(url: url)
        }
    }

    private func transcribeIfAudio(url: String, data: Data, name: String) {
        guard AssetCache.kind(forName: name) == "audio" else { return }
        let ext = (name as NSString).pathExtension.lowercased()
        Task.detached { [weak model] in
            guard let transcript = await Transcriber.transcribe(data, fileExtension: ext),
                  !transcript.isEmpty
            else { return }
            await model?.updateAssetVision(url, description: "voice recording", ocr: transcript)
        }
    }

    func insertTable() {
        let box = TableBox(raw: nil, grid: .empty(rows: 3, columns: 3))
        insertBlockAttachment(RichText.tableAttachment(for: box))
        inline.setNeedsReconcile()
    }

    func tableChanged(_ box: TableBox) {
        scheduleSave()
        inline.setNeedsReconcile()
    }

    func insertHtmlBlock() {
        let html = "<p>hello</p>"
        let block = BlockValue.html(html)
        let attachment = RichText.embedAttachment(for: block, cache: cache)
        insertBlockAttachment(attachment)
        guard let storage = view?.pStorage else { return }
        var handle: HtmlBlockHandle?
        storage.enumerateAttribute(
            .amBlock,
            in: NSRange(location: 0, length: storage.length)
        ) { value, _, _ in
            if let box = value as? BlockBox, box.value.type == "html",
               box.value.htmlSource == html {
                handle = HtmlBlockHandle(box: box, html: html)
            }
        }
        if let handle {
            controller.sheet = .html(handle)
        }
    }

    private func insertEmbedBlock(url: String) {
        let block = BlockValue.embed(url: url)
        insertBlockAttachment(RichText.embedAttachment(for: block, cache: cache))
    }

    private func insertBlockAttachment(_ attachment: NSAttributedString) {
        guard let view, let storage = view.pStorage else { return }
        let insertion = NSMutableAttributedString()
        let str = storage.string as NSString
        // insert after the current paragraph so it never splits text into
        // the embed block
        let paragraph = str.paragraphRange(for: view.pSelectedRange)
        let location = NSMaxRange(paragraph)
        let atParagraphStart = location == 0 || str.character(at: location - 1) == 0x0A
        if !atParagraphStart {
            insertion.append(NSAttributedString(
                string: "\n",
                attributes: view.pTypingAttributes
            ))
        }
        insertion.append(attachment)
        insertion.append(NSAttributedString(
            string: "\n",
            attributes: RichText.attributes(block: .paragraph, marks: [:])
        ))
        storage.insert(insertion, at: location)
        view.pSelectedRange = NSRange(location: location + insertion.length, length: 0)
        view.pTypingAttributes = RichText.attributes(block: .paragraph, marks: [:])
        scheduleSave()
    }
}

// MARK: - macOS

#if os(macOS)

final class EditorTextView: NSTextView, EditorTextViewLike {
    weak var core: EditorCore?

    var pStorage: NSTextStorage? { textStorage }
    var pSelectedRange: NSRange {
        get { selectedRange() }
        set { setSelectedRange(newValue) }
    }
    var pTypingAttributes: [NSAttributedString.Key: Any] {
        get { typingAttributes }
        set { typingAttributes = newValue }
    }
    var pLayoutManager: NSLayoutManager? { layoutManager }
    var pTextContainer: NSTextContainer? { textContainer }
    var pTextOrigin: CGPoint { textContainerOrigin }
    var pSelf: PView { self }

    func pInsertText(_ text: String) {
        insertText(text, replacementRange: selectedRange())
    }

    func pReplace(_ range: NSRange, with attributed: NSAttributedString) {
        if shouldChangeText(in: range, replacementString: attributed.string) {
            textStorage?.replaceCharacters(in: range, with: attributed)
            didChangeText()
        }
    }

    override func paste(_ sender: Any?) {
        if consumeAttachment(from: NSPasteboard.general) { return }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if consumeAttachment(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    /// Media/table/html attachments open on click; images open their info
    /// sheet on double-click so a single click still places the selection.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount <= 2, let core,
           let layoutManager, let textContainer, let storage = textStorage {
            let point = convert(event.locationInWindow, from: nil)
            let containerPoint = CGPoint(
                x: point.x - textContainerOrigin.x,
                y: point.y - textContainerOrigin.y
            )
            let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
            let rect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyphIndex, length: 1),
                in: textContainer
            )
            if rect.contains(containerPoint) {
                let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
                if charIndex < storage.length,
                   storage.attribute(.attachment, at: charIndex, effectiveRange: nil) != nil,
                   core.openAttachment(at: charIndex, includeImages: event.clickCount == 2) {
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }

    /// Files and images win over the stray strings browsers put alongside
    /// copied images; plain text still pastes as text.
    private func consumeAttachment(from pasteboard: NSPasteboard) -> Bool {
        guard let core else { return false }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let url = urls.first, url.isFileURL,
           let data = try? Data(contentsOf: url) {
            let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension.lowercased()
            return core.incomingData(data, fileExtension: ext, suggestedName: url.lastPathComponent)
        }
        if let data = pasteboard.data(forType: .png) {
            return core.incomingData(data, fileExtension: "png", suggestedName: nil)
        }
        if let data = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: data),
           let png = rep.representation(using: .png, properties: [:]) {
            return core.incomingData(png, fileExtension: "png", suggestedName: nil)
        }
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)) {
            return core.incomingData(data, fileExtension: "jpg", suggestedName: nil)
        }
        return false
    }
}

struct RichTextEditor: NSViewRepresentable {
    let noteUrl: String
    let model: NotesModel
    let controller: EditorController

    func makeCoordinator() -> Coordinator {
        Coordinator(core: EditorCore(noteUrl: noteUrl, model: model, controller: controller))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layoutManager = ListMarkerLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = EditorTextView(frame: .zero, textContainer: container)
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.typingAttributes = RichText.attributes(block: .paragraph, marks: [:])
        textView.delegate = context.coordinator
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.core = context.coordinator.core
        layoutManager.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.documentView = textView

        context.coordinator.core.view = textView
        context.coordinator.core.load()
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if context.coordinator.core.noteUrl != noteUrl {
            context.coordinator.core.switchTo(noteUrl)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        let core: EditorCore

        init(core: EditorCore) {
            self.core = core
        }

        func layoutManager(
            _ layoutManager: NSLayoutManager,
            didCompleteLayoutFor textContainer: NSTextContainer?,
            atEnd layoutFinishedFlag: Bool
        ) {
            core.inline.setNeedsReconcile()
        }

        func textDidChange(_ notification: Notification) {
            core.scheduleSave()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            core.refreshFormattingState()
        }

        func textView(_ view: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                return core.handleReturn()
            }
            return false
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            if replacementString == " ",
               affectedCharRange.length == 0,
               core.handleMarkdownTrigger(at: affectedCharRange.location) {
                return false
            }
            return true
        }
    }
}

#else

// MARK: - iOS

final class EditorTextView: UITextView, EditorTextViewLike {
    weak var core: EditorCore?

    var pStorage: NSTextStorage? { textStorage }
    var pSelectedRange: NSRange {
        get { selectedRange }
        set { selectedRange = newValue }
    }
    var pTypingAttributes: [NSAttributedString.Key: Any] {
        get { typingAttributes }
        set { typingAttributes = newValue }
    }
    var pLayoutManager: NSLayoutManager? { layoutManager }
    var pTextContainer: NSTextContainer? { textContainer }
    var pTextOrigin: CGPoint {
        CGPoint(x: textContainerInset.left, y: textContainerInset.top)
    }
    var pSelf: PView { self }

    func pInsertText(_ text: String) {
        insertText(text)
    }

    func pReplace(_ range: NSRange, with attributed: NSAttributedString) {
        textStorage.replaceCharacters(in: range, with: attributed)
        core?.scheduleSave()
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = UIPasteboard.general
        if pasteboard.hasImages, let core {
            if let data = pasteboard.data(forPasteboardType: UTType.png.identifier) {
                if core.incomingData(data, fileExtension: "png", suggestedName: nil) { return }
            }
            if let data = pasteboard.data(forPasteboardType: UTType.jpeg.identifier) {
                if core.incomingData(data, fileExtension: "jpg", suggestedName: nil) { return }
            }
            if let image = pasteboard.image, let data = image.pngData() {
                if core.incomingData(data, fileExtension: "png", suggestedName: nil) { return }
            }
        }
        super.paste(sender)
    }
}

struct RichTextEditor: UIViewRepresentable {
    let noteUrl: String
    let model: NotesModel
    let controller: EditorController

    func makeCoordinator() -> Coordinator {
        Coordinator(core: EditorCore(noteUrl: noteUrl, model: model, controller: controller))
    }

    func makeUIView(context: Context) -> EditorTextView {
        let storage = NSTextStorage()
        let layoutManager = ListMarkerLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = EditorTextView(frame: .zero, textContainer: container)
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.typingAttributes = RichText.attributes(block: .paragraph, marks: [:])
        textView.delegate = context.coordinator
        textView.core = context.coordinator.core
        textView.alwaysBounceVertical = true
        layoutManager.delegate = context.coordinator

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        textView.addGestureRecognizer(tap)

        context.coordinator.core.view = textView
        context.coordinator.core.load()
        return textView
    }

    func updateUIView(_ uiView: EditorTextView, context: Context) {
        if context.coordinator.core.noteUrl != noteUrl {
            context.coordinator.core.switchTo(noteUrl)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate,
        NSLayoutManagerDelegate {
        let core: EditorCore

        init(core: EditorCore) {
            self.core = core
        }

        func layoutManager(
            _ layoutManager: NSLayoutManager,
            didCompleteLayoutFor textContainer: NSTextContainer?,
            atEnd layoutFinishedFlag: Bool
        ) {
            core.inline.setNeedsReconcile()
        }

        func textViewDidChange(_ textView: UITextView) {
            core.scheduleSave()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            core.refreshFormattingState()
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            if text == "\n", core.handleReturn() {
                return false
            }
            if text == " ", range.length == 0,
               core.handleMarkdownTrigger(at: range.location) {
                return false
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView = gesture.view as? EditorTextView else { return }
            let point = gesture.location(in: textView)
            let containerPoint = CGPoint(
                x: point.x - textView.textContainerInset.left,
                y: point.y - textView.textContainerInset.top
            )
            let layoutManager = textView.layoutManager
            let glyphIndex = layoutManager.glyphIndex(
                for: containerPoint,
                in: textView.textContainer
            )
            let rect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyphIndex, length: 1),
                in: textView.textContainer
            )
            guard rect.contains(containerPoint) else { return }
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            guard charIndex < textView.textStorage.length,
                  textView.textStorage.attribute(
                    .attachment, at: charIndex, effectiveRange: nil
                  ) != nil
            else { return }
            core.openAttachment(at: charIndex)
        }
    }
}

#endif
