import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct CodeLanguage: Identifiable, Equatable {
    let id: String
    let name: String

    static let plain = CodeLanguage(id: "plain", name: "Plain Text")

    static let all: [CodeLanguage] = [
        .plain,
        CodeLanguage(id: "swift", name: "Swift"),
        CodeLanguage(id: "javascript", name: "JavaScript"),
        CodeLanguage(id: "typescript", name: "TypeScript"),
        CodeLanguage(id: "python", name: "Python"),
        CodeLanguage(id: "html", name: "HTML"),
        CodeLanguage(id: "css", name: "CSS"),
        CodeLanguage(id: "json", name: "JSON"),
        CodeLanguage(id: "markdown", name: "Markdown"),
        CodeLanguage(id: "bash", name: "Shell"),
        CodeLanguage(id: "sql", name: "SQL"),
        CodeLanguage(id: "rust", name: "Rust"),
    ]

    static func named(_ id: String?) -> CodeLanguage {
        guard let id else { return .plain }
        let normalized = normalize(id)
        return all.first { $0.id == normalized } ?? .plain
    }

    static func normalize(_ id: String) -> String {
        switch id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "js", "jsx": "javascript"
        case "ts", "tsx": "typescript"
        case "py": "python"
        case "sh", "shell", "zsh": "bash"
        case "md": "markdown"
        case "htm": "html"
        case "": "plain"
        default: id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }
}

/// Display-only syntax coloring for code blocks. This is intentionally shaped
/// like a tiny Shiki theme: tokenize into semantic classes, then map classes to
/// a stable palette. Colors never reach the doc, so this is presentational.
enum CodeHighlight {
    enum TokenKind {
        case comment
        case string
        case number
        case keyword
        case type
        case function
        case property
        case operatorToken
    }

    typealias Token = (range: NSRange, kind: TokenKind)

    private static let commonPatterns: [(NSRegularExpression, TokenKind)] = [
        (regex(#"//[^\n]*|/\*[\s\S]*?\*/"#), .comment),
        (regex(#""(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`[^`]*`"#), .string),
        (regex(#"\b0x[0-9A-Fa-f_]+\b|\b\d[\d_]*(?:\.\d[\d_]*)?\b"#), .number),
        (regex(#"[-+*/%=!<>|&~^?:]+"#), .operatorToken),
    ]

    private static let hashCommentPattern = regex(#"(?<![:\w])#(?!\{)[^\n]*"#)
    private static let htmlCommentPattern = regex(#"<!--[\s\S]*?-->"#)
    private static let htmlTagPattern = regex(#"</?\s*[A-Za-z][A-Za-z0-9:-]*"#)
    private static let htmlAttributePattern = regex(#"\b[A-Za-z_:][-A-Za-z0-9_:.]*(?=\s*=)"#)
    private static let cssPropertyPattern = regex(#"(?m)(^|[;{]\s*)([-A-Za-z]+)(?=\s*:)"#)
    private static let functionPattern = regex(#"\b[A-Za-z_][A-Za-z0-9_]*(?=\s*\()"#)
    private static let typePattern = regex(#"\b[A-Z][A-Za-z0-9_]*\b"#)
    private static let wordPattern = regex(#"\b[A-Za-z_][A-Za-z0-9_]*\b"#)

    private static let keywordsByLanguage: [String: Set<String>] = [
        "swift": ["actor", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "do", "else", "enum", "extension", "false", "fileprivate", "final", "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let", "nil", "open", "operator", "override", "private", "protocol", "public", "return", "self", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "where", "while"],
        "javascript": ["async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import", "in", "instanceof", "let", "new", "null", "of", "return", "static", "super", "switch", "this", "throw", "true", "try", "typeof", "undefined", "var", "void", "while", "yield"],
        "typescript": ["abstract", "any", "as", "async", "await", "boolean", "break", "case", "catch", "class", "const", "continue", "declare", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function", "if", "implements", "import", "in", "instanceof", "interface", "keyof", "let", "module", "namespace", "never", "new", "null", "number", "of", "private", "protected", "public", "readonly", "return", "static", "string", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "unknown", "var", "void", "while", "yield"],
        "python": ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while", "with", "yield"],
        "css": ["@media", "@supports", "@container", "@keyframes", "from", "to", "important"],
        "json": ["true", "false", "null"],
        "markdown": ["TODO", "FIXME", "NOTE"],
        "bash": ["case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in", "local", "then", "while"],
        "sql": ["alter", "and", "as", "by", "case", "create", "delete", "desc", "distinct", "drop", "else", "from", "group", "having", "insert", "into", "join", "left", "limit", "not", "null", "on", "or", "order", "outer", "right", "select", "set", "table", "then", "update", "values", "when", "where"],
        "rust": ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"],
    ]

    private static let fallbackKeywords: Set<String> = Set(
        keywordsByLanguage.values.flatMap { $0 }
    )

    static func tokens(in text: String, language: String?) -> [Token] {
        let language = CodeLanguage.normalize(language ?? "plain")
        guard language != "plain" else { return [] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var claimed = IndexSet()
        var out: [Token] = []

        func claim(_ regex: NSRegularExpression, _ kind: TokenKind, captureGroup: Int = 0) {
            for match in regex.matches(in: text, range: full) {
                let range = match.range(at: captureGroup)
                guard range.location != NSNotFound, range.length > 0 else { continue }
                let indexes = IndexSet(integersIn: range.location ..< NSMaxRange(range))
                guard claimed.intersection(indexes).isEmpty else { continue }
                claimed.formUnion(indexes)
                out.append((range, kind))
            }
        }

        if language == "html" {
            claim(htmlCommentPattern, .comment)
        }
        if language == "python" || language == "bash" || language == "markdown" {
            claim(hashCommentPattern, .comment)
        }
        for (pattern, kind) in commonPatterns {
            claim(pattern, kind)
        }
        if language == "html" {
            claim(htmlTagPattern, .keyword)
            claim(htmlAttributePattern, .property)
        } else if language == "css" {
            claim(cssPropertyPattern, .property, captureGroup: 2)
        } else if language != "plain" {
            claim(functionPattern, .function)
            claim(typePattern, .type)
        }

        let keywords = keywordsByLanguage[language] ?? fallbackKeywords
        for match in wordPattern.matches(in: text, range: full) {
            let range = match.range
            guard !claimed.contains(range.location) else { continue }
            let word = ns.substring(with: range)
            if keywords.contains(word) || keywords.contains(word.lowercased()) {
                out.append((range, .keyword))
            }
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    static func color(for kind: TokenKind) -> PColor {
        switch kind {
        case .comment: Palette.comment
        case .string: Palette.string
        case .number: Palette.number
        case .keyword: Palette.keyword
        case .type: Palette.type
        case .function: Palette.function
        case .property: Palette.property
        case .operatorToken: Palette.operatorToken
        }
    }

    static func renderingAttributes(for kind: TokenKind) -> [NSAttributedString.Key: Any] {
        [.foregroundColor: color(for: kind)]
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }
}

/// Light mode uses Lychee; dark mode uses Gloom from Patchwork's base theme.
private enum Palette {
    static let comment = PColor.dynamicCodeColor(light: 0x8899AA, dark: 0x6272A4)
    static let string = PColor.dynamicCodeColor(light: 0x208776, dark: 0xF1FA8C)
    static let number = PColor.dynamicCodeColor(light: 0x3999FF, dark: 0xBD93F9)
    static let keyword = PColor.dynamicCodeColor(light: 0x810005, dark: 0xFF79C6)
    static let type = PColor.dynamicCodeColor(light: 0xDB4E80, dark: 0x8BE9FD)
    static let function = PColor.dynamicCodeColor(light: 0x3999FF, dark: 0x50FA7B)
    static let property = PColor.dynamicCodeColor(light: 0xDB4E80, dark: 0x50FA7B)
    static let operatorToken = PColor.dynamicCodeColor(light: 0x086F8A, dark: 0xFF79C6)
}

extension CodeHighlight {
    static let cardBackground = PColor.dynamicCodeColor(light: 0xF9FCFF, dark: 0x1A1B1E)
    static let cardBorder = PColor.dynamicCodeColor(light: 0xE3F6FF, dark: 0x44475A)
    static let cardVerticalPadding: CGFloat = 4

    /// Rendering attributes are display-only and live in the layout manager,
    /// so token colours never touch the storage or the automerge round-trip.
    /// TextKit revalidates whenever a code paragraph lays out again. The whole
    /// contiguous code run is tokenized as one text so block comments and
    /// multi-line strings colour across paragraphs.
    static func applyRenderingAttributes(
        _ textLayoutManager: NSTextLayoutManager,
        _ fragment: NSTextLayoutFragment
    ) {
        guard let paragraph = fragment.textElement as? NSTextParagraph,
              let contentStorage = textLayoutManager.textContentManager as? NSTextContentStorage,
              let storage = contentStorage.textStorage,
              let elementRange = paragraph.elementRange
        else { return }
        let location = contentStorage.offset(
            from: contentStorage.documentRange.location,
            to: elementRange.location
        )
        let attributed = paragraph.attributedString
        guard attributed.length > 0,
              location >= 0,
              location < storage.length,
              location + attributed.length <= storage.length,
              let box = attributed.attribute(.amBlock, at: 0, effectiveRange: nil) as? BlockBox,
              box.value.type == "code-block"
        else { return }
        let storageStr = storage.string as NSString
        let language = box.value.codeLanguage
        let paragraphRange = NSRange(location: location, length: attributed.length)
        let run = codeRun(containing: paragraphRange, language: language, in: storage, str: storageStr)
        for token in tokens(in: storageStr.substring(with: run), language: language) {
            let absolute = NSRange(location: run.location + token.range.location, length: token.range.length)
            let clipped = NSIntersectionRange(absolute, paragraphRange)
            guard token.range.length > 0,
                  NSMaxRange(absolute) <= storage.length,
                  clipped.length > 0,
                  let textRange = contentStorage.textRange(for: clipped)
            else { continue }
            textLayoutManager.addRenderingAttribute(
                .foregroundColor,
                value: color(for: token.kind),
                for: textRange
            )
        }
    }

    static func isCodeParagraph(_ range: NSRange, language: String?, in storage: NSTextStorage) -> Bool {
        guard range.length > 0,
              range.location >= 0,
              range.location < storage.length,
              let box = storage.attribute(.amBlock, at: range.location, effectiveRange: nil) as? BlockBox,
              box.value.type == "code-block"
        else { return false }
        guard let language else { return true }
        return CodeLanguage.normalize(box.value.codeLanguage) == CodeLanguage.normalize(language)
    }

    /// The contiguous run of same-language code paragraphs around one.
    static func codeRun(
        containing paragraph: NSRange,
        language: String?,
        in storage: NSTextStorage,
        str: NSString
    ) -> NSRange {
        var start = paragraph
        while start.location > 0 {
            let previous = str.paragraphRange(for: NSRange(location: start.location - 1, length: 0))
            guard isCodeParagraph(previous, language: language, in: storage) else { break }
            start = previous
        }
        var end = NSMaxRange(paragraph)
        while end < storage.length {
            let next = str.paragraphRange(for: NSRange(location: end, length: 0))
            guard isCodeParagraph(next, language: language, in: storage) else { break }
            end = NSMaxRange(next)
        }
        return NSRange(location: start.location, length: end - start.location)
    }
}

extension PColor {
    static func dynamicCodeColor(light: Int, dark: Int, alpha: CGFloat = 1) -> PColor {
        #if os(macOS)
        PColor(name: nil) { appearance in
            let best = appearance.bestMatch(from: [.darkAqua, .aqua])
            return PColor(rgb: best == .darkAqua ? dark : light, alpha: alpha)
        }
        #else
        PColor { traits in
            PColor(rgb: traits.userInterfaceStyle == .dark ? dark : light, alpha: alpha)
        }
        #endif
    }
}
