import SwiftUI
import CoreText
import ImageIO
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum JSONValue: Codable, Equatable {
    case string(String)
    case int(Int64)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let b = try? single.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? single.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? single.decode(Double.self) {
            self = .number(d)
        } else if let s = try? single.decode(String.self) {
            self = .string(s)
        } else if let a = try? single.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try single.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .string(let s): try single.encode(s)
        case .int(let i): try single.encode(i)
        case .number(let d): try single.encode(d)
        case .bool(let b): try single.encode(b)
        case .null: try single.encodeNil()
        case .array(let a): try single.encode(a)
        case .object(let o): try single.encode(o)
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let i): return Int(exactly: i)
        case .number(let d): return d.isFinite ? Int(exactly: d.rounded()) : nil
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}

/// A to-do item is open, done, abandoned, or waiting on something.
enum TodoState: String, CaseIterable {
    case open
    case checked
    case canceled
    case pending

    var label: String {
        switch self {
        case .open: return "To-do"
        case .checked: return "Done"
        case .canceled: return "Canceled"
        case .pending: return "Pending"
        }
    }
}

struct BlockValue: Codable, Equatable {
    var type: String
    var parents: [String]
    var attrs: [String: JSONValue]
    var isEmbed: Bool

    enum CodingKeys: String, CodingKey {
        case type, parents, attrs, isEmbed
    }

    init(type: String, parents: [String] = [], attrs: [String: JSONValue] = [:], isEmbed: Bool = false) {
        self.type = type
        self.parents = parents
        self.attrs = attrs
        self.isEmbed = isEmbed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "paragraph"
        parents = try c.decodeIfPresent([String].self, forKey: .parents) ?? []
        attrs = try c.decodeIfPresent([String: JSONValue].self, forKey: .attrs) ?? [:]
        isEmbed = try c.decodeIfPresent(Bool.self, forKey: .isEmbed) ?? false
    }

    static let paragraph = BlockValue(type: "paragraph")

    static func heading(level: Int) -> BlockValue {
        BlockValue(type: "heading", attrs: ["level": .int(Int64(level))])
    }

    var headingLevel: Int? {
        guard type == "heading" else { return nil }
        return attrs["level"]?.intValue ?? 1
    }

    var indentLevel: Int {
        attrs["indent"]?.intValue ?? 0
    }

    var isEmbedBlock: Bool {
        isEmbed || type == "embed" || type == "image" || type == "html"
    }

    /// Blocks that live behind a single attachment character and must never
    /// be restyled or split by ordinary text editing.
    var isAtomic: Bool {
        isEmbedBlock || type == "table" || type == "columns"
    }

    var blockquotePath: [String]? {
        if type == "blockquote" {
            return parents + ["blockquote"]
        }
        guard let index = parents.lastIndex(of: "blockquote") else { return nil }
        return Array(parents.prefix(through: index))
    }

    var embedUrl: String? {
        attrs["url"]?.stringValue ?? attrs["src"]?.stringValue
    }

    var altText: String {
        attrs["alt"]?.stringValue ?? ""
    }

    static func embed(url: String) -> BlockValue {
        BlockValue(type: "embed", attrs: ["url": .string(url)], isEmbed: true)
    }

    static func html(_ source: String) -> BlockValue {
        BlockValue(type: "html", attrs: ["html": .string(source)], isEmbed: true)
    }

    var htmlSource: String? {
        attrs["html"]?.stringValue
    }

    /// A to-do item that has been ticked. Absent means unticked.
    var isChecked: Bool {
        todoState == .checked
    }

    var todoState: TodoState {
        guard type == "todo-list-item" else { return .open }
        if let raw = attrs["state"]?.stringValue, let state = TodoState(rawValue: raw) {
            return state
        }
        return attrs["checked"]?.boolValue == true ? .checked : .open
    }

    /// `checked` stays the source of truth for a ticked item so older readers
    /// and the markdown/HTML exporters keep working; the other two states live
    /// in `state`.
    mutating func setTodoState(_ state: TodoState) {
        attrs.removeValue(forKey: "checked")
        attrs.removeValue(forKey: "state")
        switch state {
        case .open: break
        case .checked: attrs["checked"] = .bool(true)
        case .canceled, .pending: attrs["state"] = .string(state.rawValue)
        }
    }

    var codeLanguage: String {
        guard type == "code-block" else { return CodeLanguage.plain.id }
        return CodeLanguage.named(attrs["language"]?.stringValue).id
    }

    static func todo(checked: Bool) -> BlockValue {
        BlockValue(type: "todo-list-item", attrs: checked ? ["checked": .bool(true)] : [:])
    }

    static func todo(state: TodoState) -> BlockValue {
        var block = BlockValue(type: "todo-list-item")
        block.setTodoState(state)
        return block
    }

    /// Stable identifier for the format picker.
    var styleKey: String {
        switch type {
        case "heading": return "heading\(headingLevel ?? 1)"
        case "paragraph" where blockquotePath != nil: return "blockquote"
        default: return type
        }
    }

    static func fromStyleKey(_ key: String) -> BlockValue {
        switch key {
        case "heading1": return .heading(level: 1)
        case "heading2": return .heading(level: 2)
        case "heading3": return .heading(level: 3)
        default: return BlockValue(type: key)
        }
    }
}

enum SpanNode: Codable, Equatable {
    case block(BlockValue)
    case text(String, [String: JSONValue])

    enum CodingKeys: String, CodingKey {
        case type, value, marks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .type)
        if kind == "block" {
            self = .block(try c.decode(BlockValue.self, forKey: .value))
        } else {
            let text = try c.decode(String.self, forKey: .value)
            let marks = try c.decodeIfPresent([String: JSONValue].self, forKey: .marks) ?? [:]
            self = .text(text, marks)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .block(let b):
            try c.encode("block", forKey: .type)
            try c.encode(b, forKey: .value)
        case .text(let text, let marks):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .value)
            if !marks.isEmpty {
                try c.encode(marks, forKey: .marks)
            }
        }
    }

    static func decodeList(_ json: String) -> [SpanNode] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([SpanNode].self, from: data)) ?? []
    }

    static func encodeList(_ spans: [SpanNode]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(spans) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}

extension NSAttributedString.Key {
    static let amBlock = NSAttributedString.Key("io.lush.amBlock")
    /// Marks display-only text (like attachment filenames) that must never
    /// round-trip into the document.
    static let amDisplayOnly = NSAttributedString.Key("io.lush.displayOnly")
    static let amLiveTranscription = NSAttributedString.Key("io.lush.liveTranscription")
    static let amHighlight = NSAttributedString.Key("io.lush.highlight")
    /// "superscript" or "subscript" — the mark behind a shifted baseline.
    static let amBaseline = NSAttributedString.Key("io.lush.baseline")
    static let amTableBox = NSAttributedString.Key("io.lush.tableBox")
    /// Display-only: this paragraph differs from the parent version in the
    /// history viewer; drawn as a margin change bar.
    static let amChanged = NSAttributedString.Key("io.lush.changed")
    static let amColumnsBox = NSAttributedString.Key("io.lush.columnsBox")
    /// Inline code, set by the editor. Read back independently of the font so a
    /// monospaced body font never reads as code.
    static let amCode = NSAttributedString.Key("io.lush.code")
    /// "serif" or "hand" — the mark behind a swapped font family. Read back
    /// from the key, not the font: family names vary by user setting.
    static let amFontRole = NSAttributedString.Key("io.lush.fontRole")
}

/// The spinner a logline wears while its fix and weather are being refreshed.
/// One per rendered line — the view manager keys its host on the instance.
final class LoglineSpinnerBox: NSObject {}

final class LiveTranscriptionBox: NSObject {
    let id: String

    init(id: String) {
        self.id = id
    }
}

/// A columns layout behind one attachment character: per-column span lists
/// (parents prefix stripped), plus the original spans until first edit.
final class ColumnsBox: NSObject {
    var raw: [SpanNode]?
    var columns: [[SpanNode]]

    init(raw: [SpanNode]?, columns: [[SpanNode]]) {
        self.raw = raw
        self.columns = columns
    }

    var spans: [SpanNode] {
        raw ?? RichText.columnsSpans(columns)
    }
}

/// Palette from wordgard rich.css: backgrounds are the hue mixed over the
/// page fill at 16% (light) / 26% (dark), inks are hand-tuned per scheme.
enum Highlight {
    static let names = ["pink", "yellow", "sky", "sea", "mint"]

    private static let palette: [String: (hue: Int, lightInk: Int, darkInk: Int)] = [
        "pink": (0xFF4D97, 0x8D1A4C, 0xFFB0D2),
        "yellow": (0xFFCC33, 0x6B4600, 0xFFDF94),
        "sky": (0x3BA6FF, 0x084881, 0xA8D6FF),
        "sea": (0x4F46E5, 0x312E81, 0x9EA3F5),
        "mint": (0x4FDF9C, 0x0D5C3A, 0xA3F2C8),
    ]

    static func background(_ name: String) -> PColor {
        let entry = palette[name] ?? palette["pink"]!
        return dynamic(
            light: PColor(rgb: entry.hue, alpha: 0.16),
            dark: PColor(rgb: entry.hue, alpha: 0.26)
        )
    }

    static func ink(_ name: String) -> PColor {
        let entry = palette[name] ?? palette["pink"]!
        return dynamic(light: PColor(rgb: entry.lightInk), dark: PColor(rgb: entry.darkInk))
    }

    private static func dynamic(light: PColor, dark: PColor) -> PColor {
        #if os(macOS)
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
        #else
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        }
        #endif
    }
}

struct TableGrid: Equatable {
    var rows: [[[SpanNode]]]
    var hasHeader: Bool

    var columnCount: Int { rows.map(\.count).max() ?? 0 }

    static func empty(rows: Int, columns: Int) -> TableGrid {
        TableGrid(
            rows: Array(repeating: Array(repeating: [], count: columns), count: rows),
            hasHeader: true
        )
    }
}

/// Carries a whole table (as parsed grid + the original spans for a lossless
/// round-trip) behind a single attachment character.
final class TableBox: NSObject {
    var raw: [SpanNode]?
    var grid: TableGrid

    init(raw: [SpanNode]?, grid: TableGrid) {
        self.raw = raw
        self.grid = grid
    }

    var spans: [SpanNode] {
        raw ?? RichText.tableSpans(grid)
    }
}

/// An attachment whose `bounds` is the ideal size; at layout time it scales
/// itself down to fit the line fragment, so images reflow with the column.
/// InlineViewManager also clamps `bounds` to the container width outright
/// (belt and braces — TextKit caches attachment metrics aggressively).
final class FittingImageAttachment: NSTextAttachment {
    var idealSize: CGSize = .zero
    /// Set for asset-backed images: the bounded display bitmap is decoded off
    /// the main thread the first time layout asks for this attachment, and a
    /// flat placeholder stands in until it lands. The full-resolution picture
    /// is never handed to TextKit — scaling a 12-megapixel photo into a
    /// 340-point box costs a decode of the whole thing, on the main thread,
    /// in the middle of a scroll.
    var assetUrl: String?
    var assetCache: AssetCache?

    /// The redraw to run when the in-flight decode lands. TextKit asks for the
    /// image on every frame that draws this fragment, so without somewhere to
    /// collapse them each of those frames queues its own waiter and the decode
    /// arrives as a burst of identical redraws — in the middle of the scroll
    /// this exists to smooth. The newest requester wins: it is the one whose
    /// viewport is on screen.
    private var pendingRefresh: (@MainActor () -> Void)?

    /// One pixel of the colour a picture's slot shows before its bitmap
    /// arrives. Stretched to the attachment's bounds, it reads as a flat
    /// placeholder block and costs nothing to draw. An asset-backed
    /// attachment always carries it, so TextKit never sees an attachment with
    /// nothing to draw and goes looking for a view provider instead.
    static let placeholder: PImage = {
        let size = CGSize(width: 1, height: 1)
        #if os(macOS)
        return NSImage(size: size, flipped: false) { rect in
            NSColor.quaternaryLabelColor.setFill()
            rect.fill()
            return true
        }
        #else
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.quaternaryLabel.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        #endif
    }()

    private func fitted(to lineFrag: CGRect, padding: CGFloat) -> CGRect {
        var size = bounds.size
        let available = lineFrag.width - padding * 2
        if available > 40, size.width > available, size.width > 0 {
            let scale = available / size.width
            size = CGSize(width: available, height: size.height * scale)
        }
        return CGRect(origin: bounds.origin, size: size)
    }

    /// The bounds come from the picture's recorded pixel size and the decoded
    /// bitmap matches its aspect, so landing a decode never moves layout — the
    /// refresh only redraws the attachment's fragment.
    private func resolveDisplayImage(refresh: @escaping @MainActor () -> Void) -> PImage? {
        var resolved = image
        guard let url = assetUrl else { return resolved }
        MainActor.assumeIsolated {
            guard let cache = assetCache else { return }
            // resolved through the cache every draw and never held here: an
            // attachment that kept its own bitmap would pin one per picture in
            // the note, and the cache's ceiling would mean nothing
            if let display = cache.displayImage(for: url) {
                resolved = display
                return
            }
            resolved = Self.placeholder
            let alreadyWaiting = pendingRefresh != nil
            pendingRefresh = refresh
            guard !alreadyWaiting else { return }
            cache.ensureDisplayImage(for: url) { [weak self] display in
                guard let self else { return }
                let pending = self.pendingRefresh
                self.pendingRefresh = nil
                guard display != nil else { return }
                pending?()
            }
        }
        return resolved
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        fitted(to: lineFrag, padding: textContainer?.lineFragmentPadding ?? 5)
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        fitted(to: proposedLineFragment, padding: textContainer?.lineFragmentPadding ?? 5)
    }

    override func image(
        forBounds imageBounds: CGRect,
        textContainer: NSTextContainer?,
        characterIndex charIndex: Int
    ) -> PImage? {
        guard assetUrl != nil else {
            return super.image(
                forBounds: imageBounds,
                textContainer: textContainer,
                characterIndex: charIndex
            )
        }
        return resolveDisplayImage { [weak textContainer] in
            textContainer?.layoutManager?.invalidateDisplay(
                forCharacterRange: NSRange(location: charIndex, length: 1)
            )
        }
    }

    override func image(
        for bounds: CGRect,
        attributes: [NSAttributedString.Key: Any],
        location: NSTextLocation,
        textContainer: NSTextContainer?
    ) -> PImage? {
        guard assetUrl != nil else {
            return super.image(
                for: bounds,
                attributes: attributes,
                location: location,
                textContainer: textContainer
            )
        }
        // rendering attributes and a viewport pass, not a layout invalidation:
        // the fragment is already the right height, and re-laying it out under
        // a scroll re-measures the document out from under the scroll view
        return resolveDisplayImage { [weak textContainer] in
            guard let layoutManager = textContainer?.textLayoutManager,
                  let contentManager = layoutManager.textContentManager,
                  let end = contentManager.location(location, offsetBy: 1),
                  let range = NSTextRange(location: location, end: end)
            else { return }
            layoutManager.invalidateRenderingAttributes(for: range)
            layoutManager.textViewportLayoutController.layoutViewport()
        }
    }
}

/// An attachment whose live view comes from the editor showing it: the view
/// provider resolves through the requesting text view's core, so each window
/// keeps its own hosted view over the same shared storage.
final class EmbedAttachment: NSTextAttachment {
    let box: AnyObject

    init(box: AnyObject) {
        self.box = box
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) {
        box = NSObject()
        super.init(coder: coder)
    }

    override func viewProvider(
        for parentView: PView?,
        location: NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        var provider: NSTextAttachmentViewProvider?
        MainActor.assumeIsolated {
            // on iOS the parent is an internal container view, not the text
            // view itself — walk up to the editor
            var candidate: PView? = parentView
            while let view = candidate {
                if let editor = view as? EditorTextView {
                    provider = editor.core?.inline.viewProvider(
                        for: self,
                        location: location,
                        textContainer: textContainer
                    )
                    break
                }
                if let host = view as? InlineViewManaging,
                   let manager = host.inlineManager {
                    provider = manager.viewProvider(
                        for: self,
                        location: location,
                        textContainer: textContainer
                    )
                    break
                }
                candidate = view.superview
            }
        }
        return provider
    }
}

final class BlockBox: NSObject {
    var value: BlockValue
    init(_ value: BlockValue) { self.value = value }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? BlockBox)?.value == value
    }

    override var hash: Int { value.type.hashValue }
}

/// A bounded store for asset bytes. A Dictionary of photos never gives
/// anything back; NSCache drops its contents under pressure and
/// `AssetCache.bytes(for:)` re-maps the spill file after it does.
final class AssetByteStore {
    private let cache = NSCache<NSString, NSData>()

    init(limit: Int) { cache.totalCostLimit = limit }

    subscript(url: String) -> Data? {
        get { cache.object(forKey: url as NSString).map { $0 as Data } }
        set {
            let key = url as NSString
            guard let newValue else {
                cache.removeObject(forKey: key)
                return
            }
            cache.setObject(newValue as NSData, forKey: key, cost: newValue.count)
        }
    }
}

@MainActor
final class AssetCache {
    let imageData = AssetByteStore(limit: 64 << 20)
    /// Where each asset's bytes were spilled, so a dropped cache entry costs a
    /// page-in rather than a round trip through the core. Paths only.
    private var spillFiles: [String: URL] = [:]
    /// The pixel size of each stored image. An attachment lays out against
    /// this, so nothing has to hold a full-resolution bitmap to know how much
    /// room a picture takes.
    var imageSizes: [String: CGSize] = [:]
    var names: [String: String] = [:]
    var fileURLs: [String: URL] = [:]
    var videoThumbs: [String: PImage] = [:]
    /// Embedded automerge docs that aren't file assets — rendered by the
    /// patchwork web runtime instead of natively.
    var patchworkDocs: Set<String> = []
    var transcripts: [String: String] = [:]

    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aac", "caf", "aiff"]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "mpg", "mpeg"]

    /// The widest a picture is ever drawn, in device pixels — `RichText.fitted`
    /// caps the point size and the densest screen either platform ships is 3x.
    /// A bitmap bigger than this is memory nothing can see.
    #if os(macOS)
    nonisolated static let displayMaxPixels = 420 * 2
    #else
    /// The cap is in pixels, so the UIImage carries the matching scale —
    /// without it the picture measures three times its point size.
    nonisolated static let displayScale: CGFloat = 3
    nonisolated static let displayMaxPixels = Int(340 * displayScale)
    #endif

    private static let displayImages: NSCache<NSString, PImage> = {
        let cache = NSCache<NSString, PImage>()
        // a phone's whole budget is a couple of hundred megabytes; the old
        // 384MB ceiling was one no device could ever reach without being
        // killed on the way
        #if os(macOS)
        cache.totalCostLimit = 384 << 20
        #else
        cache.totalCostLimit = 64 << 20
        #endif
        return cache
    }()

    private static var decodesInFlight: [String: [@MainActor (PImage?) -> Void]] = [:]

    func displayImage(for url: String) -> PImage? {
        Self.displayImages.object(forKey: url as NSString)
    }

    /// Whether this url is an image we can still produce. The size alone is not
    /// enough: bytes are evictable, so an entry whose spill never landed can
    /// lose them for good. Saying no here sends it back through
    /// `fetchMissingAssets`, which stores it again. Layout reads `imageSizes`
    /// directly, so a picture never reflows over this.
    func isImage(_ url: String) -> Bool {
        imageSizes[url] != nil && (spillFiles[url] != nil || imageData[url] != nil)
    }

    /// The picture at its own resolution, for the info sheet and the
    /// clipboard. Decoded on the spot and never held: one of these is worth
    /// tens of the bounded bitmaps the editor draws.
    func fullImage(for url: String) -> PImage? {
        bytes(for: url).flatMap(PImage.init(data:))
    }

    /// An asset's bytes, re-mapping the spill file when the cache has dropped
    /// them. The file outlives the cache entry, so a drop costs a page-in
    /// rather than another trip through the core.
    func bytes(for url: String) -> Data? {
        if let cached = imageData[url] { return cached }
        guard let file = spillFiles[url],
              let mapped = try? Data(contentsOf: file, options: .mappedIfSafe)
        else { return nil }
        imageData[url] = mapped
        return mapped
    }

    /// Keep the bytes and the picture's dimensions. Deliberately not the
    /// decoded bitmap: a photo off a phone camera costs ~48MB decoded, and a
    /// note full of them is what runs the app out of memory.
    @discardableResult
    func storeImage(_ data: Data, for url: String) -> CGSize? {
        guard let size = PImage(data: data)?.size, size.width > 0, size.height > 0
        else { return nil }
        imageSizes[url] = size
        // Spill to the file audio and video already use and keep the mapped
        // copy. Mapped pages are clean, so the kernel can reclaim them; a heap
        // copy of every photo in the note is what it cannot.
        if let file = Self.mediaFile(for: url, name: "image", data: data),
           let mapped = try? Data(contentsOf: file, options: .mappedIfSafe) {
            spillFiles[url] = file
            imageData[url] = mapped
        } else {
            imageData[url] = data
        }
        return size
    }

    /// Decode the bounded display bitmap off the main thread, once per url no
    /// matter how many fragments ask while it's in flight. `onReady` runs on
    /// the main actor with nil when there's nothing to decode.
    func ensureDisplayImage(for url: String, onReady: @escaping @MainActor (PImage?) -> Void) {
        if let display = displayImage(for: url) {
            onReady(display)
            return
        }
        guard let data = bytes(for: url) else {
            onReady(nil)
            return
        }
        if Self.decodesInFlight[url] != nil {
            Self.decodesInFlight[url]?.append(onReady)
            return
        }
        Self.decodesInFlight[url] = [onReady]
        Task.detached(priority: .userInitiated) {
            let display = Self.decodeDisplay(data)
            await MainActor.run {
                if let display {
                    Self.displayImages.setObject(
                        display.image,
                        forKey: url as NSString,
                        cost: display.cost
                    )
                }
                for waiter in Self.decodesInFlight.removeValue(forKey: url) ?? [] {
                    waiter(display?.image)
                }
            }
        }
    }

    func displayImage(ensureFor url: String) async -> PImage? {
        await withCheckedContinuation { continuation in
            ensureDisplayImage(for: url) { continuation.resume(returning: $0) }
        }
    }

    nonisolated private static func decodeDisplay(_ data: Data) -> (image: PImage, cost: Int)? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            sourceOptions as CFDictionary
        ) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: displayMaxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else { return nil }
        #if os(macOS)
        let image = NSImage(cgImage: thumbnail, size: .zero)
        #else
        let image = UIImage(cgImage: thumbnail, scale: displayScale, orientation: .up)
        #endif
        return (image, thumbnail.bytesPerRow * thumbnail.height)
    }

    /// Spill an asset's bytes to the caches directory and hand back the file,
    /// so it can be mapped instead of held, and so AVFoundation has a URL.
    nonisolated static func mediaFile(for assetUrl: String, name: String, data: Data) -> URL? {
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

    static func kind(forName name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if audioExtensions.contains(ext) { return "audio" }
        if videoExtensions.contains(ext) { return "video" }
        return "file"
    }
}

/// Per-family corrections. Two families set at the same point size rarely look
/// the same size, and their "regular" and "bold" faces rarely match in colour,
/// so each family carries a scale and a pair of weights.
struct FontAdjustment: Codable, Hashable {
    var scale: Double
    var regularWeight: Double?
    var boldWeight: Double?

    static let none = FontAdjustment(scale: 1, regularWeight: nil, boldWeight: nil)

    static let weights: [(value: Double, label: String)] = [
        (100, "Thin"),
        (200, "Extra Light"),
        (300, "Light"),
        (400, "Regular"),
        (500, "Medium"),
        (600, "Semibold"),
        (700, "Bold"),
        (800, "Extra Bold"),
        (900, "Black"),
    ]

    static func label(for weight: Double?) -> String {
        guard let weight else { return "Automatic" }
        return weights.first { $0.value == weight }?.label ?? "\(Int(weight))"
    }

    init(scale: Double = 1, regularWeight: Double? = nil, boldWeight: Double? = nil) {
        self.scale = scale
        self.regularWeight = regularWeight
        self.boldWeight = boldWeight
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        regularWeight = try c.decodeIfPresent(Double.self, forKey: .regularWeight)
        boldWeight = try c.decodeIfPresent(Double.self, forKey: .boldWeight)
    }
}

/// User-adjustable editor typography, persisted in UserDefaults. Views that
/// render text re-load when `changed` is posted.
enum EditorTextSize: String, CaseIterable, Identifiable {
    case extraSmall
    case small
    case medium
    case large
    case extraLarge

    var id: String { rawValue }

    var label: String {
        switch self {
        case .extraSmall: "XS"
        case .small: "S"
        case .medium: "M"
        case .large: "L"
        case .extraLarge: "XL"
        }
    }

    var points: Double {
        #if os(iOS)
        switch self {
        case .extraSmall: 15.5
        case .small: 17
        case .medium: 19
        case .large: 21
        case .extraLarge: 23
        }
        #else
        switch self {
        case .extraSmall: 12.5
        case .small: 14
        case .medium: 16
        case .large: 18
        case .extraLarge: 20
        }
        #endif
    }
}

enum EditorSettings {
    static let changed = Notification.Name("io.lush.editorSettingsChanged")
    static let systemFontFamily = "__system__"
    private static let bundledFonts = [
        "Caroni-Regular.otf",
        "FantasqueSansMono-Regular.ttf",
        "FantasqueSansMono-Bold.ttf",
        "FantasqueSansMono-Italic.ttf",
        "FantasqueSansMono-BoldItalic.ttf",
        "jost-vf.ttf",
        "Merriweather-VariableFont_opsz,wdth,wght.ttf",
        "Merriweather-Italic-VariableFont_opsz,wdth,wght.ttf",
    ]
    private static let sizeKey = "editorBodySize"
    private static let textSizeKey = "editorTextSize"
    private static let designKey = "editorFontDesign"
    private static let sansFamilyKey = "editorSansFamily"
    private static let serifFamilyKey = "editorSerifFamily"
    private static let monoFamilyKey = "editorMonoFamily"
    private static let handFamilyKey = "editorHandFamily"
    private static let adjustmentsKey = "fontAdjustments"
    private static let autoInsertLoglineKey = "editorAutoInsertLogline"
    static let maxNoteCharactersKey = "editorMaxNoteCharacters"
    static let minimapKey = "editorMinimapVisible"

    static let fontFamilies: [(key: String, label: String)] = [
        ("sans", "Sans"),
        ("serif", "Serif"),
        ("mono", "Mono"),
        ("hand", "Hand"),
    ]

    private static let legacyNamedFonts: [String: String] = [
        "georgia": "Georgia",
        "palatino": "Palatino",
        "baskerville": "Baskerville",
        "times": "Times New Roman",
        "didot": "Didot",
        "helvetica": "Helvetica Neue",
        "avenir": "Avenir Next",
        "optima": "Optima",
        "typewriter": "American Typewriter",
        "courier": "Courier New",
        "menlo": "Menlo",
    ]

    static var defaultBodySize: Double {
        #if os(iOS)
        17
        #else
        14
        #endif
    }

    // Rendering a document asks for these once per attribute run, so they are
    // read from UserDefaults once and dropped when a setter changes them.
    private static var cachedBodySize: Double?
    private static var cachedFamilies: [String: String] = [:]
    private static var cachedAdjustments: [String: FontAdjustment]?
    private static var fontCache: [FontKey: PFont] = [:]
    private static var bundledFontsRegistered = false

    private struct FontKey: Hashable {
        let role: String
        let family: String
        let adjustment: FontAdjustment
        let size: CGFloat
        let weight: CGFloat
    }

    private static func invalidateTypography() {
        cachedBodySize = nil
        cachedFamilies = [:]
        cachedAdjustments = nil
        fontCache = [:]
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static var bodySize: Double {
        let base: Double
        if let cachedBodySize {
            base = cachedBodySize
        } else {
            base = textSize.points
            cachedBodySize = base
        }
        #if os(iOS)
        return Double(UIFontMetrics(forTextStyle: .body).scaledValue(for: CGFloat(base)))
        #else
        return base
        #endif
    }

    static var textSize: EditorTextSize {
        if let raw = UserDefaults.standard.string(forKey: textSizeKey),
           let size = EditorTextSize(rawValue: raw) {
            return size
        }
        let saved = UserDefaults.standard.double(forKey: sizeKey)
        guard saved > 0 else { return .medium }
        return EditorTextSize.allCases.min {
            abs($0.points - saved) < abs($1.points - saved)
        } ?? .medium
    }

    static func setTextSize(_ size: EditorTextSize) {
        UserDefaults.standard.set(size.rawValue, forKey: textSizeKey)
        invalidateTypography()
    }

    static func refreshDynamicType() {
        invalidateTypography()
    }

    static var availableFontFamilies: [String] {
        registerBundledFonts()
        #if os(macOS)
        return NSFontManager.shared.availableFontFamilies.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        #else
        return UIFont.familyNames.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        #endif
    }

    static func family(for key: String) -> String {
        if let cached = cachedFamilies[key] { return cached }
        let saved = UserDefaults.standard.string(forKey: familyDefaultsKey(for: key))
        let family = saved ?? legacyDefaultFamily(for: key)
        cachedFamilies[key] = family
        return family
    }

    static func setFamily(_ family: String, for key: String) {
        UserDefaults.standard.set(family, forKey: familyDefaultsKey(for: key))
        invalidateTypography()
    }

    static var design: String {
        UserDefaults.standard.string(forKey: designKey) ?? "system"
    }

    static func setDesign(_ design: String) {
        setFamily(legacyFamilyName(for: design), for: "sans")
    }

    static var autoInsertLogline: Bool {
        UserDefaults.standard.bool(forKey: autoInsertLoglineKey)
    }

    static func setAutoInsertLogline(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: autoInsertLoglineKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// How many characters wide a note's text may get before it stops growing
    /// and centres. Zero fills the editor.
    static var maxNoteCharacters: Int {
        UserDefaults.standard.integer(forKey: maxNoteCharactersKey)
    }

    static func setMaxNoteCharacters(_ characters: Int) {
        UserDefaults.standard.set(characters, forKey: maxNoteCharactersKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// The character measure in points, at the body font and size. Zero when
    /// notes fill the editor.
    static var maxNoteWidth: CGFloat {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .pad else { return 0 }
        #endif
        let characters = maxNoteCharacters
        guard characters > 0 else { return 0 }
        let advance = ("0" as NSString)
            .size(withAttributes: [.font: font(ofSize: bodySize)])
            .width
        return CGFloat(characters) * advance
    }

    static var minimapVisible: Bool {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .pad else { return false }
        #endif
        return UserDefaults.standard.bool(forKey: minimapKey)
    }

    static func setMinimapVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: minimapKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func font(
        family key: String = "sans",
        ofSize size: CGFloat,
        weight: PFont.Weight = .regular
    ) -> PFont {
        let family = family(for: key)
        return font(
            role: key,
            family: family,
            adjustment: adjustment(family: family, role: key),
            ofSize: size,
            weight: weight
        )
    }

    /// Resolution with the adjustment passed in, so a preview can render a
    /// setting the user has not committed yet.
    static func font(
        role: String,
        family: String,
        adjustment: FontAdjustment,
        ofSize size: CGFloat,
        weight: PFont.Weight = .regular
    ) -> PFont {
        let cacheKey = FontKey(
            role: role,
            family: family,
            adjustment: adjustment,
            size: size,
            weight: weight.rawValue
        )
        if let hit = fontCache[cacheKey] { return hit }
        let resolved = resolveFont(
            family: family,
            role: role,
            adjustment: adjustment,
            ofSize: size * adjustment.scale,
            weight: weight
        )
        fontCache[cacheKey] = resolved
        return resolved
    }

    /// System choices are stored per role — a role falling back to the system
    /// serif is a different typeface from one falling back to the system sans.
    static func adjustmentKey(family: String, role: String) -> String {
        family == systemFontFamily ? "system:\(role.isEmpty ? "sans" : role)" : family
    }

    static func adjustment(family: String, role: String = "") -> FontAdjustment {
        let key = adjustmentKey(family: family, role: role)
        if let stored = storedAdjustments[key] { return stored }
        return defaultAdjustments[key] ?? .none
    }

    static func setAdjustment(_ adjustment: FontAdjustment, family: String, role: String) {
        var all = storedAdjustments
        all[adjustmentKey(family: family, role: role)] = adjustment
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: adjustmentsKey)
        }
        invalidateTypography()
    }

    private static var storedAdjustments: [String: FontAdjustment] {
        if let cachedAdjustments { return cachedAdjustments }
        let data = UserDefaults.standard.data(forKey: adjustmentsKey)
        let all = data.flatMap { try? JSONDecoder().decode([String: FontAdjustment].self, from: $0) } ?? [:]
        cachedAdjustments = all
        return all
    }

    private static func familyDefaultsKey(for key: String) -> String {
        switch key {
        case "serif": serifFamilyKey
        case "mono": monoFamilyKey
        case "hand": handFamilyKey
        default: sansFamilyKey
        }
    }

    private static func legacyDefaultFamily(for key: String) -> String {
        switch key {
        case "sans": return legacyFamilyName(for: design)
        case "serif": return "Merriweather"
        case "mono": return "Fantasque Sans Mono"
        case "hand": return "Caroni"
        default: return systemFontFamily
        }
    }

    private static func legacyFamilyName(for design: String) -> String {
        legacyNamedFonts[design] ?? "Jost*"
    }

    private static func resolveFont(
        family: String,
        role: String,
        adjustment: FontAdjustment,
        ofSize size: CGFloat,
        weight: PFont.Weight
    ) -> PFont {
        registerBundledFonts()
        let base = baseFont(family: family, role: role, ofSize: size, weight: weight)
        let override: Double?
        if weight.rawValue >= PFont.Weight.semibold.rawValue {
            override = adjustment.boldWeight
        } else if weight == .regular {
            override = adjustment.regularWeight
        } else {
            override = nil
        }
        if let override { return weighted(base, to: override) }
        return base
    }

    private static func baseFont(
        family: String,
        role: String,
        ofSize size: CGFloat,
        weight: PFont.Weight
    ) -> PFont {
        if family != systemFontFamily,
           let resolved = font(namedFamily: family, size: size, weight: weight) {
            return resolved
        }
        if role == "serif" {
            return systemFont(ofSize: size, weight: weight, design: .serif)
        }
        if role == "mono" {
            return .monospacedSystemFont(ofSize: size, weight: weight)
        }
        if role == "hand", let hand = defaultHandFont(ofSize: size, weight: weight) {
            return hand
        }
        return .systemFont(ofSize: size, weight: weight)
    }

    private static func systemFont(
        ofSize size: CGFloat,
        weight: PFont.Weight,
        design: PFontDescriptor.SystemDesign
    ) -> PFont {
        let base = PFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        #if os(macOS)
        return PFont(descriptor: descriptor, size: size) ?? base
        #else
        return PFont(descriptor: descriptor, size: size)
        #endif
    }

    private static func font(namedFamily family: String, size: CGFloat, weight: PFont.Weight) -> PFont? {
        let descriptor = PFontDescriptor(fontAttributes: [.family: family])
        let matches = descriptor.matchingFontDescriptors(withMandatoryKeys: [.family])
        let baseDescriptor = matches.first ?? descriptor
        #if os(macOS)
        guard let font = PFont(descriptor: baseDescriptor, size: size) else { return nil }
        #else
        let font = PFont(descriptor: baseDescriptor, size: size)
        #endif
        return weight.rawValue > 0 ? styled(font, bold: true, italic: false) : font
    }

    /// Starting points for the families Lush ships, so the bundled pairing
    /// reads evenly before anyone opens the font settings.
    private static let defaultAdjustments: [String: FontAdjustment] = [
        "Jost*": FontAdjustment(boldWeight: 600),
        "Merriweather": FontAdjustment(scale: 0.94, regularWeight: 300, boldWeight: 600),
        "Caroni": FontAdjustment(scale: 1.15),
    ]

    private static let weightAxis = 2003265652
    private static let variationAttribute = PFontDescriptor.AttributeName(
        rawValue: kCTFontVariationAttribute as String
    )

    static func styled(_ font: PFont, bold: Bool, italic: Bool) -> PFont {
        let traited = font.addingTraits(bold: bold, italic: italic)
        guard bold,
              let family = font.pFamilyName,
              let weight = adjustment(family: family).boldWeight
        else { return traited }
        return weighted(traited, to: weight)
    }

    /// Both a variation axis (for variable families) and a weight trait (to
    /// pick the nearest static face), so one call covers either kind.
    static func weighted(_ font: PFont, to weight: Double) -> PFont {
        guard let family = font.pFamilyName else { return font }
        let attributes: [PFontDescriptor.AttributeName: Any] = [
            .family: family,
            .traits: [PFontDescriptor.TraitKey.weight: platformWeight(weight).rawValue],
            variationAttribute: [weightAxis: weight],
        ]
        let base = PFontDescriptor(fontAttributes: attributes)
        #if os(macOS)
        var traits = font.fontDescriptor.symbolicTraits
        traits.remove(.bold)
        let descriptor = base.withSymbolicTraits(traits)
        return PFont(descriptor: descriptor, size: font.pointSize) ?? font
        #else
        var traits = font.fontDescriptor.symbolicTraits
        traits.remove(.traitBold)
        let descriptor = base.withSymbolicTraits(traits) ?? base
        return PFont(descriptor: descriptor, size: font.pointSize)
        #endif
    }

    static func platformWeight(_ weight: Double) -> PFont.Weight {
        switch weight {
        case ..<150: .ultraLight
        case ..<250: .thin
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        case ..<850: .heavy
        default: .black
        }
    }

    private static func defaultHandFont(ofSize size: CGFloat, weight: PFont.Weight) -> PFont? {
        for family in ["Caroni", "Snell Roundhand", "Bradley Hand", "Marker Felt", "Chalkboard SE"] {
            if let font = font(namedFamily: family, size: size, weight: weight) {
                return font
            }
        }
        return nil
    }

    static func registerBundledFonts() {
        guard !bundledFontsRegistered else { return }
        bundledFontsRegistered = true
        for filename in bundledFonts {
            let basename = (filename as NSString).deletingPathExtension
            let ext = (filename as NSString).pathExtension
            let url = Bundle.main.url(forResource: basename, withExtension: ext)
                ?? Bundle.main.url(forResource: basename, withExtension: ext, subdirectory: "fonts")
            guard let url else {
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

enum RichText {
    private static let loadingEmbedImage = PImage.draw(size: CGSize(width: 460, height: 140)) { context in
        context.setFillColor(PColor.pSecondaryLabel.withAlphaComponent(0.12).cgColor)
        context.addPath(CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: 460, height: 140),
            cornerWidth: 8,
            cornerHeight: 8,
            transform: nil
        ))
        context.fillPath()
    }

    static var bodySize: CGFloat { EditorSettings.bodySize }

    /// The families a `font` mark may name.
    static let fontRoles: [(key: String, label: String)] = [
        ("serif", "Serif"),
        ("hand", "Hand"),
    ]

    private static func fontMetrics(for block: BlockValue) -> (size: CGFloat, weight: PFont.Weight) {
        switch block.type {
        case "heading":
            switch block.headingLevel ?? 1 {
            case 1: return (bodySize * 1.6, .bold)
            case 2: return (bodySize * 1.3, .bold)
            default: return (bodySize * 1.15, .semibold)
            }
        case "code-block":
            return (bodySize * 0.92, .regular)
        default:
            return (bodySize, .regular)
        }
    }

    /// "serif" and "hand" are block types in documents written before they
    /// became marks. They still render; nothing writes them any more.
    static func baseFont(for block: BlockValue, marks: [String: JSONValue] = [:]) -> PFont {
        let (size, weight) = fontMetrics(for: block)
        if let role = marks["font"]?.stringValue,
           fontRoles.contains(where: { $0.key == role }) {
            return EditorSettings.font(family: role, ofSize: size, weight: weight)
        }
        switch block.type {
        case "serif": return EditorSettings.font(family: "serif", ofSize: size)
        case "hand": return EditorSettings.font(family: "hand", ofSize: size)
        case "code-block": return EditorSettings.font(family: "mono", ofSize: size)
        default: return EditorSettings.font(ofSize: size, weight: weight)
        }
    }

    private struct ParagraphKey: Hashable {
        let type: String
        let parents: [String]
        let indentLevel: Int
    }

    private static var paragraphStyleCache: [ParagraphKey: NSParagraphStyle] = [:]

    static func paragraphStyle(for block: BlockValue) -> NSParagraphStyle {
        let key = ParagraphKey(type: block.type, parents: block.parents, indentLevel: block.indentLevel)
        if let hit = paragraphStyleCache[key] { return hit }
        let style = buildParagraphStyle(for: block)
        paragraphStyleCache[key] = style
        return style
    }

    private static func buildParagraphStyle(for block: BlockValue) -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.paragraphSpacing = 0
        var indent: CGFloat = 0
        // nested structures (list nesting, columns, table cells) indent by depth
        let listDepth = block.parents.filter {
            $0 == "unordered-list-item" || $0 == "ordered-list-item" || $0 == "todo-list-item"
        }.count
        let quoteDepth = block.parents.filter { $0 == "blockquote" }.count
        indent += CGFloat(block.parents.count - listDepth - quoteDepth) * 20
        indent += CGFloat(listDepth) * 28
        indent += CGFloat(quoteDepth) * 16
        indent += CGFloat(block.indentLevel) * 20
        switch block.type {
        case "heading":
            ps.paragraphSpacingBefore = 10
            ps.paragraphSpacing = 6
        case "unordered-list-item", "ordered-list-item", "todo-list-item":
            indent += 28
        case "blockquote":
            indent += 16
        case "code-block":
            // room inside the card, tight lines within it
            indent += 12
        default:
            break
        }
        ps.firstLineHeadIndent = indent
        ps.headIndent = indent
        return ps
    }

    static func attributes(block: BlockValue, marks: [String: JSONValue]) -> [NSAttributedString.Key: Any] {
        var font = baseFont(for: block, marks: marks)
        var bold = false
        var italic = false
        if case .bool(true)? = marks["strong"], block.type != "heading" {
            bold = true
        }
        if case .bool(true)? = marks["em"] {
            italic = true
        }
        if bold || italic {
            font = EditorSettings.styled(font, bold: bold, italic: italic)
        }
        if case .bool(true)? = marks["code"] {
            let size = font.pointSize - 1
            font = EditorSettings.styled(
                EditorSettings.font(family: "mono", ofSize: size),
                bold: bold,
                italic: italic
            )
        }
        var out: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle(for: block),
            .foregroundColor: PColor.pLabel,
            .amBlock: BlockBox(block),
        ]
        if case .bool(true)? = marks["code"] {
            out[.backgroundColor] = CodeHighlight.cardBackground
            out[.amCode] = true
        }
        if let role = marks["font"]?.stringValue,
           fontRoles.contains(where: { $0.key == role }) {
            out[.amFontRole] = role
        }
        if let name = marks["highlight"]?.stringValue {
            out[.amHighlight] = name
            out[.backgroundColor] = Highlight.background(name)
            out[.foregroundColor] = Highlight.ink(name)
        }
        if case .bool(true)? = marks["underline"] {
            out[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if case .bool(true)? = marks["strikethrough"] {
            out[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        // Sub- and superscript are a smaller font on a shifted baseline. The
        // custom key is what reads back: the offset alone would also match
        // text that merely sits on a different baseline.
        if case .bool(true)? = marks["superscript"] {
            out[.amBaseline] = "superscript"
            out[.font] = font.withSize(font.pointSize * 0.72)
            out[.baselineOffset] = font.pointSize * 0.38
        } else if case .bool(true)? = marks["subscript"] {
            out[.amBaseline] = "subscript"
            out[.font] = font.withSize(font.pointSize * 0.72)
            out[.baselineOffset] = -font.pointSize * 0.18
        }
        if let link = marks["link"]?.stringValue, let url = URL(string: link) {
            out[.link] = url
            out[.foregroundColor] = PColor.pTint
            out[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return out
    }

    static func marks(from attrs: [NSAttributedString.Key: Any], block: BlockValue) -> [String: JSONValue] {
        var marks: [String: JSONValue] = [:]
        if let font = attrs[.font] as? PFont {
            if font.hasBoldTrait, block.type != "heading" {
                marks["strong"] = .bool(true)
            }
            if font.hasItalicTrait {
                marks["em"] = .bool(true)
            }
        }
        if block.type != "code-block", attrs[.amCode] != nil {
            marks["code"] = .bool(true)
        }
        if let link = attrs[.link] {
            if let url = link as? URL {
                marks["link"] = .string(url.absoluteString)
            } else if let s = link as? String {
                marks["link"] = .string(s)
            }
        }
        if let name = attrs[.amHighlight] as? String {
            marks["highlight"] = .string(name)
        }
        // A link draws itself underlined, so only text that isn't a link can
        // claim the underline mark.
        if attrs[.link] == nil, let style = attrs[.underlineStyle] as? Int, style != 0 {
            marks["underline"] = .bool(true)
        }
        if let style = attrs[.strikethroughStyle] as? Int, style != 0 {
            marks["strikethrough"] = .bool(true)
        }
        if let baseline = attrs[.amBaseline] as? String {
            marks[baseline] = .bool(true)
        }
        if let role = attrs[.amFontRole] as? String {
            marks["font"] = .string(role)
        }
        return marks
    }

    private static func legacyMarks(_ font: String?) -> [String: JSONValue] {
        font.map { ["font": .string($0)] } ?? [:]
    }

    @MainActor
    static func attributed(from spans: [SpanNode], cache: AssetCache) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var block = BlockValue.paragraph
        // legacy serif/hand blocks become paragraphs carrying a font mark, so
        // the family survives being made a list item or a heading
        var legacyFont: String?
        var sawAnything = false
        var i = 0
        while i < spans.count {
            let node = spans[i]
            if case .block(let b) = node, b.type == "table" || b.type == "columns" {
                let root = b.type
                var j = i + 1
                collecting: while j < spans.count {
                    switch spans[j] {
                    case .block(let child):
                        guard child.parents.first == root else { break collecting }
                        j += 1
                    case .text:
                        j += 1
                    }
                }
                let slice = Array(spans[i..<j])
                if sawAnything {
                    out.append(NSAttributedString(
                        string: "\n",
                        attributes: attributes(block: block, marks: [:])
                    ))
                }
                if root == "table" {
                    out.append(tableAttachment(for: TableBox(raw: slice, grid: parseTable(slice))))
                } else {
                    out.append(columnsAttachment(
                        for: ColumnsBox(raw: slice, columns: parseColumns(slice))
                    ))
                }
                block = BlockValue(type: root)
                legacyFont = nil
                sawAnything = true
                i = j
                continue
            }
            switch node {
            case .block(let b):
                if sawAnything {
                    out.append(NSAttributedString(
                        string: "\n",
                        attributes: attributes(block: block, marks: legacyMarks(legacyFont))
                    ))
                }
                if b.type == "serif" || b.type == "hand" {
                    legacyFont = b.type
                    block = BlockValue(
                        type: "paragraph",
                        parents: b.parents,
                        attrs: b.attrs,
                        isEmbed: b.isEmbed
                    )
                } else {
                    legacyFont = nil
                    block = b
                }
                sawAnything = true
                if b.type == "context" {
                    out.append(contextLine(for: b))
                } else if b.isEmbedBlock {
                    out.append(embedAttachment(for: b, cache: cache))
                }
            case .text(let text, let marks):
                guard !block.isEmbedBlock else { break }
                var marks = marks
                if let legacyFont, marks["font"] == nil { marks["font"] = .string(legacyFont) }
                out.append(NSAttributedString(
                    string: text,
                    attributes: attributes(block: block, marks: marks)
                ))
                sawAnything = true
            }
            i += 1
        }
        return out
    }

    @MainActor
    static func contextLine(for block: BlockValue) -> NSAttributedString {
        let attrs = contextDisplayAttributes(for: block)
        let line = NSMutableAttributedString()
        let parts = contextLineParts(for: block)
        for (index, part) in parts.enumerated() {
            if index > 0 {
                line.append(NSAttributedString(string: " | ", attributes: attrs))
            }
            var partAttrs = attrs
            if part.isLocation, let url = mapsURL(for: block, location: part.text) {
                partAttrs[.link] = url
                partAttrs[.foregroundColor] = PColor.pTint
                partAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            line.append(NSAttributedString(string: part.text, attributes: partAttrs))
        }
        if line.length == 0 {
            line.append(NSAttributedString(string: "Logline", attributes: attrs))
        }
        if block.isPendingContext {
            let attachment = EmbedAttachment(box: LoglineSpinnerBox())
            let side = max(10, bodySize * 0.76)
            attachment.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            let spinner = NSMutableAttributedString(attachment: attachment)
            spinner.addAttributes(attrs, range: NSRange(location: 0, length: spinner.length))
            line.append(NSAttributedString(string: " ", attributes: attrs))
            line.append(spinner)
        }
        return line
    }

    private static func contextLineParts(for block: BlockValue) -> [(text: String, isLocation: Bool)] {
        var parts: [(text: String, isLocation: Bool)] = []
        if let stamp = block.contextDisplayStamp {
            parts.append((stamp, false))
        }
        if let weather = block.attrs["weather"]?.stringValue {
            parts.append((weather, false))
        }
        if let location = block.attrs["location"]?.stringValue {
            parts.append((location, true))
        }
        return parts
    }

    private static func mapsURL(for block: BlockValue, location: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.path = "/"
        var items = [URLQueryItem(name: "q", value: location)]
        if let lat = block.attrs["lat"]?.doubleValue,
           let lon = block.attrs["lon"]?.doubleValue {
            items.append(URLQueryItem(name: "ll", value: "\(lat),\(lon)"))
        }
        components.queryItems = items
        return components.url
    }

    private static func contextDisplayAttributes(for block: BlockValue) -> [NSAttributedString.Key: Any] {
        var attrs = attributes(block: block, marks: [:])
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacing = 0
        paragraphStyle.firstLineHeadIndent = 0
        paragraphStyle.headIndent = 0
        attrs[.font] = EditorSettings.font(ofSize: bodySize * 0.76)
        attrs[.paragraphStyle] = paragraphStyle
        attrs[.foregroundColor] = PColor.pSecondaryLabel
        attrs[.amDisplayOnly] = true
        attrs.removeValue(forKey: .backgroundColor)
        return attrs
    }

    @MainActor
    static func embedAttachment(for block: BlockValue, cache: AssetCache) -> NSAttributedString {
        let url = block.embedUrl
        // the attachment and the .amBlock attribute must share one BlockBox:
        // embed handlers mutate it in place and the span encoder reads it back
        var attrs = attributes(block: block, marks: [:])
        attrs.removeValue(forKey: .backgroundColor)
        let box = attrs[.amBlock] as? BlockBox ?? BlockBox(block)
        // A live box must have no image — TextKit only asks an attachment for
        // its view provider when there is nothing to draw without one.
        func liveBox(width: CGFloat, height: CGFloat) -> EmbedAttachment {
            let live = EmbedAttachment(box: box)
            live.bounds = CGRect(origin: .zero, size: CGSize(width: width, height: height))
            return live
        }
        func imageBox(_ image: PImage?, bounds: CGRect, ideal: CGSize? = nil) -> FittingImageAttachment {
            let fitting = FittingImageAttachment()
            fitting.image = image
            fitting.bounds = bounds
            if let ideal { fitting.idealSize = ideal }
            return fitting
        }
        let attachment: NSTextAttachment
        var displayName: String?
        if block.type == "html" {
            attachment = liveBox(width: 460, height: 220)
        } else if block.type == "context" {
            attachment = liveBox(width: 460, height: 28)
        } else if block.type == "calendar-event" {
            let drawn = calendarEventImage(for: block)
            let size = drawn?.size ?? CGSize(width: 420, height: 58)
            attachment = imageBox(drawn, bounds: CGRect(origin: .zero, size: size), ideal: size)
        } else if let url, cache.patchworkDocs.contains(url) {
            attachment = liveBox(width: 460, height: 300)
        } else if let url, let pixels = cache.imageSizes[url] {
            // laid out from the recorded pixel size, drawn from the bounded
            // bitmap the cache decodes off the main thread
            let size = Self.fitted(pixels)
            let fitting = imageBox(
                cache.displayImage(for: url) ?? FittingImageAttachment.placeholder,
                bounds: CGRect(origin: .zero, size: size),
                ideal: size
            )
            fitting.assetUrl = url
            fitting.assetCache = cache
            attachment = fitting
        } else if let url, let thumbnail = cache.videoThumbs[url] {
            // the live VideoInlineView plays in place of the poster
            let size = Self.fitted(thumbnail.size)
            attachment = liveBox(width: size.width, height: size.height)
        } else if let url, let name = cache.names[url],
                  AssetCache.kind(forName: name) == "audio",
                  cache.fileURLs[url] != nil {
            attachment = liveBox(width: 460, height: cache.transcripts[url] != nil ? 132 : 84)
        } else if let url, let name = cache.names[url] {
            let symbol = switch AssetCache.kind(forName: name) {
            case "audio": "waveform.circle.fill"
            case "video": "play.rectangle.fill"
            default: "doc.fill"
            }
            attachment = imageBox(PImage.symbol(symbol), bounds: CGRect(x: 0, y: -4, width: 20, height: 20))
            displayName = name
        } else if block.type != "embed" {
            // unknown block types render as the live chip, never as blank space
            attachment = liveBox(width: 320, height: 44)
        } else {
            attachment = imageBox(
                loadingEmbedImage,
                bounds: CGRect(x: 0, y: 0, width: 460, height: 140),
                ideal: CGSize(width: 460, height: 140)
            )
        }
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes(attrs, range: NSRange(location: 0, length: string.length))
        if let displayName {
            var nameAttrs = attrs
            nameAttrs[.font] = PFont.systemFont(ofSize: bodySize, weight: .medium)
            nameAttrs[.amDisplayOnly] = true
            string.append(NSAttributedString(string: "  \(displayName)", attributes: nameAttrs))
        }
        return string
    }

    /// The calendar box is drawn rather than hosted: an image attachment is
    /// the one embed the editor renders everywhere — including exports, the
    /// dock tile, and history snapshots.
    @MainActor
    static func calendarEventImage(for block: BlockValue) -> PImage? {
        let renderer = ImageRenderer(
            content: CalendarEventInlineView(block: block)
                .frame(width: 420)
                .environment(\.colorScheme, currentColorScheme)
        )
        renderer.scale = 2
        #if os(macOS)
        return renderer.nsImage
        #else
        return renderer.uiImage
        #endif
    }

    @MainActor
    private static var currentColorScheme: ColorScheme {
        #if os(macOS)
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        #else
        UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
        #endif
    }

    static func fitted(_ original: CGSize) -> CGSize {
        #if os(iOS)
        let maxWidth: CGFloat = 340
        #else
        let maxWidth: CGFloat = 420
        #endif
        let maxHeight: CGFloat = 340
        var size = original
        if size.width > 0, size.height > 0 {
            let scale = min(1, min(maxWidth / size.width, maxHeight / size.height))
            size = CGSize(width: size.width * scale, height: size.height * scale)
        }
        return size
    }

    // MARK: tables

    /// Cells hold span lists — marks, paragraphs, images — the same way
    /// columns do; a plain string cell from an older doc parses to a single
    /// text node.
    static func parseTable(_ spans: [SpanNode]) -> TableGrid {
        var rows: [[[SpanNode]]] = []
        var hasHeader = false
        for node in spans {
            switch node {
            case .block(let b) where b.type == "table-row":
                rows.append([])
            case .block(let b) where b.type == "table-cell" || b.type == "table-header-cell":
                if rows.isEmpty { rows.append([]) }
                rows[rows.count - 1].append([])
                if b.type == "table-header-cell", rows.count == 1 {
                    hasHeader = true
                }
            case .block(var b):
                guard !rows.isEmpty, !rows[rows.count - 1].isEmpty else { break }
                b.parents = Array(b.parents.dropFirst(3))
                rows[rows.count - 1][rows[rows.count - 1].count - 1].append(.block(b))
            case .text:
                guard !rows.isEmpty, !rows[rows.count - 1].isEmpty else { break }
                rows[rows.count - 1][rows[rows.count - 1].count - 1].append(node)
            }
        }
        let cols = rows.map(\.count).max() ?? 0
        rows = rows.map { $0 + Array(repeating: [], count: cols - $0.count) }
        return TableGrid(rows: rows, hasHeader: hasHeader)
    }

    static func tableSpans(_ grid: TableGrid) -> [SpanNode] {
        var spans: [SpanNode] = [.block(BlockValue(type: "table"))]
        for (rowIndex, row) in grid.rows.enumerated() {
            spans.append(.block(BlockValue(type: "table-row", parents: ["table"])))
            let cellType = grid.hasHeader && rowIndex == 0 ? "table-header-cell" : "table-cell"
            for cell in row {
                spans.append(.block(BlockValue(type: cellType, parents: ["table", "table-row"])))
                for node in cell {
                    if case .block(var b) = node {
                        b.parents = ["table", "table-row", "table-cell"] + b.parents
                        spans.append(.block(b))
                    } else {
                        spans.append(node)
                    }
                }
            }
        }
        return spans
    }

    static func plainText(of spans: [SpanNode]) -> String {
        spans.compactMap {
            if case .text(let text, _) = $0 { return text }
            return nil
        }.joined()
    }

    /// The attachment only reserves space in the text flow; the live
    /// TableInlineView is positioned over it by InlineViewManager.
    // MARK: columns

    static func parseColumns(_ spans: [SpanNode]) -> [[SpanNode]] {
        var columns: [[SpanNode]] = []
        for node in spans.dropFirst() {
            switch node {
            case .block(let b) where b.type == "column" && b.parents == ["columns"]:
                columns.append([])
            case .block(var b):
                if columns.isEmpty { columns.append([]) }
                b.parents = Array(b.parents.dropFirst(2))
                columns[columns.count - 1].append(.block(b))
            case .text:
                if columns.isEmpty { columns.append([]) }
                columns[columns.count - 1].append(node)
            }
        }
        if columns.isEmpty {
            columns = [[], []]
        }
        return columns.map { $0.isEmpty ? [.block(.paragraph)] : $0 }
    }

    static func columnsSpans(_ columns: [[SpanNode]]) -> [SpanNode] {
        var out: [SpanNode] = [.block(BlockValue(type: "columns"))]
        for column in columns {
            out.append(.block(BlockValue(type: "column", parents: ["columns"])))
            for node in column {
                if case .block(var b) = node {
                    b.parents = ["columns", "column"] + b.parents
                    out.append(.block(b))
                } else {
                    out.append(node)
                }
            }
        }
        return out
    }

    static func columnsAttachment(for box: ColumnsBox) -> NSAttributedString {
        let attachment = EmbedAttachment(box: box)
        attachment.bounds = CGRect(origin: .zero, size: CGSize(width: 460, height: 120))
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes([
            .font: PFont.systemFont(ofSize: bodySize),
            .paragraphStyle: paragraphStyle(for: .paragraph),
            .amBlock: BlockBox(BlockValue(type: "columns")),
            .amColumnsBox: box,
        ], range: NSRange(location: 0, length: string.length))
        return string
    }

    @MainActor
    static func measuredHeight(of spans: [SpanNode], width: CGFloat, cache: AssetCache) -> CGFloat {
        let attr = attributed(from: spans, cache: cache)
        let rect = attr.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return ceil(rect.height)
    }

    static func tableAttachment(for box: TableBox) -> NSAttributedString {
        let attachment = EmbedAttachment(box: box)
        let cols = max(box.grid.columnCount, 1)
        let rows = max(box.grid.rows.count, 1)
        attachment.bounds = CGRect(
            origin: .zero,
            size: CGSize(width: CGFloat(cols) * 150 + 2, height: CGFloat(rows) * 30 + 2)
        )
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes([
            .font: PFont.systemFont(ofSize: bodySize),
            .paragraphStyle: paragraphStyle(for: .paragraph),
            .amBlock: BlockBox(BlockValue(type: "table")),
            .amTableBox: box,
        ], range: NSRange(location: 0, length: string.length))
        return string
    }


    static func spans(from attr: NSAttributedString, trailingBlock: BlockValue? = nil) -> [SpanNode] {
        let str = attr.string as NSString
        var spans: [SpanNode] = []
        var paragraphRanges: [NSRange] = []
        var location = 0
        while location < str.length {
            let r = str.paragraphRange(for: NSRange(location: location, length: 0))
            paragraphRanges.append(r)
            location = NSMaxRange(r)
        }
        if str.length == 0 || str.hasSuffix("\n") {
            paragraphRanges.append(NSRange(location: str.length, length: 0))
        }

        // text typed on an attachment's line survives as its own paragraph
        func strayParagraph(in range: NSRange) -> [SpanNode] {
            guard range.length > 0 else { return [] }
            var nodes: [SpanNode] = []
            var pendingText = ""
            var pendingMarks: [String: JSONValue] = [:]
            attr.enumerateAttributes(in: range) { runAttrs, runRange, _ in
                guard runAttrs[.amDisplayOnly] == nil else { return }
                let text = str.substring(with: runRange)
                    .replacingOccurrences(of: "\u{FFFC}", with: "")
                guard !text.isEmpty else { return }
                let marks = self.marks(from: runAttrs, block: .paragraph)
                if marks == pendingMarks {
                    pendingText += text
                } else {
                    if !pendingText.isEmpty {
                        nodes.append(.text(pendingText, pendingMarks))
                    }
                    pendingText = text
                    pendingMarks = marks
                }
            }
            if !pendingText.isEmpty {
                nodes.append(.text(pendingText, pendingMarks))
            }
            return nodes.isEmpty ? [] : [.block(.paragraph)] + nodes
        }

        var previousBlock = BlockValue.paragraph
        var activeBlockquotePath: [String]?
        for range in paragraphRanges {
            var contentLength = range.length
            if contentLength > 0, str.character(at: NSMaxRange(range) - 1) == 0x0A {
                contentLength -= 1
            }
            if range.length > 0 {
                var boxes: [(location: Int, spans: [SpanNode])] = []
                attr.enumerateAttribute(.amTableBox, in: range) { value, runRange, _ in
                    if let box = value as? TableBox {
                        let run = str.substring(with: runRange) as NSString
                        let attachment = run.range(of: "\u{FFFC}")
                        let location = attachment.location == NSNotFound
                            ? runRange.location
                            : runRange.location + attachment.location
                        boxes.append((location, box.spans))
                    }
                }
                attr.enumerateAttribute(.amColumnsBox, in: range) { value, runRange, _ in
                    if let box = value as? ColumnsBox {
                        let run = str.substring(with: runRange) as NSString
                        let attachment = run.range(of: "\u{FFFC}")
                        let location = attachment.location == NSNotFound
                            ? runRange.location
                            : runRange.location + attachment.location
                        boxes.append((location, box.spans))
                    }
                }
                if !boxes.isEmpty {
                    boxes.sort { $0.location < $1.location }
                    let contentEnd = range.location + contentLength
                    var cursor = range.location
                    for box in boxes {
                        if cursor < box.location {
                            spans.append(contentsOf: strayParagraph(in: NSRange(
                                location: cursor,
                                length: box.location - cursor
                            )))
                        }
                        spans.append(contentsOf: box.spans)
                        cursor = max(cursor, min(box.location + 1, contentEnd))
                    }
                    if cursor < contentEnd {
                        spans.append(contentsOf: strayParagraph(in: NSRange(
                            location: cursor,
                            length: contentEnd - cursor
                        )))
                    }
                    previousBlock = .paragraph
                    activeBlockquotePath = nil
                    continue
                }
            }
            var block: BlockValue
            if range.length > 0,
               let box = attr.attribute(.amBlock, at: range.location, effectiveRange: nil) as? BlockBox {
                block = box.value
            } else if range.length == 0, let trailingBlock {
                block = trailingBlock
            } else {
                block = previousBlock
            }
            if block.type == "blockquote", let path = block.blockquotePath {
                if activeBlockquotePath == path {
                    block = BlockValue(type: "paragraph", parents: path)
                } else {
                    activeBlockquotePath = path
                }
            } else {
                activeBlockquotePath = block.blockquotePath
            }
            if block.type == "context" || block.type == "calendar-event" {
                spans.append(.block(block))
                previousBlock = block
                // these render themselves from their attrs, so their own
                // characters are display-only and must not be encoded — but a
                // reader can type onto the line, and that text is theirs.
                // Dropping the whole paragraph here ate it on the next save.
                let stray = strayParagraph(in: NSRange(
                    location: range.location,
                    length: contentLength
                ))
                if !stray.isEmpty {
                    spans.append(contentsOf: stray)
                    previousBlock = .paragraph
                }
                continue
            }
            if block.isEmbedBlock {
                let content = contentLength > 0
                    ? str.substring(with: NSRange(location: range.location, length: contentLength))
                    : ""
                let attachment = (content as NSString).range(of: "\u{FFFC}")
                if attachment.location != NSNotFound {
                    let location = range.location + attachment.location
                    if location > range.location {
                        spans.append(contentsOf: strayParagraph(in: NSRange(
                            location: range.location,
                            length: location - range.location
                        )))
                    }
                    spans.append(.block(block))
                    let after = location + attachment.length
                    let contentEnd = range.location + contentLength
                    if after < contentEnd {
                        spans.append(contentsOf: strayParagraph(in: NSRange(
                            location: after,
                            length: contentEnd - after
                        )))
                    }
                    previousBlock = .paragraph
                    continue
                }
                block = .paragraph
            }
            spans.append(.block(block))
            previousBlock = block

            guard contentLength > 0 else { continue }
            let contentRange = NSRange(location: range.location, length: contentLength)
            var pendingText = ""
            var pendingMarks: [String: JSONValue] = [:]
            attr.enumerateAttributes(in: contentRange) { runAttrs, runRange, _ in
                guard runAttrs[.amDisplayOnly] == nil else { return }
                let text = str.substring(with: runRange)
                    .replacingOccurrences(of: "\u{FFFC}", with: "")
                guard !text.isEmpty else { return }
                let marks = self.marks(from: runAttrs, block: block)
                if marks == pendingMarks {
                    pendingText += text
                } else {
                    if !pendingText.isEmpty {
                        spans.append(.text(pendingText, pendingMarks))
                    }
                    pendingText = text
                    pendingMarks = marks
                }
            }
            if !pendingText.isEmpty {
                spans.append(.text(pendingText, pendingMarks))
            }
        }
        return spans
    }

    private static let titleBoxes: Set<String> = [
        "table", "table-row", "table-cell", "table-header-cell", "columns", "column",
    ]

    /// First non-empty line of text, for use as the note's title.
    static func title(from spans: [SpanNode]) -> String {
        title(from: spans, skippingBoxes: true) ?? title(from: spans, skippingBoxes: false) ?? ""
    }

    private static func title(from spans: [SpanNode], skippingBoxes: Bool) -> String? {
        // accumulate a whole line across formatting runs; a bold word or a
        // link at the start of the title otherwise clipped it at the run edge
        var line = ""
        var skipping = false
        for node in spans {
            switch node {
            case .block(let block):
                if let title = titleLine(line) { return title }
                line = ""
                skipping = skippingBoxes && isTitleBox(block)
            case .text(let value, _):
                if !skipping { line += value }
            }
        }
        return titleLine(line)
    }

    private static func isTitleBox(_ block: BlockValue) -> Bool {
        titleBoxes.contains(block.type) || block.parents.contains(where: titleBoxes.contains)
    }

    private static func titleLine(_ text: String) -> String? {
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return String(trimmed.prefix(60)) }
        }
        return nil
    }
}
