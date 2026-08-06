import SwiftUI
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
        case .int(let i): return Int(i)
        case .number(let d): return Int(d)
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

    var isEmbedBlock: Bool {
        isEmbed || type == "embed" || type == "image" || type == "html"
    }

    /// Blocks that live behind a single attachment character and must never
    /// be restyled or split by ordinary text editing.
    var isAtomic: Bool {
        isEmbedBlock || type == "table" || type == "columns"
    }

    var embedUrl: String? {
        attrs["url"]?.stringValue ?? attrs["src"]?.stringValue
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
        type == "todo-list-item" && attrs["checked"]?.boolValue == true
    }

    var codeLanguage: String {
        guard type == "code-block" else { return CodeLanguage.plain.id }
        return CodeLanguage.named(attrs["language"]?.stringValue).id
    }

    static func todo(checked: Bool) -> BlockValue {
        BlockValue(type: "todo-list-item", attrs: checked ? ["checked": .bool(true)] : [:])
    }

    /// Stable identifier for the format picker.
    var styleKey: String {
        switch type {
        case "heading": return "heading\(headingLevel ?? 1)"
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
    static let amHighlight = NSAttributedString.Key("io.lush.highlight")
    /// "superscript" or "subscript" — the mark behind a shifted baseline.
    static let amBaseline = NSAttributedString.Key("io.lush.baseline")
    static let amTableBox = NSAttributedString.Key("io.lush.tableBox")
    static let amColumnsBox = NSAttributedString.Key("io.lush.columnsBox")
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
    var rows: [[String]]
    var hasHeader: Bool

    var columnCount: Int { rows.map(\.count).max() ?? 0 }

    static func empty(rows: Int, columns: Int) -> TableGrid {
        TableGrid(
            rows: Array(repeating: Array(repeating: "", count: columns), count: rows),
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

    private func fitted(to lineFrag: CGRect, padding: CGFloat) -> CGRect {
        var size = bounds.size
        let available = lineFrag.width - padding * 2
        if available > 40, size.width > available, size.width > 0 {
            let scale = available / size.width
            size = CGSize(width: available, height: size.height * scale)
        }
        return CGRect(origin: bounds.origin, size: size)
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
}

final class BlockBox: NSObject {
    var value: BlockValue
    init(_ value: BlockValue) { self.value = value }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? BlockBox)?.value == value
    }

    override var hash: Int { value.type.hashValue }
}

@MainActor
final class AssetCache {
    var images: [String: PImage] = [:]
    var names: [String: String] = [:]
    var fileURLs: [String: URL] = [:]
    var videoThumbs: [String: PImage] = [:]
    /// Embedded automerge docs that aren't file assets — rendered by the
    /// patchwork web runtime instead of natively.
    var patchworkDocs: Set<String> = []
    var transcripts: [String: String] = [:]

    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aac", "caf", "aiff"]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "mpg", "mpeg"]

    static func kind(forName name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if audioExtensions.contains(ext) { return "audio" }
        if videoExtensions.contains(ext) { return "video" }
        return "file"
    }
}

/// User-adjustable editor typography, persisted in UserDefaults. Views that
/// render text re-load when `changed` is posted.
enum EditorSettings {
    static let changed = Notification.Name("io.lush.editorSettingsChanged")
    private static let sizeKey = "editorBodySize"
    private static let designKey = "editorFontDesign"
    private static let autoInsertLoglineKey = "editorAutoInsertLogline"

    static let designs: [(key: String, label: String)] = [
        ("system", "System"),
        ("serif", "New York"),
        ("rounded", "Rounded"),
        ("mono", "Monospaced"),
        ("georgia", "Georgia"),
        ("palatino", "Palatino"),
        ("baskerville", "Baskerville"),
        ("times", "Times New Roman"),
        ("didot", "Didot"),
        ("helvetica", "Helvetica Neue"),
        ("avenir", "Avenir Next"),
        ("optima", "Optima"),
        ("typewriter", "Typewriter"),
        ("courier", "Courier New"),
        ("menlo", "Menlo"),
    ]

    private static let namedFonts: [String: String] = [
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
    private static var cachedDesign: String?
    private static var fontCache: [FontKey: PFont] = [:]

    private struct FontKey: Hashable {
        let size: CGFloat
        let weight: CGFloat
    }

    private static func invalidateTypography() {
        cachedBodySize = nil
        cachedDesign = nil
        fontCache = [:]
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static var bodySize: Double {
        if let cachedBodySize { return cachedBodySize }
        let saved = UserDefaults.standard.double(forKey: sizeKey)
        let size = saved > 0 ? saved : defaultBodySize
        cachedBodySize = size
        return size
    }

    static func setBodySize(_ size: Double) {
        UserDefaults.standard.set(size, forKey: sizeKey)
        invalidateTypography()
    }

    static var design: String {
        if let cachedDesign { return cachedDesign }
        let design = UserDefaults.standard.string(forKey: designKey) ?? "system"
        cachedDesign = design
        return design
    }

    static func setDesign(_ design: String) {
        UserDefaults.standard.set(design, forKey: designKey)
        invalidateTypography()
    }

    static var autoInsertLogline: Bool {
        UserDefaults.standard.bool(forKey: autoInsertLoglineKey)
    }

    static func setAutoInsertLogline(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: autoInsertLoglineKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func font(ofSize size: CGFloat, weight: PFont.Weight = .regular) -> PFont {
        let key = FontKey(size: size, weight: weight.rawValue)
        if let hit = fontCache[key] { return hit }
        let resolved = resolveFont(ofSize: size, weight: weight)
        fontCache[key] = resolved
        return resolved
    }

    private static func resolveFont(ofSize size: CGFloat, weight: PFont.Weight) -> PFont {
        let base = PFont.systemFont(ofSize: size, weight: weight)
        switch design {
        case "serif":
            guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
            #if os(macOS)
            return PFont(descriptor: descriptor, size: size) ?? base
            #else
            return PFont(descriptor: descriptor, size: size)
            #endif
        case "rounded":
            guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
            #if os(macOS)
            return PFont(descriptor: descriptor, size: size) ?? base
            #else
            return PFont(descriptor: descriptor, size: size)
            #endif
        case "mono":
            return .monospacedSystemFont(ofSize: size, weight: weight)
        default:
            guard let fontName = namedFonts[design],
                  let named = PFont(name: fontName, size: size) else { return base }
            return weight.rawValue > 0 ? named.addingTraits(bold: true) : named
        }
    }
}

enum RichText {
    static var bodySize: CGFloat { EditorSettings.bodySize }

    static func baseFont(for block: BlockValue) -> PFont {
        switch block.type {
        case "heading":
            switch block.headingLevel ?? 1 {
            case 1: return EditorSettings.font(ofSize: bodySize + 10, weight: .bold)
            case 2: return EditorSettings.font(ofSize: bodySize + 5, weight: .bold)
            default: return EditorSettings.font(ofSize: bodySize + 2, weight: .semibold)
            }
        case "code-block":
            return .monospacedSystemFont(ofSize: bodySize - 1, weight: .regular)
        default:
            return EditorSettings.font(ofSize: bodySize)
        }
    }

    private struct ParagraphKey: Hashable {
        let type: String
        let depth: Int
    }

    private static var paragraphStyleCache: [ParagraphKey: NSParagraphStyle] = [:]

    static func paragraphStyle(for block: BlockValue) -> NSParagraphStyle {
        let key = ParagraphKey(type: block.type, depth: block.parents.count)
        if let hit = paragraphStyleCache[key] { return hit }
        let style = buildParagraphStyle(for: block)
        paragraphStyleCache[key] = style
        return style
    }

    private static func buildParagraphStyle(for block: BlockValue) -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.paragraphSpacing = 6
        var indent: CGFloat = 0
        // nested structures (list nesting, columns, table cells) indent by depth
        indent += CGFloat(block.parents.count) * 20
        switch block.type {
        case "heading":
            ps.paragraphSpacingBefore = 10
        case "unordered-list-item", "ordered-list-item", "todo-list-item":
            indent += 32
        case "blockquote":
            indent += 16
        default:
            break
        }
        ps.firstLineHeadIndent = indent
        ps.headIndent = indent
        return ps
    }

    static func attributes(block: BlockValue, marks: [String: JSONValue]) -> [NSAttributedString.Key: Any] {
        var font = baseFont(for: block)
        var bold = false
        var italic = false
        if case .bool(true)? = marks["strong"], block.type != "heading" {
            bold = true
        }
        if case .bool(true)? = marks["em"] {
            italic = true
        }
        if bold || italic {
            font = font.addingTraits(bold: bold, italic: italic)
        }
        if case .bool(true)? = marks["code"] {
            let size = font.pointSize - 1
            font = PFont.monospacedSystemFont(ofSize: size, weight: .regular)
                .addingTraits(bold: bold, italic: italic)
        }
        var out: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle(for: block),
            .foregroundColor: block.type == "blockquote" ? PColor.pSecondaryLabel : PColor.pLabel,
            .amBlock: BlockBox(block),
        ]
        if case .bool(true)? = marks["code"] {
            out[.backgroundColor] = PColor.pLabel.withAlphaComponent(0.08)
        }
        if block.type == "code-block" {
            out[.backgroundColor] = PColor.pLabel.withAlphaComponent(0.05)
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
            if block.type != "code-block", font.hasMonoSpaceTrait {
                marks["code"] = .bool(true)
            }
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
        return marks
    }

    @MainActor
    static func attributed(from spans: [SpanNode], cache: AssetCache) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var block = BlockValue.paragraph
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
                sawAnything = true
                i = j
                continue
            }
            switch node {
            case .block(let b):
                if sawAnything {
                    out.append(NSAttributedString(
                        string: "\n",
                        attributes: attributes(block: block, marks: [:])
                    ))
                }
                block = b
                sawAnything = true
                if b.isEmbedBlock {
                    out.append(embedAttachment(for: b, cache: cache))
                }
            case .text(let text, let marks):
                guard !block.isEmbedBlock else { break }
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
    static func embedAttachment(for block: BlockValue, cache: AssetCache) -> NSAttributedString {
        let url = block.embedUrl
        let isLiveBox = block.type == "html"
            || block.type == "context"
            || url.map { cache.patchworkDocs.contains($0) } == true
        let attachment: NSTextAttachment = isLiveBox
            ? NSTextAttachment()
            : FittingImageAttachment()
        var displayName: String?
        if block.type == "html" {
            attachment.image = PImage.draw(size: CGSize(width: 1, height: 1)) { _ in }
            attachment.bounds = CGRect(origin: .zero, size: CGSize(width: 460, height: 220))
        } else if block.type == "context" {
            attachment.image = PImage.draw(size: CGSize(width: 1, height: 1)) { _ in }
            attachment.bounds = CGRect(origin: .zero, size: CGSize(width: 460, height: 28))
        } else if let url, cache.patchworkDocs.contains(url) {
            attachment.image = PImage.draw(size: CGSize(width: 1, height: 1)) { _ in }
            attachment.bounds = CGRect(origin: .zero, size: CGSize(width: 460, height: 300))
        } else if let url, let image = cache.images[url] {
            attachment.image = image
            let size = Self.fitted(image.size)
            attachment.bounds = CGRect(origin: .zero, size: size)
            (attachment as? FittingImageAttachment)?.idealSize = size
        } else if let url, let thumb = cache.videoThumbs[url] {
            attachment.image = thumb
            let size = Self.fitted(thumb.size)
            attachment.bounds = CGRect(origin: .zero, size: size)
            (attachment as? FittingImageAttachment)?.idealSize = size
        } else if let url, let name = cache.names[url],
                  AssetCache.kind(forName: name) == "audio",
                  cache.fileURLs[url] != nil {
            // rendered by the live AudioInlineView; reserve the box
            attachment.image = PImage.draw(size: CGSize(width: 1, height: 1)) { _ in }
            let height: CGFloat = cache.transcripts[url] != nil ? 132 : 84
            attachment.bounds = CGRect(origin: .zero, size: CGSize(width: 460, height: height))
        } else if let url, let name = cache.names[url] {
            let symbol = switch AssetCache.kind(forName: name) {
            case "audio": "waveform.circle.fill"
            case "video": "play.rectangle.fill"
            default: "doc.fill"
            }
            attachment.image = PImage.symbol(symbol)
            attachment.bounds = CGRect(x: 0, y: -4, width: 20, height: 20)
            displayName = name
        } else {
            attachment.image = PImage.symbol("photo")
            attachment.bounds = CGRect(x: 0, y: 0, width: 48, height: 36)
        }
        let string = NSMutableAttributedString(attachment: attachment)
        var attrs = attributes(block: block, marks: [:])
        attrs.removeValue(forKey: .backgroundColor)
        string.addAttributes(attrs, range: NSRange(location: 0, length: string.length))
        if let displayName {
            var nameAttrs = attrs
            nameAttrs[.font] = PFont.systemFont(ofSize: bodySize, weight: .medium)
            nameAttrs[.amDisplayOnly] = true
            string.append(NSAttributedString(string: "  \(displayName)", attributes: nameAttrs))
        }
        return string
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

    static func parseTable(_ spans: [SpanNode]) -> TableGrid {
        var rows: [[String]] = []
        var hasHeader = false
        for node in spans {
            switch node {
            case .block(let b):
                switch b.type {
                case "table-row":
                    rows.append([])
                case "table-cell", "table-header-cell":
                    if rows.isEmpty { rows.append([]) }
                    rows[rows.count - 1].append("")
                    if b.type == "table-header-cell", rows.count == 1 {
                        hasHeader = true
                    }
                default:
                    break
                }
            case .text(let text, _):
                if !rows.isEmpty, !rows[rows.count - 1].isEmpty {
                    rows[rows.count - 1][rows[rows.count - 1].count - 1] += text
                }
            }
        }
        let cols = rows.map(\.count).max() ?? 0
        rows = rows.map { $0 + Array(repeating: "", count: cols - $0.count) }
        return TableGrid(rows: rows, hasHeader: hasHeader)
    }

    static func tableSpans(_ grid: TableGrid) -> [SpanNode] {
        var spans: [SpanNode] = [.block(BlockValue(type: "table"))]
        for (rowIndex, row) in grid.rows.enumerated() {
            spans.append(.block(BlockValue(type: "table-row", parents: ["table"])))
            let cellType = grid.hasHeader && rowIndex == 0 ? "table-header-cell" : "table-cell"
            for cell in row {
                spans.append(.block(BlockValue(type: cellType, parents: ["table", "table-row"])))
                if !cell.isEmpty {
                    spans.append(.text(cell, [:]))
                }
            }
        }
        return spans
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
        let attachment = NSTextAttachment()
        attachment.image = PImage.draw(size: CGSize(width: 1, height: 1)) { _ in }
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
        let attachment = NSTextAttachment()
        attachment.image = PImage.draw(size: CGSize(width: 1, height: 1)) { _ in }
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

        var previousBlock = BlockValue.paragraph
        for range in paragraphRanges {
            var contentLength = range.length
            if contentLength > 0, str.character(at: NSMaxRange(range) - 1) == 0x0A {
                contentLength -= 1
            }
            if range.length > 0 {
                var boxSpans: [SpanNode]?
                attr.enumerateAttribute(.amTableBox, in: range) { value, _, stop in
                    if let box = value as? TableBox {
                        boxSpans = box.spans
                        stop.pointee = true
                    }
                }
                if boxSpans == nil {
                    attr.enumerateAttribute(.amColumnsBox, in: range) { value, _, stop in
                        if let box = value as? ColumnsBox {
                            boxSpans = box.spans
                            stop.pointee = true
                        }
                    }
                }
                if let boxSpans {
                    spans.append(contentsOf: boxSpans)
                    // text typed on the attachment's line survives as its own
                    // paragraph after the table
                    var stray = ""
                    attr.enumerateAttributes(in: range) { runAttrs, runRange, _ in
                        guard runAttrs[.amDisplayOnly] == nil else { return }
                        stray += str.substring(with: runRange)
                            .replacingOccurrences(of: "\u{FFFC}", with: "")
                    }
                    stray = stray.trimmingCharacters(in: .newlines)
                    if !stray.isEmpty {
                        spans.append(.block(.paragraph))
                        spans.append(.text(stray, [:]))
                    }
                    previousBlock = .paragraph
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
            if block.isEmbedBlock {
                let content = contentLength > 0
                    ? str.substring(with: NSRange(location: range.location, length: contentLength))
                    : ""
                if content.contains("\u{FFFC}") {
                    spans.append(.block(block))
                    previousBlock = block
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

    /// First non-empty line of text, for use as the note's title.
    static func title(from spans: [SpanNode]) -> String {
        for node in spans {
            if case .text(let text, _) = node {
                let line = text
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .first
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if !line.isEmpty {
                    return String(line.prefix(60))
                }
            }
        }
        return ""
    }
}
