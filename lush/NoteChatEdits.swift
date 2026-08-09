import Foundation

/// One numbered block of a note as the chat model sees it. Numbers are 1-based
/// positions in the note's block order, nested blocks included, and are valid
/// for the outline they were read from — ops resolve against that snapshot.
struct NoteChatBlock: Equatable {
    let number: Int
    let start: Int
    let end: Int
    let block: BlockValue
    let markdown: String
    let attachment: Int?
}

enum NoteChatOp: Codable, Equatable {
    case replace(block: Int, markdown: String)
    case insertAfter(block: Int, markdown: String)
    case insertBefore(block: Int, markdown: String)
    case delete(block: Int)
    case setType(block: Int, style: String)
    case mark(block: Int, text: String, mark: String, value: String?)
    case insertTable(after: Int, header: Bool, rows: [[String]])
    case insertColumns(after: Int, columns: [String])
    case insertEmbed(after: Int, url: String)
    case moveBlock(block: Int, after: Int)
    case setCodeLanguage(block: Int, language: String)
    case setIndent(block: Int, level: Int)

    var summary: String {
        switch self {
        case .replace(let block, let markdown):
            "replace block \(block) with \(NoteChatEdits.short(markdown))"
        case .insertAfter(let block, let markdown):
            "insert after block \(block): \(NoteChatEdits.short(markdown))"
        case .insertBefore(let block, let markdown):
            "insert before block \(block): \(NoteChatEdits.short(markdown))"
        case .delete(let block):
            "delete block \(block)"
        case .setType(let block, let style):
            "make block \(block) a \(style)"
        case .mark(let block, let text, let mark, let value):
            "mark \(NoteChatEdits.short(text)) in block \(block) as \(value.map { "\(mark) \($0)" } ?? mark)"
        case .insertTable(let after, _, let rows):
            "insert a \(rows.count)×\(rows.map(\.count).max() ?? 0) table after block \(after)"
        case .insertColumns(let after, let columns):
            "insert \(columns.count) columns after block \(after)"
        case .insertEmbed(let after, let url):
            "embed \(NoteChatEdits.short(url, limit: 40)) after block \(after)"
        case .moveBlock(let block, let after):
            "move block \(block) after block \(after)"
        case .setCodeLanguage(let block, let language):
            "set block \(block) to \(language)"
        case .setIndent(let block, let level):
            "indent block \(block) to level \(level)"
        }
    }

    static func list(from value: Any?) -> [NoteChatOp] {
        if let one = value as? [String: Any] {
            return [NoteChatOp(json: one)].compactMap { $0 }
        }
        guard let raw = value as? [[String: Any]] else { return [] }
        return raw.compactMap(NoteChatOp.init(json:))
    }

    init?(json: [String: Any]) {
        let block = (json["block"] as? Int) ?? (json["block"] as? NSNumber)?.intValue ?? 0
        let markdown = json["markdown"] as? String ?? json["text"] as? String ?? ""
        switch json["op"] as? String {
        case "replace":
            self = .replace(block: block, markdown: markdown)
        case "insert_after":
            self = .insertAfter(block: block, markdown: markdown)
        case "insert_before":
            self = .insertBefore(block: block, markdown: markdown)
        case "delete":
            self = .delete(block: block)
        case "set_type":
            guard let style = json["style"] as? String else { return nil }
            self = .setType(block: block, style: style)
        case "mark":
            guard let text = json["text"] as? String, let mark = json["mark"] as? String else { return nil }
            self = .mark(block: block, text: text, mark: mark, value: json["value"] as? String)
        case "insert_table":
            let rows = (json["rows"] as? [[Any]])?.map { $0.map { "\($0)" } } ?? []
            guard !rows.isEmpty else { return nil }
            self = .insertTable(
                after: NoteChatOp.number(json["after"]) ?? block,
                header: json["header"] as? Bool ?? true,
                rows: rows
            )
        case "insert_columns":
            let columns = (json["columns"] as? [Any])?.map { "\($0)" } ?? []
            guard columns.count > 1 else { return nil }
            self = .insertColumns(after: NoteChatOp.number(json["after"]) ?? block, columns: columns)
        case "insert_embed":
            guard let url = json["url"] as? String, !url.isEmpty else { return nil }
            self = .insertEmbed(after: NoteChatOp.number(json["after"]) ?? block, url: url)
        case "move_block":
            guard let after = NoteChatOp.number(json["after"]) else { return nil }
            self = .moveBlock(block: block, after: after)
        case "set_code_language":
            guard let language = json["language"] as? String, !language.isEmpty else { return nil }
            self = .setCodeLanguage(block: block, language: language)
        case "set_indent":
            self = .setIndent(block: block, level: NoteChatOp.number(json["level"]) ?? 0)
        default:
            return nil
        }
    }

    private static func number(_ value: Any?) -> Int? {
        (value as? Int) ?? (value as? NSNumber)?.intValue
    }
}

@MainActor
enum NoteChatEdits {
    static let styles = [
        "paragraph", "heading1", "heading2", "heading3",
        "unordered-list-item", "ordered-list-item",
        "todo-list-item", "todo-checked", "todo-canceled", "todo-pending",
        "blockquote", "code-block",
    ]

    static let marks = [
        "strong", "em", "code", "underline", "strikethrough",
        "highlight", "superscript", "subscript", "link", "font",
    ]

    /// Every block in span order, nested ones included. Tables and columns own
    /// their descendants, so deleting or moving one takes the whole structure.
    static func outline(_ spans: [SpanNode]) -> [NoteChatBlock] {
        var out: [NoteChatBlock] = []
        var attachments = 0
        for (index, span) in spans.enumerated() {
            guard case .block(let block) = span else { continue }
            var end = index + 1
            while end < spans.count, !isBlock(spans[end]) { end += 1 }
            // a table or columns block owns its whole structure, so it moves
            // and deletes as one thing — the text inside belongs to the cells
            let container = block.type == "table" || block.type == "columns"
            let content = end
            if container {
                let depth = block.parents.count
                while end < spans.count {
                    if case .block(let next) = spans[end], next.parents.count <= depth { break }
                    end += 1
                }
            }
            var attachment: Int?
            if block.isEmbedBlock, block.type != "html" {
                attachments += 1
                attachment = attachments
            }
            out.append(NoteChatBlock(
                number: out.count + 1,
                start: index,
                end: end,
                block: block,
                markdown: inlineMarkdown(spans[(index + 1)..<min(content, spans.count)]),
                attachment: attachment
            ))
        }
        return out
    }

    static func outlineText(_ spans: [SpanNode]) -> String {
        let blocks = outline(spans)
        guard !blocks.isEmpty else { return "The note is empty." }
        return blocks.map { entry in
            let indent = String(repeating: "  ", count: entry.block.parents.count)
            let content = entry.markdown.isEmpty ? "" : ": \(entry.markdown)"
            return "\(entry.number). \(indent)\(descriptor(entry))\(content)"
        }.joined(separator: "\n")
    }

    private static func descriptor(_ entry: NoteChatBlock) -> String {
        let block = entry.block
        switch block.type {
        case "heading":
            return "heading\(min(max(block.headingLevel ?? 1, 1), 6))"
        case "todo-list-item":
            return "todo(\(block.todoState.rawValue))"
        case "code-block":
            return "code(\(block.codeLanguage))"
        case "table", "columns", "table-row", "table-cell", "table-header-cell", "column":
            return block.type
        case "context":
            return "context strip"
        case "html":
            return "html"
        default:
            if let attachment = entry.attachment {
                return "\(block.type) [attachment \(attachment)]"
            }
            return block.type
        }
    }

    static func apply(_ ops: [NoteChatOp], to spans: [SpanNode]) -> (spans: [SpanNode], failures: [String]) {
        let blocks = outline(spans)
        var edits: [(at: Int, remove: Int, insert: [SpanNode], order: Int)] = []
        var failures: [String] = []

        func block(_ number: Int) -> NoteChatBlock? {
            let found = blocks.first { $0.number == number }
            if found == nil { failures.append("no block \(number)") }
            return found
        }

        for (order, op) in ops.enumerated() {
            switch op {
            case .replace(let number, let markdown):
                guard let entry = block(number) else { continue }
                edits.append((entry.start, entry.end - entry.start, reparented(markdown, like: entry.block), order))
            case .insertAfter(let number, let markdown):
                guard let entry = block(number) else { continue }
                edits.append((entry.end, 0, reparented(markdown, like: sibling(of: entry)), order))
            case .insertBefore(let number, let markdown):
                guard let entry = block(number) else { continue }
                edits.append((entry.start, 0, reparented(markdown, like: sibling(of: entry)), order))
            case .delete(let number):
                guard let entry = block(number) else { continue }
                edits.append((entry.start, entry.end - entry.start, [], order))
            case .setType(let number, let style):
                guard let entry = block(number) else { continue }
                guard let retyped = retyped(entry.block, style: style) else {
                    failures.append("unknown style \(style)")
                    continue
                }
                edits.append((entry.start, 1, [.block(retyped)], order))
            case .mark(let number, let text, let name, let value):
                guard let entry = block(number) else { continue }
                guard let marked = marking(
                    Array(spans[(entry.start + 1)..<entry.end]), text: text, mark: name, value: value
                ) else {
                    failures.append("\(NoteChatEdits.short(text)) is not in block \(number)")
                    continue
                }
                edits.append((entry.start + 1, entry.end - entry.start - 1, marked, order))
            case .insertTable(let number, let header, let rows):
                guard let entry = block(number) else { continue }
                let grid = TableGrid(
                    rows: rows.map { row in row.map { RichTextClipboard.inlineSpans(fromMarkdown: $0) } },
                    hasHeader: header
                )
                edits.append((entry.end, 0, RichText.tableSpans(grid), order))
            case .insertColumns(let number, let columns):
                guard let entry = block(number) else { continue }
                let spans = RichText.columnsSpans(columns.map { RichTextClipboard.spans(fromMarkdown: $0) })
                edits.append((entry.end, 0, spans, order))
            case .insertEmbed(let number, let url):
                guard let entry = block(number) else { continue }
                edits.append((entry.end, 0, [.block(.embed(url: url))], order))
            case .moveBlock(let number, let target):
                guard let entry = block(number), let destination = block(target) else { continue }
                guard !(destination.start >= entry.start && destination.start < entry.end) else {
                    failures.append("block \(target) is inside block \(number)")
                    continue
                }
                // already there: removing and reinserting at the same index
                // would race with itself
                guard destination.end != entry.start else { continue }
                let moving = Array(spans[entry.start..<entry.end]).map { span -> SpanNode in
                    guard case .block(var moved) = span else { return span }
                    moved.parents = destination.block.parents
                        + moved.parents.dropFirst(entry.block.parents.count)
                    return .block(moved)
                }
                edits.append((entry.start, entry.end - entry.start, [], order))
                edits.append((destination.end, 0, moving, order))
            case .setCodeLanguage(let number, let language):
                guard let entry = block(number) else { continue }
                var retyped = entry.block
                retyped.type = "code-block"
                retyped.attrs["language"] = .string(language)
                edits.append((entry.start, 1, [.block(retyped)], order))
            case .setIndent(let number, let level):
                guard let entry = block(number) else { continue }
                var indented = entry.block
                if level <= 0 {
                    indented.attrs.removeValue(forKey: "indent")
                } else {
                    indented.attrs["indent"] = .int(Int64(min(level, 8)))
                }
                edits.append((entry.start, 1, [.block(indented)], order))
            }
        }

        // later positions first so earlier indices stay valid; ties keep the
        // order the model listed them in
        var out = spans
        for edit in edits.sorted(by: { $0.at == $1.at ? $0.order > $1.order : $0.at > $1.at }) {
            let end = min(edit.at + edit.remove, out.count)
            guard edit.at <= end else { continue }
            out.replaceSubrange(edit.at..<end, with: edit.insert)
        }
        return (out, failures)
    }

    /// An inserted sibling inherits the nesting of the block it lands beside —
    /// text added next to a list item stays in the list, text added in a table
    /// cell stays in the cell.
    private static func sibling(of entry: NoteChatBlock) -> BlockValue {
        var block = entry.block
        if block.type == "table" || block.type == "columns" {
            block = BlockValue(type: "paragraph", parents: entry.block.parents)
        }
        return block
    }

    private static func reparented(_ markdown: String, like model: BlockValue) -> [SpanNode] {
        let parsed = RichTextClipboard.spans(fromMarkdown: markdown)
        guard !parsed.isEmpty else { return [] }
        return parsed.map { span in
            guard case .block(var block) = span else { return span }
            var parents = model.parents + block.parents
            // a plain paragraph keeps the neighbour's own kind (list item,
            // heading level); anything the markdown spelled out wins
            if block.type == "paragraph", model.type != "paragraph", !model.isAtomic {
                block = model
                block.attrs.removeValue(forKey: "checked")
                block.attrs.removeValue(forKey: "state")
                parents = model.parents
            }
            block.parents = parents
            return .block(block)
        }
    }

    private static func retyped(_ block: BlockValue, style: String) -> BlockValue? {
        guard styles.contains(style) else { return nil }
        var out: BlockValue
        switch style {
        case "todo-list-item", "todo-checked", "todo-canceled", "todo-pending":
            let state: TodoState = switch style {
            case "todo-checked": .checked
            case "todo-canceled": .canceled
            case "todo-pending": .pending
            default: .open
            }
            out = .todo(state: state)
        default:
            out = .fromStyleKey(style)
        }
        out.parents = block.parents
        if let indent = block.attrs["indent"] {
            out.attrs["indent"] = indent
        }
        return out
    }

    /// Adds a mark to the first occurrence of `text` in the block's runs,
    /// splitting runs at the boundaries and keeping the marks already there.
    private static func marking(
        _ runs: [SpanNode], text: String, mark: String, value: String?
    ) -> [SpanNode]? {
        guard marks.contains(mark), !text.isEmpty else { return nil }
        let plain = runs.reduce(into: "") { out, span in
            if case .text(let value, _) = span { out += value }
        }
        guard let found = plain.range(of: text) else { return nil }
        let target = plain.distance(from: plain.startIndex, to: found.lowerBound)
            ..< plain.distance(from: plain.startIndex, to: found.upperBound)

        let markValue: JSONValue = switch mark {
        case "link", "highlight", "font": .string(value ?? (mark == "highlight" ? "yellow" : ""))
        default: .bool(true)
        }
        if case .string(let string) = markValue, string.isEmpty { return nil }

        var out: [SpanNode] = []
        var offset = 0
        for span in runs {
            guard case .text(let value, let marks) = span else {
                out.append(span)
                continue
            }
            let range = offset..<(offset + value.count)
            offset = range.upperBound
            guard range.overlaps(target) else {
                out.append(span)
                continue
            }
            let lower = max(range.lowerBound, target.lowerBound) - range.lowerBound
            let upper = min(range.upperBound, target.upperBound) - range.lowerBound
            let characters = Array(value)
            var marked = marks
            marked[mark] = markValue
            if lower > 0 {
                out.append(.text(String(characters[0..<lower]), marks))
            }
            out.append(.text(String(characters[lower..<upper]), marked))
            if upper < characters.count {
                out.append(.text(String(characters[upper...]), marks))
            }
        }
        return out
    }

    private static func isBlock(_ span: SpanNode) -> Bool {
        if case .block = span { return true }
        return false
    }

    private static func inlineMarkdown(_ runs: ArraySlice<SpanNode>) -> String {
        runs.reduce(into: "") { out, span in
            if case .text(let text, let marks) = span {
                out += RichTextClipboard.inlineMarkdown(text, marks: marks)
            }
        }
    }

    nonisolated static func short(_ text: String, limit: Int = 60) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ")
        guard line.count > limit else { return line }
        return String(line.prefix(limit)) + "…"
    }
}
