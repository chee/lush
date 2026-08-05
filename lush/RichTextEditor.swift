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
    static let styles: [(key: String, label: String)] = [
        ("paragraph", "Body"),
        ("heading1", "Title"),
        ("heading2", "Heading"),
        ("heading3", "Subheading"),
        ("unordered-list-item", "Bulleted List"),
        ("ordered-list-item", "Numbered List"),
        ("todo-list-item", "To-do List"),
        ("blockquote", "Quote"),
        ("code-block", "Code"),
    ]

    var currentStyleKey: String = "paragraph"
    var strongActive = false
    var emActive = false
    var codeActive = false
    var underlineActive = false
    var strikethroughActive = false
    var superscriptActive = false
    var subscriptActive = false
    var highlightActive: String?
    var recorderVisible = false
    var sheet: EditorSheet?
    #if os(iOS)
    var photoPickerVisible = false
    var filePickerVisible = false
    var cameraPickerVisible = false
    #endif
    @ObservationIgnored weak var core: EditorCore?

    func applyStyle(_ key: String) {
        core?.applyBlockStyle(BlockValue.fromStyleKey(key))
    }

    func toggleStrong() { core?.toggleMark("strong") }
    func toggleEm() { core?.toggleMark("em") }
    func toggleCode() { core?.toggleMark("code") }
    func toggleUnderline() { core?.toggleMark("underline") }
    func toggleStrikethrough() { core?.toggleMark("strikethrough") }
    // The two are exclusive: a run of text sits on one baseline.
    func toggleSuperscript() { core?.toggleBaseline("superscript") }
    func toggleSubscript() { core?.toggleBaseline("subscript") }
    func applyHighlight(_ name: String?) { core?.setHighlight(name) }
    func insertTable() { core?.insertTable() }
    func insertColumns() { core?.insertColumns() }
    func insertHtmlBlock() { core?.insertHtmlBlock() }
    func insertLogline() { core?.insertLogline() }
    func insertPatchworkDoc() { sheet = .patchworkCreate }

    #if os(iOS)
    func dismissKeyboard() { core?.endEditing() }
    #endif

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

    func analyzeAssetVision(_ url: String) async -> AssetVision? {
        guard let core else { return nil }
        return await core.model.analyzeAssetVision(url)
    }

    func saveTranscript(assetUrl: String, transcript: String) {
        core?.cache.transcripts[assetUrl] = transcript
        Task { [weak self] in
            guard let self else { return }
            let vision = await self.assetVision(assetUrl)
            await self.core?.model.updateAssetVision(assetUrl, description: vision?.description ?? "", ocr: transcript)
        }
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
    /// Paragraph location -> its 1-based ordinal, for the duration of one draw
    /// pass. Without it every item in a numbered list rescans the whole run
    /// above it, which is quadratic in the length of the list.
    private var ordinals: [Int: Int] = [:]

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        ordinals = [:]
        defer { ordinals = [:] }
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
            let isTodo = block.type == "todo-list-item"
            guard isBullet || isNumber || isTodo else { continue }

            let itemFont = storage.attribute(.font, at: paragraph.location, effectiveRange: nil)
                as? PFont ?? PFont.systemFont(ofSize: RichText.bodySize)
            let indent = (storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
                as? NSParagraphStyle)?.firstLineHeadIndent ?? 20
            // Force layout so empty paragraphs (just \n) have glyph info.
            ensureLayout(forCharacterRange: paragraph)
            let glyphIndex = glyphIndexForCharacter(at: paragraph.location)
            var lineRect: CGRect = glyphIndex < numberOfGlyphs
                ? lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
                : .zero
            // Empty final paragraphs use extraLineFragmentRect.
            if lineRect == .zero { lineRect = extraLineFragmentRect }
            guard lineRect != .zero else { continue }
            // Use font ascender for the baseline — glyph location y is 0
            // for paragraph-separator null glyphs on empty lines.
            let baseline = origin.y + lineRect.minY + itemFont.ascender
            let diameter: CGFloat = 6.5
            if isTodo {
                let side = itemFont.pointSize * 0.82
                let rect = CGRect(
                    x: origin.x + indent - side - 6,
                    y: baseline - itemFont.xHeight / 2 - side / 2,
                    width: side,
                    height: side
                )
                Self.drawCheckbox(in: rect, checked: block.isChecked)
            } else if isBullet {
                let rect = CGRect(
                    x: origin.x + indent - diameter - 5,
                    y: baseline - itemFont.xHeight / 2 - diameter / 2,
                    width: diameter,
                    height: diameter
                )
                PColor.pLabel.setFill()
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
                    .foregroundColor: PColor.pLabel,
                ]
                let point = CGPoint(
                    x: origin.x + indent - diameter - 5,
                    y: baseline - font.ascender
                )
                marker.draw(at: point, withAttributes: attrs)
            }
        }
    }

    /// 1-based position among the contiguous run of ordered items with the
    /// same nesting.
    private func ordinal(of location: Int, in storage: NSTextStorage, str: NSString) -> Int {
        if let hit = ordinals[location] { return hit }
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
            if let hit = ordinals[previous.location] {
                count += hit
                break
            }
            count += 1
            cursor = previous.location
        }
        ordinals[location] = count
        return count
    }

    /// The to-do box: an empty rounded square, or a filled one with a tick.
    /// Clicking it is handled by the text view (`toggleTodo(at:)`).
    static func drawCheckbox(in rect: CGRect, checked: Bool) {
        let square = rect.insetBy(dx: 0.75, dy: 0.75)
        #if os(macOS)
        let box = NSBezierPath(roundedRect: square, xRadius: 3, yRadius: 3)
        #else
        let box = UIBezierPath(roundedRect: square, cornerRadius: 3)
        #endif
        guard checked else {
            box.lineWidth = 1.5
            PColor.pSecondaryLabel.setStroke()
            box.stroke()
            return
        }
        PColor.pTint.setFill()
        box.fill()
        let tick = PBezierPath()
        tick.move(to: CGPoint(x: rect.minX + rect.width * 0.24, y: rect.midY + rect.height * 0.02))
        tick.line(to: CGPoint(x: rect.minX + rect.width * 0.43, y: rect.maxY - rect.height * 0.24))
        tick.line(to: CGPoint(x: rect.minX + rect.width * 0.76, y: rect.minY + rect.height * 0.24))
        tick.lineWidth = max(1.5, rect.width * 0.14)
        PColor.pOnTint.setStroke()
        tick.stroke()
    }
}

@MainActor
private final class EditorDocumentSession {
    let noteUrl: String
    let storage = NSTextStorage()
    var heads: [String] = []
    var lastKnownJSON = ""
    var title = ""
    var isApplyingDocumentState = false
    var loaded = false
    var loadTask: Task<NoteSpansSnapshot, Never>?

    init(noteUrl: String) {
        self.noteUrl = noteUrl
    }
}

@MainActor
private enum EditorDocumentSessions {
    private static var sessions: [String: EditorDocumentSession] = [:]

    static func session(for noteUrl: String) -> EditorDocumentSession {
        if let session = sessions[noteUrl] {
            return session
        }
        let session = EditorDocumentSession(noteUrl: noteUrl)
        sessions[noteUrl] = session
        return session
    }
}

@MainActor
final class EditorCore {
    weak var view: (any EditorTextViewLike)?
    let model: NotesModel
    let controller: EditorController
    var noteUrl: String
    private var session: EditorDocumentSession

    private var saveTask: Task<Void, Never>?
    private var localWriteHeadsTask: Task<[String]?, Never>?
    private var localWritesInFlight = 0
    private var pendingRemoteReload = false
    private var isApplyingDocumentState = false
    private var remoteReloadTask: Task<Void, Never>?
    private var remoteReloadGeneration = 0
    private var pendingTextSplice: PendingTextSplice?
    private var queuedTextSplice: QueuedTextSplice?
    private var textSpliceFlushTask: Task<Void, Never>?
    let cache = AssetCache()

    let inline = InlineViewManager()
    private var settingsObserver: (any NSObjectProtocol)?
    private var noteObserverId: UUID?

    init(noteUrl: String, model: NotesModel, controller: EditorController) {
        self.noteUrl = noteUrl
        self.session = EditorDocumentSessions.session(for: noteUrl)
        self.model = model
        self.controller = controller
        controller.core = self
        inline.core = self
        noteObserverId = model.addNoteObserver { [weak self] url in
            self?.remoteChanged(url)
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: EditorSettings.changed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.load()
            }
        }
    }

    deinit {
        remoteReloadTask?.cancel()
        textSpliceFlushTask?.cancel()
        saveTask?.cancel()
        contextMonitorTask?.cancel()
        if let noteObserverId {
            Task { @MainActor [model] in
                model.removeNoteObserver(noteObserverId)
            }
        }
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    // MARK: loading

    var sharedStorage: NSTextStorage {
        session.storage
    }

    func switchTo(_ url: String) {
        pushNow()
        remoteReloadTask?.cancel()
        textSpliceFlushTask?.cancel()
        pendingRemoteReload = false
        pendingTextSplice = nil
        queuedTextSplice = nil
        textSpliceFlushTask = nil
        noteUrl = url
        session = EditorDocumentSessions.session(for: url)
        attachViewToSharedStorage()
        lastContextSnap = contextTracker?.snapshot ?? ContextSnapshot()
        load()
    }

    func attachViewToSharedStorage() {
        guard let layoutManager = view?.pLayoutManager else { return }
        if layoutManager.textStorage !== session.storage {
            layoutManager.textStorage?.removeLayoutManager(layoutManager)
            session.storage.addLayoutManager(layoutManager)
        }
    }

    func detachViewFromSharedStorage() {
        guard let layoutManager = view?.pLayoutManager,
              layoutManager.textStorage === session.storage
        else { return }
        session.storage.removeLayoutManager(layoutManager)
    }

    private weak var contextTracker: ContextTracker?
    private var lastContextSnap = ContextSnapshot()
    private var contextMonitorTask: Task<Void, Never>?

    func startContext(_ tracker: ContextTracker) {
        contextTracker = tracker
        lastContextSnap = tracker.snapshot
        contextMonitorTask?.cancel()
        contextMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                self?.checkContextChange()
            }
        }
    }

    private func checkContextChange() {
        guard EditorSettings.autoInsertLogline else { return }
        guard let tracker = contextTracker else { return }
        let snap = tracker.snapshot
        guard snap.hasSubstantialChange(from: lastContextSnap) else { return }
        lastContextSnap = snap
        insertContextBlockAtEnd(BlockValue.contextBlock(from: snap))
    }

    func insertLogline() {
        let snap = contextTracker?.snapshot ?? ContextSnapshot(timestamp: Date())
        insertBlockAttachment(RichText.embedAttachment(for: BlockValue.contextBlock(from: snap), cache: cache))
        inline.setNeedsReconcile()
    }

    private func insertContextBlockAtEnd(_ block: BlockValue) {
        guard let view, let storage = view.pStorage, storage.length > 0 else { return }
        let saved = view.pSelectedRange
        view.pSelectedRange = NSRange(location: max(0, storage.length - 1), length: 0)
        insertBlockAttachment(RichText.embedAttachment(for: block, cache: cache))
        view.pSelectedRange = NSRange(location: min(saved.location, storage.length), length: 0)
    }

    func load() {
        let url = noteUrl
        Task { [weak self] in
            guard let self else { return }
            let session = self.session
            if session.loaded {
                // The session survives across visits but this editor's asset
                // cache does not; reclassify embeds before reconciling or
                // they all render as empty space.
                let spans = SpanNode.decodeList(session.lastKnownJSON)
                await self.fetchMissingAssets(in: spans)
                guard self.noteUrl == url, self.session === session else { return }
                self.syncFromSession()
                return
            }
            let task: Task<NoteSpansSnapshot, Never>
            if let loadTask = session.loadTask {
                task = loadTask
            } else {
                task = Task { [model] in await model.spansSnapshot(for: url) }
                session.loadTask = task
            }
            let snapshot = await task.value
            guard self.noteUrl == url, self.session === session else { return }
            let json = snapshot.spansJson
            let spans = SpanNode.decodeList(json)
            await self.fetchMissingAssets(in: spans)
            guard self.noteUrl == url, self.session === session else { return }
            session.heads = snapshot.heads
            session.loaded = true
            session.loadTask = nil
            let shouldFocus = self.model.pendingFocusUrl == url
            if shouldFocus { self.model.pendingFocusUrl = nil }
            self.apply(spans: spans, focus: shouldFocus)
        }
    }

    private func syncFromSession() {
        attachViewToSharedStorage()
        guard let view else { return }
        let location = min(view.pSelectedRange.location, session.storage.length)
        view.pSelectedRange = NSRange(location: location, length: 0)
        refreshFormattingState()
        inline.setNeedsReconcile()
    }

    private func fetchMissingAssets(in spans: [SpanNode]) async {
        let urls: [String] = spans.compactMap { node -> String? in
            guard case .block(let block) = node,
                  block.isEmbedBlock,
                  let url = block.embedUrl,
                  url.hasPrefix("automerge:"),
                  cache.images[url] == nil, cache.names[url] == nil,
                  !cache.patchworkDocs.contains(url)
            else { return nil }
            return url
        }
        guard !urls.isEmpty else { return }
        let model = self.model
        let fetched: [(String, Data?)] = await withTaskGroup(of: (String, Data?).self) { group in
            for url in urls {
                group.addTask {
                    let data = await model.assetBytes(url)
                    return (url, data)
                }
            }
            var results: [(String, Data?)] = []
            for await pair in group { results.append(pair) }
            return results
        }
        for (url, data) in fetched {
            guard let data else {
                let info = await model.assetInfo(url)
                if (info?.mimeType ?? "").isEmpty {
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
                switch AssetCache.kind(forName: name) {
                case "video":
                    await prepareVideo(url: url, name: name, data: data)
                case "audio":
                    cache.fileURLs[url] = Self.mediaFile(for: url, name: name, data: data)
                    if let vision = await model.assetVision(url), !vision.ocr.isEmpty {
                        cache.transcripts[url] = vision.ocr
                    }
                default:
                    break
                }
            }
        }
    }

    func isPatchworkDoc(_ url: String) -> Bool {
        cache.patchworkDocs.contains(url)
    }

    func endEditing() {
        #if os(iOS)
        (view as? UITextView)?.resignFirstResponder()
        #endif
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

    private func apply(spans: [SpanNode], focus: Bool = false) {
        guard let view, let storage = view.pStorage else { return }
        let attributed = RichText.attributed(from: spans, cache: cache)
        let selection = view.pSelectedRange
        isApplyingDocumentState = true
        session.isApplyingDocumentState = true
        pendingTextSplice = nil
        queuedTextSplice = nil
        textSpliceFlushTask?.cancel()
        textSpliceFlushTask = nil
        defer {
            isApplyingDocumentState = false
            session.isApplyingDocumentState = false
        }
        storage.setAttributedString(attributed)
        var location = min(selection.location, attributed.length)
        if location == 0, attributed.length > 1 {
            let str = attributed.string as NSString
            var loc = 0
            while loc < attributed.length {
                if let box = attributed.attribute(.amBlock, at: loc, effectiveRange: nil) as? BlockBox,
                   box.value.isEmbedBlock {
                    loc = NSMaxRange(str.paragraphRange(for: NSRange(location: loc, length: 0)))
                } else {
                    break
                }
            }
            location = loc
        }
        view.pSelectedRange = NSRange(location: location, length: 0)
        if attributed.length == 0 {
            // Notes-style: an empty note starts with a Title line.
            view.pTypingAttributes = RichText.attributes(block: .heading(level: 1), marks: [:])
        }
        session.lastKnownJSON = SpanNode.encodeList(spans)
        session.title = RichText.title(from: spans)
        refreshFormattingState()
        inline.setNeedsReconcile()
        if location == attributed.length, location > 0,
           let lastNonEmbed = spans.reversed().compactMap({ (s: SpanNode) -> BlockValue? in guard case .block(let b) = s, !b.isEmbedBlock else { return nil }; return b }).first {
            view.pTypingAttributes = RichText.attributes(block: lastNonEmbed, marks: [:])
            controller.currentStyleKey = lastNonEmbed.styleKey
        }
        if focus {
            #if os(macOS)
            view.pSelf.window?.makeFirstResponder(view.pSelf)
            #else
            view.pSelf.becomeFirstResponder()
            #endif
        }
    }

    private func remoteChanged(_ url: String) {
        guard url == noteUrl else { return }
        guard localWritesInFlight == 0 else {
            pendingRemoteReload = true
            return
        }
        remoteReloadGeneration += 1
        let generation = remoteReloadGeneration
        remoteReloadTask?.cancel()
        remoteReloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            let snapshot = await self.model.spansSnapshot(for: url)
            guard !Task.isCancelled, self.noteUrl == url, self.remoteReloadGeneration == generation else { return }
            let json = snapshot.spansJson
            let spans = SpanNode.decodeList(json)
            await self.fetchMissingAssets(in: spans)
            guard !Task.isCancelled, self.noteUrl == url, self.remoteReloadGeneration == generation else { return }
            self.session.heads = snapshot.heads
            let canonical = SpanNode.encodeList(spans)
            if canonical != self.session.lastKnownJSON {
                self.apply(spans: spans)
            }
        }
    }

    private func beginLocalWrite() {
        localWritesInFlight += 1
    }

    private func finishLocalWrite(for url: String) {
        localWritesInFlight = max(0, localWritesInFlight - 1)
        guard localWritesInFlight == 0, pendingRemoteReload, noteUrl == url else { return }
        pendingRemoteReload = false
        remoteChanged(url)
    }

    // MARK: saving

    private struct PendingTextSplice {
        let index: UInt64
        let deleteCount: Int64
        let insert: String
        let utf16Location: Int
        let utf16Length: Int
    }

    private struct QueuedTextSplice {
        let url: String
        var index: UInt64
        var deleteCount: Int64
        var insert: String
        var utf16EndLocation: Int
        var title: String
        let heads: [String]
    }

    private struct PreparedTextMark {
        let start: UInt64
        let end: UInt64
        let valueJson: String?
    }

    func prepareTextSplice(range: NSRange, replacement: String) -> Bool {
        pendingTextSplice = nil
        guard let storage = view?.pStorage else { return false }
        guard isPlainTextSpliceCandidate(in: storage, range: range, replacement: replacement) else {
            return false
        }
        let deleteCount = editableScalarCount(in: storage, range: range)
        let index: UInt64
        if range.length == 0,
           !replacement.isEmpty,
           let queued = queuedTextSplice,
           queued.url == noteUrl,
           queued.deleteCount == 0,
           range.location == queued.utf16EndLocation {
            index = queued.index + UInt64(queued.insert.unicodeScalars.count)
        } else if replacement.isEmpty,
                  range.length > 0,
                  let queued = queuedTextSplice,
                  queued.url == noteUrl,
                  queued.insert.isEmpty,
                  range.location == queued.utf16EndLocation {
            index = queued.index
        } else if replacement.isEmpty,
                  range.length > 0,
                  deleteCount > 0,
                  let queued = queuedTextSplice,
                  queued.url == noteUrl,
                  queued.insert.isEmpty,
                  NSMaxRange(range) == queued.utf16EndLocation,
                  queued.index >= UInt64(deleteCount) {
            index = queued.index - UInt64(deleteCount)
        } else {
            guard let resolved = automergeTextPosition(in: storage, at: range.location) else {
                return false
            }
            index = UInt64(resolved)
        }
        pendingTextSplice = PendingTextSplice(
            index: index,
            deleteCount: Int64(deleteCount),
            insert: replacement,
            utf16Location: range.location,
            utf16Length: range.length
        )
        return true
    }

    func textDidChange() {
        guard !isApplyingDocumentState, !session.isApplyingDocumentState else { return }
        guard let pending = pendingTextSplice else {
            scheduleSave()
            return
        }
        pendingTextSplice = nil
        guard let storage = view?.pStorage else {
            scheduleSave()
            return
        }
        let title: String
        if pending.index < 120 || session.title.isEmpty {
            title = titleFromStorage(storage)
            session.title = title
        } else {
            title = session.title
        }
        let url = noteUrl
        if pending.deleteCount == 0,
           let queued = queuedTextSplice,
           queued.url == url,
           queued.deleteCount == 0,
           pending.utf16Length == 0,
           pending.utf16Location == queued.utf16EndLocation,
           pending.index == queued.index + UInt64(queued.insert.unicodeScalars.count) {
            queuedTextSplice?.insert += pending.insert
            queuedTextSplice?.utf16EndLocation += (pending.insert as NSString).length
            queuedTextSplice?.title = title
            scheduleQueuedTextSpliceFlush()
            return
        }
        if pending.insert.isEmpty,
           pending.deleteCount > 0,
           let queued = queuedTextSplice,
           queued.url == url,
           queued.insert.isEmpty,
           pending.utf16Location == queued.utf16EndLocation,
           pending.index == queued.index {
            queuedTextSplice?.deleteCount += pending.deleteCount
            queuedTextSplice?.title = title
            scheduleQueuedTextSpliceFlush()
            return
        }
        if pending.insert.isEmpty,
           pending.deleteCount > 0,
           let queued = queuedTextSplice,
           queued.url == url,
           queued.insert.isEmpty,
           NSMaxRange(NSRange(location: pending.utf16Location, length: pending.utf16Length)) == queued.utf16EndLocation,
           pending.index + UInt64(pending.deleteCount) == queued.index {
            queuedTextSplice?.index = pending.index
            queuedTextSplice?.deleteCount += pending.deleteCount
            queuedTextSplice?.utf16EndLocation = pending.utf16Location
            queuedTextSplice?.title = title
            scheduleQueuedTextSpliceFlush()
            return
        }
        flushQueuedTextSplice()
        queuedTextSplice = QueuedTextSplice(
            url: url,
            index: pending.index,
            deleteCount: pending.deleteCount,
            insert: pending.insert,
            utf16EndLocation: pending.utf16Location + (pending.insert as NSString).length,
            title: title,
            heads: session.heads
        )
        scheduleQueuedTextSpliceFlush()
    }

    private func scheduleQueuedTextSpliceFlush() {
        textSpliceFlushTask?.cancel()
        textSpliceFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.flushQueuedTextSplice()
        }
    }

    private func flushQueuedTextSplice() {
        textSpliceFlushTask?.cancel()
        textSpliceFlushTask = nil
        guard let queued = queuedTextSplice else { return }
        queuedTextSplice = nil
        let url = queued.url
        let heads = queued.heads
        let previousHeadsTask = localWriteHeadsTask
        beginLocalWrite()
        let task = Task { [weak self] () -> [String]? in
            let chainedHeads = await previousHeadsTask?.value
            guard let self else { return nil }
            defer { self.finishLocalWrite(for: url) }
            let writeHeads = chainedHeads ?? heads
            let newHeads = await self.model.spliceNoteText(
                url,
                index: queued.index,
                deleteCount: queued.deleteCount,
                insert: queued.insert,
                title: queued.title,
                spansJson: nil,
                heads: writeHeads,
                origin: self.noteObserverId
            )
            guard self.noteUrl == url else { return nil }
            guard let newHeads else {
                self.scheduleSave()
                return nil
            }
            self.session.heads = newHeads
            return newHeads
        }
        localWriteHeadsTask = task
    }

    private func titleFromStorage(_ storage: NSAttributedString) -> String {
        let string = storage.string as NSString
        var title = ""
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, range, stop in
            guard attrs[.amDisplayOnly] == nil else { return }
            let text = string.substring(with: range)
                .replacingOccurrences(of: "\u{FFFC}", with: "")
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    title = String(trimmed.prefix(60))
                    stop.pointee = true
                    return
                }
            }
        }
        return title
    }

    func scheduleSave() {
        guard !isApplyingDocumentState, !session.isApplyingDocumentState else { return }
        flushQueuedTextSplice()
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.pushNow()
        }
    }

    func pushNow() {
        guard !isApplyingDocumentState, !session.isApplyingDocumentState else { return }
        if queuedTextSplice != nil {
            flushQueuedTextSplice()
            return
        }
        saveTask?.cancel()
        saveTask = nil
        guard let storage = view?.pStorage else { return }
        let typing = typingBlock()
        let spans = RichText.spans(from: storage, trailingBlock: typing.isAtomic ? nil : typing)
        let json = SpanNode.encodeList(spans)
        guard json != session.lastKnownJSON else { return }
        session.lastKnownJSON = json
        let url = noteUrl
        let title = RichText.title(from: spans)
        session.title = title
        beginLocalWrite()
        Task { [weak self] in
            guard let self else { return }
            defer { self.finishLocalWrite(for: url) }
            await self.model.updateDocument(url, json: json, title: title, origin: self.noteObserverId)
        }
    }

    private func automergeTextPosition(in storage: NSAttributedString, at location: Int) -> Int? {
        let string = storage.string as NSString
        guard location >= 0, location <= string.length else { return nil }
        guard string.length > 0 else { return nil }
        var position = 0
        var cursor = 0
        while cursor < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: cursor, length: 0))
            let contentEnd = paragraphContentEnd(in: string, paragraph: paragraph)
            position += 1
            if location >= paragraph.location, location <= contentEnd {
                let prefix = NSRange(location: paragraph.location, length: location - paragraph.location)
                return position + editableScalarCount(in: storage, range: prefix)
            }
            position += editableScalarCount(
                in: storage,
                range: NSRange(location: paragraph.location, length: contentEnd - paragraph.location)
            )
            cursor = NSMaxRange(paragraph)
        }
        return position
    }

    private func paragraphContentEnd(in string: NSString, paragraph: NSRange) -> Int {
        guard paragraph.length > 0 else { return paragraph.location }
        let end = NSMaxRange(paragraph)
        return string.character(at: end - 1) == 0x0A ? end - 1 : end
    }

    private func isPlainTextSpliceCandidate(
        in storage: NSAttributedString,
        range: NSRange,
        replacement: String
    ) -> Bool {
        let string = storage.string as NSString
        guard range.location >= 0,
              range.length >= 0,
              NSMaxRange(range) <= string.length
        else { return false }
        guard !hasMarkedText() else { return false }
        guard !replacement.contains("\n"),
              !replacement.contains("\u{FFFC}")
        else { return false }
        if range.length > 0 {
            guard !string.substring(with: range).contains("\n") else { return false }
            let paragraph = string.paragraphRange(for: NSRange(location: range.location, length: 0))
            guard NSMaxRange(range) <= paragraphContentEnd(in: string, paragraph: paragraph) else {
                return false
            }
            guard attributesArePlainEditable(in: storage, range: range) else {
                return false
            }
        } else if storage.length > 0 {
            guard insertionPointIsPlainEditable(in: storage, location: range.location) else {
                return false
            }
        }
        return true
    }

    private func hasMarkedText() -> Bool {
        #if os(macOS)
        if let textView = view as? NSTextView {
            return textView.hasMarkedText()
        }
        #else
        if let textView = view as? UITextView {
            return textView.markedTextRange != nil
        }
        #endif
        return false
    }

    private func insertionPointIsPlainEditable(
        in storage: NSAttributedString,
        location: Int
    ) -> Bool {
        guard storage.length > 0 else { return true }
        let probeLocations = [
            min(location, storage.length - 1),
            max(0, location - 1),
        ]
        for probe in Set(probeLocations) {
            guard attributesArePlainEditable(
                in: storage,
                range: NSRange(location: probe, length: 1)
            ) else { return false }
        }
        return true
    }

    private func attributesArePlainEditable(
        in storage: NSAttributedString,
        range: NSRange
    ) -> Bool {
        guard range.length > 0 else { return true }
        var ok = true
        storage.enumerateAttributes(in: range) { attrs, _, stop in
            if attrs[.amDisplayOnly] != nil
                || attrs[.attachment] != nil
                || attrs[.amTableBox] != nil
                || attrs[.amColumnsBox] != nil
                || (attrs[.amBlock] as? BlockBox)?.value.isAtomic == true {
                ok = false
                stop.pointee = true
            }
        }
        return ok
    }

    private func prepareTextMark(
        range: NSRange,
        value: JSONValue?
    ) -> PreparedTextMark? {
        guard let storage = view?.pStorage else { return nil }
        guard range.length > 0,
              isPlainTextSpliceCandidate(in: storage, range: range, replacement: "")
        else { return nil }
        guard let start = automergeTextPosition(in: storage, at: range.location) else {
            return nil
        }
        let count = editableScalarCount(in: storage, range: range)
        guard count > 0 else { return nil }
        let valueJson: String?
        if let value {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(value),
                  let json = String(data: data, encoding: .utf8)
            else { return nil }
            valueJson = json
        } else {
            valueJson = nil
        }
        return PreparedTextMark(
            start: UInt64(start),
            end: UInt64(start + count),
            valueJson: valueJson
        )
    }

    private func editableScalarCount(in storage: NSAttributedString, range: NSRange) -> Int {
        guard range.length > 0 else { return 0 }
        let string = storage.string as NSString
        var count = 0
        storage.enumerateAttributes(in: range) { attrs, runRange, _ in
            guard attrs[.amDisplayOnly] == nil else { return }
            let text = string.substring(with: runRange)
                .replacingOccurrences(of: "\u{FFFC}", with: "")
            count += text.unicodeScalars.count
        }
        return count
    }

    // MARK: formatting

    func refreshFormattingState() {
        guard let view else { return }
        var typing = view.pTypingAttributes
        if typing[.amTableBox] != nil || typing[.amColumnsBox] != nil
            || typing[.attachment] != nil
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
        controller.underlineActive = marks["underline"] != nil
        controller.strikethroughActive = marks["strikethrough"] != nil
        controller.superscriptActive = marks["superscript"] != nil
        controller.subscriptActive = marks["subscript"] != nil
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
        if storage.length == 0 || selection.location >= storage.length {
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

    /// The character in a to-do item whose box sits under this point in the
    /// text container — the marker gutter is the indent the item's own
    /// paragraph style asks for.
    func todoBoxHit(
        at point: CGPoint,
        layoutManager: NSLayoutManager,
        container: NSTextContainer
    ) -> Int? {
        guard let storage = view?.pStorage, storage.length > 0 else { return nil }
        let index = min(
            layoutManager.characterIndex(
                for: point,
                in: container,
                fractionOfDistanceBetweenInsertionPoints: nil
            ),
            storage.length - 1
        )
        guard let style = storage.attribute(.paragraphStyle, at: index, effectiveRange: nil)
                as? NSParagraphStyle,
              point.x >= 0, point.x < style.firstLineHeadIndent,
              let box = storage.attribute(.amBlock, at: index, effectiveRange: nil) as? BlockBox,
              box.value.type == "todo-list-item"
        else { return nil }
        return index
    }

    /// Tick or untick the to-do item containing a character. Returns false
    /// when that character isn't in one, so a click can fall through.
    @discardableResult
    func toggleTodo(at character: Int) -> Bool {
        guard let view, let storage = view.pStorage, character < storage.length else { return false }
        let str = storage.string as NSString
        let paragraph = str.paragraphRange(for: NSRange(location: character, length: 0))
        guard paragraph.length > 0,
              let box = storage.attribute(.amBlock, at: paragraph.location, effectiveRange: nil) as? BlockBox,
              box.value.type == "todo-list-item"
        else { return false }
        var block = box.value
        if block.isChecked {
            block.attrs.removeValue(forKey: "checked")
        } else {
            block.attrs["checked"] = .bool(true)
        }
        let selection = view.pSelectedRange
        storage.beginEditing()
        storage.enumerateAttributes(in: paragraph) { runAttrs, runRange, _ in
            let marks = RichText.marks(from: runAttrs, block: box.value)
            storage.setAttributes(RichText.attributes(block: block, marks: marks), range: runRange)
        }
        storage.endEditing()
        view.pSelectedRange = selection
        refreshFormattingState()
        scheduleSave()
        return true
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
                guard !oldBlock.isAtomic, runAttrs[.amTableBox] == nil,
                      runAttrs[.amColumnsBox] == nil else { return }
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

    /// Superscript and subscript are one axis: turning one on turns the other
    /// off, since text can only sit on one baseline.
    func toggleBaseline(_ mark: String) {
        let other = mark == "superscript" ? "subscript" : "superscript"
        let turningOn = marksAtSelection()[mark] == nil
        if turningOn, marksAtSelection()[other] != nil {
            applyMark(other, value: nil)
        }
        applyMark(mark, value: turningOn ? .bool(true) : nil)
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
        let prepared = prepareTextMark(range: selection, value: value)
        storage.beginEditing()
        storage.enumerateAttributes(in: selection) { runAttrs, runRange, _ in
            let block = (runAttrs[.amBlock] as? BlockBox)?.value ?? .paragraph
            guard !block.isAtomic, runAttrs[.amTableBox] == nil,
                  runAttrs[.amColumnsBox] == nil else { return }
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
        guard let prepared else {
            scheduleSave()
            return
        }
        let typing = typingBlock()
        let spans = RichText.spans(from: storage, trailingBlock: typing.isAtomic ? nil : typing)
        let json = SpanNode.encodeList(spans)
        session.lastKnownJSON = json
        let title = RichText.title(from: spans)
        let url = noteUrl
        let heads = session.heads
        let previousHeadsTask = localWriteHeadsTask
        beginLocalWrite()
        let task = Task { [weak self] () -> [String]? in
            let chainedHeads = await previousHeadsTask?.value
            guard let self else { return nil }
            defer { self.finishLocalWrite(for: url) }
            let writeHeads = chainedHeads ?? heads
            let newHeads = await self.model.applyNoteMark(
                url,
                start: prepared.start,
                end: prepared.end,
                name: mark,
                valueJson: prepared.valueJson,
                title: title,
                spansJson: json,
                heads: writeHeads,
                origin: self.noteObserverId
            )
            guard self.noteUrl == url else { return nil }
            guard let newHeads else {
                self.scheduleSave()
                return nil
            }
            self.session.heads = newHeads
            return newHeads
        }
        localWriteHeadsTask = task
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
            || block.type == "todo-list-item"
            || block.type == "blockquote"
            || block.type == "code-block"
        if continuing, paragraphText.isEmpty {
            // Return on an empty continuing block leaves it, like Notes.
            applyBlockStyle(.paragraph)
            return true
        }
        // A new to-do starts unticked, however the one above it stands.
        if block.type == "todo-list-item" {
            view.pInsertText("\n")
            view.pTypingAttributes = RichText.attributes(block: .todo(checked: false), marks: [:])
            refreshFormattingState()
            return true
        }
        if block.type == "heading" || block.isAtomic {
            view.pInsertText("\n")
            view.pTypingAttributes = RichText.attributes(block: .paragraph, marks: [:])
            refreshFormattingState()
            return true
        }
        // paragraphs, lists, quotes and code blocks continue their block
        // On iOS, UITextView does not reliably carry custom block attributes
        // across paragraph boundaries when it handles the newline internally.
        // Mirror the heading case: insert the newline ourselves and set attrs.
        #if os(iOS)
        if continuing {
            view.pInsertText("\n")
            view.pTypingAttributes = RichText.attributes(block: block, marks: [:])
            refreshFormattingState()
            return true
        }
        #endif
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
        case "[]", "[ ]": newBlock = .todo(checked: false)
        case "[x]", "[X]": newBlock = .todo(checked: true)
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

    /// Tab in a list: increase indent by one level. Returns true when handled.
    @discardableResult
    func nestListItem() -> Bool {
        let block = blockAtSelection()
        guard block.type == "unordered-list-item" || block.type == "ordered-list-item" else {
            return false
        }
        var nested = block
        nested.parents.append(block.type)
        applyBlockStyle(nested)
        return true
    }

    /// Shift+Tab in a list: decrease indent by one level. Returns true when handled.
    @discardableResult
    func unnestListItem() -> Bool {
        let block = blockAtSelection()
        guard block.type == "unordered-list-item" || block.type == "ordered-list-item" else {
            return false
        }
        guard !block.parents.isEmpty else { return false }
        var unnested = block
        unnested.parents.removeLast()
        applyBlockStyle(unnested)
        return true
    }

    // MARK: attachment interaction

    func isImageAttachment(at charIndex: Int) -> Bool {
        guard let storage = view?.pStorage, charIndex < storage.length,
              let box = storage.attributes(at: charIndex, effectiveRange: nil)[.amBlock] as? BlockBox,
              box.value.isEmbedBlock,
              let url = box.value.embedUrl
        else { return false }
        return cache.images[url] != nil
    }

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

    func removeEmbed(_ box: BlockBox) {
        guard let storage = view?.pStorage else { return }
        guard let range = range(whereBlockBox: box, in: storage) else { return }
        storage.replaceCharacters(in: range, with: NSAttributedString())
        scheduleSave()
        inline.setNeedsReconcile()
    }

    func updateEmbedTool(_ box: BlockBox, tool: String?) {
        guard let storage = view?.pStorage else { return }
        guard let range = range(whereBlockBox: box, in: storage) else { return }
        guard let url = box.value.embedUrl else { return }
        var newBlock = BlockValue.embed(url: url)
        if let tool, !tool.isEmpty {
            newBlock.attrs["tool"] = .string(tool)
        }
        storage.replaceCharacters(
            in: range,
            with: RichText.embedAttachment(for: newBlock, cache: cache)
        )
        scheduleSave()
        inline.setNeedsReconcile()
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
                switch AssetCache.kind(forName: name) {
                case "video":
                    await self.prepareVideo(url: url, name: name, data: data)
                case "audio":
                    self.cache.fileURLs[url] = Self.mediaFile(for: url, name: name, data: data)
                default:
                    break
                }
                self.transcribeIfAudio(url: url, data: data, name: name)
            }
            self.insertEmbedBlock(url: url)
        }
    }

    private func transcribeIfAudio(url: String, data: Data, name: String) {
        guard AssetCache.kind(forName: name) == "audio" else { return }
        let ext = (name as NSString).pathExtension.lowercased()
        Task.detached { [weak model, weak self] in
            guard let transcript = await Transcriber.transcribe(data, fileExtension: ext),
                  !transcript.isEmpty
            else { return }
            await model?.updateAssetVision(url, description: "voice recording", ocr: transcript)
            await self?.transcriptReady(url: url, transcript: transcript)
        }
    }

    private func transcriptReady(url: String, transcript: String) {
        cache.transcripts[url] = transcript
        inline.resetHosts()
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

    func insertColumns() {
        let box = ColumnsBox(
            raw: nil,
            columns: [[.block(.paragraph)], [.block(.paragraph)]]
        )
        insertBlockAttachment(RichText.columnsAttachment(for: box))
        inline.setNeedsReconcile()
    }

    func columnsChanged(_ box: ColumnsBox) {
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

    override func pasteAsPlainText(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            super.pasteAsPlainText(sender)
            return
        }
        insertText(text, replacementRange: selectedRange())
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if consumeAttachment(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    /// Media/table/html attachments open on click; images open their info
    /// sheet on double-click so a single click still places the selection.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount <= 2, let core, let layoutManager, let textContainer {
            let point = convert(event.locationInWindow, from: nil)
            let containerPoint = CGPoint(
                x: point.x - textContainerOrigin.x,
                y: point.y - textContainerOrigin.y
            )
            if event.clickCount == 1,
               let todo = core.todoBoxHit(
                   at: containerPoint,
                   layoutManager: layoutManager,
                   container: textContainer
               ),
               core.toggleTodo(at: todo) {
                return
            }
            if let charIndex = attachmentIndex(at: containerPoint),
               core.openAttachment(at: charIndex, includeImages: event.clickCount == 2) {
                return
            }
        }
        super.mouseDown(with: event)
    }

    private func attachmentIndex(at containerPoint: CGPoint) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage else { return nil }
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        let rect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        )
        guard rect.contains(containerPoint) else { return nil }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < storage.length,
              storage.attribute(.attachment, at: charIndex, effectiveRange: nil) != nil
        else { return nil }
        return charIndex
    }

    /// Double-clicking an image opens its info, but nothing advertises that.
    /// Right-click is where a mac user looks for it.
    override func menu(for event: NSEvent) -> NSMenu? {
        let standard = super.menu(for: event)
        let point = convert(event.locationInWindow, from: nil)
        let containerPoint = CGPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        guard let core,
              let charIndex = attachmentIndex(at: containerPoint),
              core.isImageAttachment(at: charIndex)
        else { return standard }
        let menu = standard ?? NSMenu()
        let item = NSMenuItem(
            title: "Get Info",
            action: #selector(showAttachmentInfo(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = charIndex
        menu.insertItem(item, at: 0)
        if standard != nil {
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    @objc private func showAttachmentInfo(_ sender: NSMenuItem) {
        guard let charIndex = sender.representedObject as? Int else { return }
        core?.openAttachment(at: charIndex)
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
    let contextTracker: ContextTracker

    func makeCoordinator() -> Coordinator {
        Coordinator(core: EditorCore(noteUrl: noteUrl, model: model, controller: controller))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = context.coordinator.core.sharedStorage
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
        // image-only pasteboards (screenshots) otherwise fail paste
        // validation and ⌘V just beeps; our paste override intercepts the
        // image before NSTextView's own graphics handling runs
        textView.importsGraphics = true
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
        context.coordinator.core.startContext(contextTracker)
        return scroll
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.core.detachViewFromSharedStorage()
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
            guard layoutFinishedFlag else { return }
            core.inline.setNeedsReconcile()
        }

        func textDidChange(_ notification: Notification) {
            core.textDidChange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            core.refreshFormattingState()
        }

        func textView(_ view: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                return core.handleReturn()
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                return core.nestListItem()
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                return core.unnestListItem()
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
            _ = core.prepareTextSplice(
                range: affectedCharRange,
                replacement: replacementString ?? ""
            )
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

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(handleTabKey)),
            UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(handleShiftTabKey)),
        ]
    }

    @objc private func handleTabKey() { core?.nestListItem() }
    @objc private func handleShiftTabKey() { core?.unnestListItem() }

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

    override func pasteAndMatchStyle(_ sender: Any?) {
        guard let text = UIPasteboard.general.string else {
            super.pasteAndMatchStyle(sender)
            return
        }
        insertText(text)
    }
}

struct RichTextEditor: UIViewRepresentable {
    let noteUrl: String
    let model: NotesModel
    let controller: EditorController
    let contextTracker: ContextTracker

    func makeCoordinator() -> Coordinator {
        Coordinator(core: EditorCore(noteUrl: noteUrl, model: model, controller: controller))
    }

    func makeUIView(context: Context) -> EditorTextView {
        let storage = context.coordinator.core.sharedStorage
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

        let accessory = UIHostingController(
            rootView: FormatAccessoryBar(controller: controller)
        )
        accessory.view.frame = CGRect(x: 0, y: 0, width: 0, height: 46)
        accessory.view.backgroundColor = .clear
        textView.inputAccessoryView = accessory.view
        context.coordinator.accessory = accessory

        context.coordinator.core.view = textView
        context.coordinator.core.load()
        context.coordinator.core.startContext(contextTracker)
        return textView
    }

    static func dismantleUIView(_ uiView: EditorTextView, coordinator: Coordinator) {
        coordinator.core.detachViewFromSharedStorage()
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
        var accessory: UIHostingController<FormatAccessoryBar>?

        init(core: EditorCore) {
            self.core = core
        }

        func layoutManager(
            _ layoutManager: NSLayoutManager,
            didCompleteLayoutFor textContainer: NSTextContainer?,
            atEnd layoutFinishedFlag: Bool
        ) {
            guard layoutFinishedFlag else { return }
            core.inline.setNeedsReconcile()
        }

        func textViewDidChange(_ textView: UITextView) {
            core.textDidChange()
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
            _ = core.prepareTextSplice(range: range, replacement: text)
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
            // If the tap landed on a live inline view (audio, table, etc.),
            // let that view handle the interaction instead of opening a sheet.
            guard !core.inline.hasLiveView(at: point) else { return }
            let containerPoint = CGPoint(
                x: point.x - textView.textContainerInset.left,
                y: point.y - textView.textContainerInset.top
            )
            let layoutManager = textView.layoutManager
            if let todo = core.todoBoxHit(
                at: containerPoint,
                layoutManager: layoutManager,
                container: textView.textContainer
            ), core.toggleTodo(at: todo) {
                return
            }
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

/// Notes-style formatting bar above the keyboard.
struct FormatAccessoryBar: View {
    let controller: EditorController

    var body: some View {
        HStack(spacing: 18) {
            Menu {
                ForEach(EditorController.styles, id: \.key) { style in
                    Button {
                        controller.applyStyle(style.key)
                    } label: {
                        if controller.currentStyleKey == style.key {
                            Label(style.label, systemImage: "checkmark")
                        } else {
                            Text(style.label)
                        }
                    }
                }
            } label: {
                Image(systemName: "textformat")
            }
            Divider()
                .frame(height: 22)
            barButton("bold", active: controller.strongActive) {
                controller.toggleStrong()
            }
            barButton("italic", active: controller.emActive) {
                controller.toggleEm()
            }
            barButton("underline", active: controller.underlineActive) {
                controller.toggleUnderline()
            }
            barButton("strikethrough", active: controller.strikethroughActive) {
                controller.toggleStrikethrough()
            }
            barButton("chevron.left.forwardslash.chevron.right", active: controller.codeActive) {
                controller.toggleCode()
            }
            barButton("textformat.superscript", active: controller.superscriptActive) {
                controller.toggleSuperscript()
            }
            barButton("textformat.subscript", active: controller.subscriptActive) {
                controller.toggleSubscript()
            }
            Menu {
                ForEach(Highlight.names, id: \.self) { name in
                    Button {
                        controller.applyHighlight(name)
                    } label: {
                        if controller.highlightActive == name {
                            Label(name.capitalized, systemImage: "checkmark")
                        } else {
                            Text(name.capitalized)
                        }
                    }
                }
                Divider()
                Button("None") { controller.applyHighlight(nil) }
            } label: {
                Image(systemName: "highlighter")
                    .foregroundStyle(
                        controller.highlightActive != nil ? Color.accentColor : Color.primary
                    )
            }
            Spacer()
            Button {
                controller.dismissKeyboard()
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
            }
        }
        .font(.system(size: 17))
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
        .background(.bar)
    }

    private func barButton(
        _ symbol: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
        }
    }
}

#endif
