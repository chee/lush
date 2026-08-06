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

        let keywords = keywordsByLanguage[language] ?? (language == "plain" ? [] : fallbackKeywords)
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

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }
}

private enum Palette {
    static let comment = PColor.pSecondaryLabel
    static let string = PColor.dynamicCodeColor(light: 0xB42318, dark: 0xFFB4A8)
    static let number = PColor.dynamicCodeColor(light: 0x1D4ED8, dark: 0x9EC3FF)
    static let keyword = PColor.dynamicCodeColor(light: 0x7E22CE, dark: 0xD8B4FE)
    static let type = PColor.dynamicCodeColor(light: 0x047857, dark: 0x8FE3C0)
    static let function = PColor.dynamicCodeColor(light: 0xB45309, dark: 0xF9C97C)
    static let property = PColor.dynamicCodeColor(light: 0x0F766E, dark: 0x82DCD4)
    static let operatorToken = PColor.dynamicCodeColor(light: 0x4B5563, dark: 0xCBD5E1)
}

extension PColor {
    static func dynamicCodeColor(light: Int, dark: Int) -> PColor {
        #if os(macOS)
        PColor(name: nil) { appearance in
            let best = appearance.bestMatch(from: [.darkAqua, .aqua])
            return PColor(rgb: best == .darkAqua ? dark : light)
        }
        #else
        PColor { traits in
            PColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        }
        #endif
    }
}
