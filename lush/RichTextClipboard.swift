import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
enum RichTextClipboard {
    static let spansTypeIdentifier = "org.automerge.richtext"
    static let markdownTypeIdentifier = "net.daringfireball.markdown"
    static let htmlTypeIdentifier = UTType.html.identifier

    /// The same spans JSON as a Clipboard API web custom format, which is how
    /// browsers put it on the pasteboard: a map from mime type to a numbered
    /// payload type, both under `org.w3.web-custom-format.*`.
    static let webSpansTypeIdentifier = "application/vnd.inkandswitch.automerge.richtext"
    static let webCustomMapIdentifier = "org.w3.web-custom-format.map"
    static let webCustomPayloadIdentifier = "org.w3.web-custom-format.type-0"

    static func spansJSON(webCustomMap mapData: Data, payload: (String) -> Data?) -> String? {
        guard let map = try? JSONDecoder().decode([String: String].self, from: mapData),
              let type = map[webSpansTypeIdentifier],
              let data = payload(type)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func webCustomItems(spansJSON json: String) -> [String: Data] {
        guard let payload = json.data(using: .utf8),
              let map = try? JSONSerialization.data(
                withJSONObject: [webSpansTypeIdentifier: webCustomPayloadIdentifier]
              )
        else { return [:] }
        return [webCustomMapIdentifier: map, webCustomPayloadIdentifier: payload]
    }

    static func html(from spans: [SpanNode]) -> String {
        NoteExporter.htmlFragment(from: spans)
    }

    static func markdown(from spans: [SpanNode]) -> String {
        var lines: [String] = []
        var i = 0
        while i < spans.count {
            guard case .block(let block) = spans[i] else {
                i += 1
                continue
            }
            var runs: [(String, [String: JSONValue])] = []
            var j = i + 1
            while j < spans.count {
                if case .block = spans[j] { break }
                if case .text(let text, let marks) = spans[j] {
                    runs.append((text, marks))
                }
                j += 1
            }
            let content = runs.map { markdownInline($0.0, marks: $0.1) }.joined()
            let indent = String(repeating: "  ", count: block.parents.count)
            switch block.type {
            case "heading":
                let level = min(max(block.headingLevel ?? 1, 1), 6)
                lines.append(String(repeating: "#", count: level) + " " + content)
            case "unordered-list-item":
                lines.append(indent + "- " + content)
            case "ordered-list-item":
                lines.append(indent + "1. " + content)
            case "todo-list-item":
                lines.append(indent + "- [" + (block.isChecked ? "x" : " ") + "] " + content)
            case "blockquote":
                lines.append("> " + content)
            case "code-block":
                var codeLines = [plainText(runs)]
                while j < spans.count,
                      case .block(let next) = spans[j],
                      next.type == "code-block",
                      next.codeLanguage == block.codeLanguage,
                      next.parents == block.parents {
                    var nextRuns: [(String, [String: JSONValue])] = []
                    j += 1
                    while j < spans.count {
                        if case .block = spans[j] { break }
                        if case .text(let text, let marks) = spans[j] {
                            nextRuns.append((text, marks))
                        }
                        j += 1
                    }
                    codeLines.append(plainText(nextRuns))
                }
                let language = block.codeLanguage == CodeLanguage.plain.id ? "" : block.codeLanguage
                lines.append("```" + language + "\n" + codeLines.joined(separator: "\n") + "\n```")
            case "html":
                if let source = block.htmlSource {
                    lines.append(source)
                }
            default:
                if block.isEmbedBlock {
                    lines.append("[attachment]")
                } else {
                    lines.append(escapeLeadingMarker(content))
                }
            }
            i = j
        }
        return lines.joined(separator: "\n")
    }

    static func attributed(fromSpansJSON json: String, cache: AssetCache) -> NSAttributedString? {
        let spans = SpanNode.decodeList(json)
        guard !spans.isEmpty else { return nil }
        return RichText.attributed(from: spans, cache: cache)
    }

    static func attributed(fromHTML html: String, cache: AssetCache) -> NSAttributedString? {
        let spans = spans(fromHTML: html)
        guard !spans.isEmpty else { return nil }
        return RichText.attributed(from: spans, cache: cache)
    }

    static func attributed(fromMarkdown markdown: String, cache: AssetCache) -> NSAttributedString? {
        guard looksLikeMarkdown(markdown) else { return nil }
        let spans = spans(fromMarkdown: markdown)
        guard !spans.isEmpty else { return nil }
        return RichText.attributed(from: spans, cache: cache)
    }

    static func looksLikeMarkdown(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("# ")
                || line.hasPrefix("## ")
                || line.hasPrefix("### ")
                || line.hasPrefix("- ")
                || line.hasPrefix("* ")
                || line.hasPrefix("> ")
                || line.hasPrefix("- [ ] ")
                || line.hasPrefix("- [x] ")
                || line.hasPrefix("- [X] ")
                || orderedListPrefixLength(in: line) != nil
                || line.hasPrefix("```")
        }
    }

    static func spans(fromHTML html: String) -> [SpanNode] {
        guard let data = html.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ],
                documentAttributes: nil
              )
        else { return [] }
        return spans(fromAttributedHTML: attributed)
    }

    static func spans(fromMarkdown markdown: String) -> [SpanNode] {
        var spans: [SpanNode] = []
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var inFence = false
        var fenceLanguage = ""
        var fenceLines: [String] = []
        var listTypeByDepth: [String] = []
        let listTypes: Set<String> = ["unordered-list-item", "ordered-list-item", "todo-list-item"]

        func flushFence() {
            var block = BlockValue(type: "code-block")
            if !fenceLanguage.isEmpty {
                block.attrs["language"] = .string(fenceLanguage)
            }
            for line in fenceLines.isEmpty ? [""] : fenceLines {
                spans.append(.block(block))
                if !line.isEmpty {
                    spans.append(.text(line, [:]))
                }
            }
            fenceLines = []
            fenceLanguage = ""
        }

        for rawLine in lines {
            if rawLine.hasPrefix("```") {
                if inFence {
                    flushFence()
                    inFence = false
                } else {
                    inFence = true
                    fenceLanguage = String(rawLine.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if inFence {
                fenceLines.append(rawLine)
                continue
            }

            let line = rawLine.trimmingCharacters(in: .whitespaces)
            var block: BlockValue
            let content: String
            if line.hasPrefix("### ") {
                block = .heading(level: 3)
                content = String(line.dropFirst(4))
            } else if line.hasPrefix("## ") {
                block = .heading(level: 2)
                content = String(line.dropFirst(3))
            } else if line.hasPrefix("# ") {
                block = .heading(level: 1)
                content = String(line.dropFirst(2))
            } else if line.hasPrefix("- [ ] ") {
                block = .todo(checked: false)
                content = String(line.dropFirst(6))
            } else if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
                block = .todo(checked: true)
                content = String(line.dropFirst(6))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                block = BlockValue(type: "unordered-list-item")
                content = String(line.dropFirst(2))
            } else if line.hasPrefix("> ") {
                block = BlockValue(type: "blockquote")
                content = String(line.dropFirst(2))
            } else if let prefixLength = orderedListPrefixLength(in: line) {
                block = BlockValue(type: "ordered-list-item")
                content = String(line.dropFirst(prefixLength))
            } else {
                block = .paragraph
                content = rawLine
            }
            if listTypes.contains(block.type) {
                let indent = rawLine.prefix(while: { $0 == " " }).count / 2
                let depth = min(indent, listTypeByDepth.count)
                listTypeByDepth = Array(listTypeByDepth.prefix(depth))
                block.parents = listTypeByDepth
                listTypeByDepth.append(block.type)
            } else {
                listTypeByDepth = []
            }
            spans.append(.block(block))
            for run in inlineRuns(fromMarkdown: content) {
                spans.append(.text(run.text, run.marks))
            }
        }
        if inFence {
            flushFence()
        }
        return spans
    }

    private static func spans(fromAttributedHTML attr: NSAttributedString) -> [SpanNode] {
        var spans: [SpanNode] = []
        let str = attr.string as NSString
        var location = 0
        while location < str.length {
            let paragraph = str.paragraphRange(for: NSRange(location: location, length: 0))
            guard paragraph.length > 0 else { break }
            location = NSMaxRange(paragraph)

            var content = paragraph
            if str.character(at: NSMaxRange(paragraph) - 1) == 0x0A {
                content.length -= 1
            }
            let startAttrs = attr.attributes(at: paragraph.location, effectiveRange: nil)
            let style = startAttrs[.paragraphStyle] as? NSParagraphStyle
            var block = BlockValue.paragraph
            if let lists = style?.textLists, !lists.isEmpty {
                let ordered = lists.last.map {
                    String(describing: $0.markerFormat).contains("decimal")
                } ?? false
                block = BlockValue(type: ordered ? "ordered-list-item" : "unordered-list-item")
                trimListMarker(in: str, range: &content)
            } else if let font = startAttrs[.font] as? PFont,
                      font.hasBoldTrait,
                      font.pointSize >= 17,
                      content.length > 0 {
                block = .heading(level: font.pointSize >= 22 ? 1 : 2)
            }
            spans.append(.block(block))

            guard content.length > 0 else { continue }
            attr.enumerateAttributes(in: content) { runAttrs, runRange, _ in
                let text = str.substring(with: runRange)
                    .replacingOccurrences(of: "\u{FFFC}", with: "")
                guard !text.isEmpty else { return }
                spans.append(.text(text, RichText.marks(from: runAttrs, block: block)))
            }
        }
        return spans
    }

    private static func trimListMarker(in str: NSString, range: inout NSRange) {
        guard range.length > 0 else { return }
        let text = str.substring(with: range)
        let markerCharacters: Int
        if text.hasPrefix("- ") || text.hasPrefix("* ") {
            markerCharacters = 2
        } else {
            markerCharacters = orderedListPrefixLength(in: text) ?? 0
        }
        let markerLength = String(text.prefix(markerCharacters)).utf16.count
        range.location += markerLength
        range.length = max(0, range.length - markerLength)
    }

    private static func orderedListPrefixLength(in line: String) -> Int? {
        var digits = 0
        for character in line {
            if character.isNumber {
                digits += 1
                continue
            }
            guard digits > 0, character == "." || character == ")" else { return nil }
            let next = line.index(line.startIndex, offsetBy: digits + 1)
            guard next < line.endIndex, line[next] == " " else { return nil }
            return digits + 2
        }
        return nil
    }

    private static func markdownInline(_ text: String, marks: [String: JSONValue]) -> String {
        let isCode = marks["code"] == .bool(true)
        var out = isCode ? "`" + text + "`" : escapeMarkdown(text)
        if case .bool(true)? = marks["strong"] { out = "**" + out + "**" }
        if case .bool(true)? = marks["em"] { out = "*" + out + "*" }
        if case .bool(true)? = marks["strikethrough"] { out = "~~" + out + "~~" }
        if let link = marks["link"]?.stringValue { out = "[" + out + "](" + link + ")" }
        return out
    }

    private static func escapeMarkdown(_ text: String) -> String {
        var out = ""
        for character in text {
            if "\\`*_~[".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// A paragraph whose text starts like a block marker would import as that
    /// block; a leading backslash keeps it a paragraph.
    private static func escapeLeadingMarker(_ line: String) -> String {
        if let first = line.first, "#->".contains(first) {
            return "\\" + line
        }
        if let prefixLength = orderedListPrefixLength(in: line) {
            let dot = line.index(line.startIndex, offsetBy: prefixLength - 2)
            return String(line[..<dot]) + "\\" + String(line[dot...])
        }
        return line
    }

    private static func plainText(_ runs: [(String, [String: JSONValue])]) -> String {
        runs.map(\.0).joined()
    }

    private static func inlineRuns(fromMarkdown text: String) -> [(text: String, marks: [String: JSONValue])] {
        var runs: [(String, [String: JSONValue])] = []
        var index = text.startIndex
        var plainStart = index

        func flushPlain(upTo end: String.Index) {
            guard plainStart < end else { return }
            runs.append((String(text[plainStart..<end]), [:]))
        }

        let punctuation = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"

        while index < text.endIndex {
            let rest = text[index...]
            if rest.hasPrefix("\\"),
               text.index(after: index) < text.endIndex,
               punctuation.contains(text[text.index(after: index)]) {
                flushPlain(upTo: index)
                let escaped = text.index(after: index)
                runs.append((String(text[escaped]), [:]))
                index = text.index(after: escaped)
                plainStart = index
            } else if rest.hasPrefix("**"),
               let end = text[rest.index(index, offsetBy: 2)...].range(of: "**")?.lowerBound {
                flushPlain(upTo: index)
                let bodyStart = text.index(index, offsetBy: 2)
                runs.append((String(text[bodyStart..<end]), ["strong": .bool(true)]))
                index = text.index(end, offsetBy: 2)
                plainStart = index
            } else if rest.hasPrefix("~~"),
                      let end = text[rest.index(index, offsetBy: 2)...].range(of: "~~")?.lowerBound {
                flushPlain(upTo: index)
                let bodyStart = text.index(index, offsetBy: 2)
                runs.append((String(text[bodyStart..<end]), ["strikethrough": .bool(true)]))
                index = text.index(end, offsetBy: 2)
                plainStart = index
            } else if rest.hasPrefix("`"),
                      let end = text[text.index(after: index)...].firstIndex(of: "`") {
                flushPlain(upTo: index)
                runs.append((String(text[text.index(after: index)..<end]), ["code": .bool(true)]))
                index = text.index(after: end)
                plainStart = index
            } else if rest.hasPrefix("["),
                      let close = text[index...].firstIndex(of: "]"),
                      close < text.index(before: text.endIndex),
                      text[text.index(after: close)] == "(",
                      let end = text[text.index(after: text.index(after: close))...].firstIndex(of: ")") {
                flushPlain(upTo: index)
                let title = String(text[text.index(after: index)..<close])
                let urlStart = text.index(after: text.index(after: close))
                let url = String(text[urlStart..<end])
                runs.append((title, ["link": .string(url)]))
                index = text.index(after: end)
                plainStart = index
            } else if rest.hasPrefix("*"),
                      let end = text[text.index(after: index)...].firstIndex(of: "*") {
                flushPlain(upTo: index)
                runs.append((String(text[text.index(after: index)..<end]), ["em": .bool(true)]))
                index = text.index(after: end)
                plainStart = index
            } else {
                index = text.index(after: index)
            }
        }
        flushPlain(upTo: text.endIndex)
        var merged: [(String, [String: JSONValue])] = []
        for run in runs {
            if let last = merged.last, last.1 == run.1 {
                merged[merged.count - 1].0 += run.0
            } else {
                merged.append(run)
            }
        }
        return merged
    }
}
