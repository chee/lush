import Foundation
import EventKit

/// A change the chat wants to make. Nothing here has happened yet — the model
/// queues these by calling a write tool, and they only touch a document when
/// the person presses Apply.
struct NoteChatProposal: Identifiable, Codable, Equatable {
    let id: UUID
    let action: NoteChatAction

    init(id: UUID = UUID(), action: NoteChatAction) {
        self.id = id
        self.action = action
    }

    var title: String {
        switch action {
        case .editNote: "Edit this note"
        case .createNote(let title, _, _): "New note “\(title.isEmpty ? "Untitled" : title)”"
        case .appendToNote(_, let name, _): "Append to “\(name)”"
        case .renameNote(_, let name, let title): "Rename “\(name)” to “\(title)”"
        case .linkEvent(_, let name, let events): "Link “\(name)” to \(events.count) event\(events.count == 1 ? "" : "s")"
        }
    }

    var detail: [String] {
        switch action {
        case .editNote(_, let ops, _): ops.map(\.summary)
        case .createNote(_, _, let markdown): markdown.components(separatedBy: "\n")
        case .appendToNote(_, _, let markdown): markdown.components(separatedBy: "\n")
        case .renameNote: []
        case .linkEvent(_, _, let events): events.map(\.title)
        }
    }
}

enum NoteChatAction: Codable, Equatable {
    /// `spans` is the note as it looks with `ops` already applied, computed
    /// when the model proposed them so that Apply is exactly what was shown.
    case editNote(url: String, ops: [NoteChatOp], spans: String)
    case createNote(title: String, folderUrl: String?, markdown: String)
    case appendToNote(url: String, name: String, markdown: String)
    case renameNote(url: String, name: String, title: String)
    case linkEvent(url: String, name: String, events: [LinkedEvent])

    struct LinkedEvent: Codable, Equatable {
        let id: String
        let title: String
    }

    @MainActor
    func apply(model: NotesModel) async -> String? {
        switch self {
        case .editNote(let url, _, let spans):
            let decoded = SpanNode.decodeList(spans)
            guard !decoded.isEmpty else { return "The edit produced an empty note." }
            await model.updateDocument(url, json: spans, title: RichText.title(from: decoded))
            return nil
        case .createNote(let title, let folderUrl, let markdown):
            guard let core = model.core else { return "Lush is still starting." }
            let spans = SpanNode.encodeList(
                [.block(.heading(level: 1)), .text(title, [:])]
                    + RichTextClipboard.spans(fromMarkdown: markdown)
            )
            do {
                _ = try await Task.detached { [core, folderUrl, title, spans] () -> String in
                    let url = if let folderUrl, !folderUrl.isEmpty {
                        try core.createNoteIn(folderUrl: folderUrl, title: title)
                    } else {
                        try core.createNoteDoc(title: title)
                    }
                    if folderUrl == nil || folderUrl?.isEmpty == true {
                        try? core.linkNoteToFolder(noteUrl: url, title: title)
                    }
                    _ = try? core.updateNoteSpans(url: url, spansJson: spans, heads: nil)
                    return url
                }.value
                model.refreshNotes()
                return nil
            } catch {
                return error.localizedDescription
            }
        case .appendToNote(let url, _, let markdown):
            let spans = SpanNode.decodeList(await model.spansJSON(for: url))
                + RichTextClipboard.spans(fromMarkdown: markdown)
            await model.updateDocument(url, json: SpanNode.encodeList(spans), title: RichText.title(from: spans))
            return nil
        case .renameNote(let url, _, let title):
            guard let core = model.core else { return "Lush is still starting." }
            do {
                try await Task.detached { [core, url, title] in
                    try core.renameNote(url: url, title: title)
                }.value
                model.refreshNotes()
                return nil
            } catch {
                return error.localizedDescription
            }
        case .linkEvent(let url, _, let events):
            CalendarLinks.set(events.map(\.id), for: url)
            return nil
        }
    }
}

struct NoteChatToolCall: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let detail: String

    init(id: UUID = UUID(), name: String, detail: String) {
        self.id = id
        self.name = name
        self.detail = detail
    }
}

/// One question's worth of tool state: the note the chat is about, whatever the
/// model has read so far, and the changes it has queued.
@MainActor
final class NoteChatSession {
    let model: NotesModel
    let url: String
    let title: String
    var spans: [SpanNode]
    var attachments: [NoteAttachment]
    private(set) var calls: [NoteChatToolCall] = []
    private(set) var proposals: [NoteChatProposal] = []

    init(model: NotesModel, url: String, title: String, spans: [SpanNode], attachments: [NoteAttachment]) {
        self.model = model
        self.url = url
        self.title = title
        self.spans = spans
        self.attachments = attachments
    }

    var outline: String { NoteChatEdits.outlineText(spans) }

    static let catalog = """
    search_notes {"query": string} — search every note by text and meaning
    read_note {"url": string} — the block outline of another note
    list_folder {"url": string?} — folders and notes; omit url for the roots
    read_attachment {"number": int} — the contents of an attachment on this note
    read_agenda {"days": int?} — calendar events and reminders, default 7 days
    edit_note {"ops": [op, ...]} — propose changes to the note being discussed
    create_note {"title": string, "markdown": string?, "folder_url": string?}
    append_to_note {"url": string, "markdown": string}
    rename_note {"url": string, "title": string}
    link_note_to_event {"event_ids": [string], "url": string?}

    Ops for edit_note, each addressing a block by its number in the outline:
    {"op": "replace", "block": 3, "markdown": "new text"}
    {"op": "insert_after", "block": 3, "markdown": "a line\\nanother line"}
    {"op": "insert_before", "block": 3, "markdown": "..."}
    {"op": "delete", "block": 3}
    {"op": "set_type", "block": 3, "style": "heading2"}
    {"op": "mark", "block": 3, "text": "exact words", "mark": "strong"}
    {"op": "insert_table", "after": 3, "header": true, "rows": [["Name", "Qty"], ["Milk", "2"]]}

    Styles: \(NoteChatEdits.styles.joined(separator: ", ")).
    Marks: \(NoteChatEdits.marks.joined(separator: ", ")); value carries the link \
    url, the highlight colour (\(Highlight.names.joined(separator: ", "))), or the \
    font role (\(RichText.fontRoles.map(\.key).joined(separator: ", "))).
    Markdown in any op: **bold**, *italic*, `code`, ~~strike~~, [text](url), \
    <u>underline</u>, <mark class="yellow">highlight</mark>, <sup>x</sup>, <sub>x</sub>, \
    # heading, - bullet, 1. number, - [ ] to-do, > quote.

    The four tools that change something queue a proposal for the person to \
    accept or reject; nothing is written when you call them. Do not call one \
    twice for the same change.
    """

    /// Runs a read tool for real; queues a write tool as a proposal. The
    /// returned string is what the model sees next round.
    func run(_ name: String, arguments: [String: Any]) async -> String {
        let result = await execute(name, arguments: arguments)
        calls.append(NoteChatToolCall(name: name, detail: NoteChatEdits.short(describe(arguments), limit: 80)))
        return result
    }

    private func describe(_ arguments: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private func execute(_ name: String, arguments: [String: Any]) async -> String {
        switch name {
        case "search_notes":
            guard let query = arguments["query"] as? String, !query.isEmpty else {
                return "search_notes needs a query."
            }
            let hits = await model.search(query)
            guard !hits.isEmpty else { return "No notes matched \(query)." }
            return hits.prefix(12).map {
                "\($0.name.isEmpty ? "Untitled" : $0.name) — \($0.url)\n  \(NoteChatEdits.short($0.snippet, limit: 160))"
            }.joined(separator: "\n")

        case "read_note":
            guard let url = arguments["url"] as? String, !url.isEmpty else {
                return "read_note needs a url."
            }
            let spans = SpanNode.decodeList(await model.spansJSON(for: url))
            guard !spans.isEmpty else { return "That note is empty or could not be read." }
            return "\(model.node(for: url)?.displayName ?? "Untitled")\n\(NoteChatEdits.outlineText(spans))"

        case "list_folder":
            let nodes: [FolderNode]
            if let url = arguments["url"] as? String, !url.isEmpty {
                guard let node = model.node(for: url) else { return "No folder at that url." }
                nodes = node.children ?? []
            } else {
                nodes = model.folderTree
            }
            guard !nodes.isEmpty else { return "Empty." }
            return nodes.map { "\($0.kind): \($0.displayName) — \($0.url)" }.joined(separator: "\n")

        case "read_attachment":
            let number = (arguments["number"] as? Int) ?? (arguments["number"] as? NSNumber)?.intValue ?? 0
            guard let attachment = attachments.first(where: { $0.number == number }) else {
                return "This note has no attachment \(number)."
            }
            if attachment.isPatchworkDoc, let url = attachment.url,
               let json = try? await PatchworkScripting.shared.documentJSON(url) {
                return String(json.prefix(8_000))
            }
            let parts = [attachment.description, attachment.text, attachment.summary]
                .filter { !$0.isEmpty }
            return parts.isEmpty ? "Nothing has been extracted from that attachment." : parts.joined(separator: "\n")

        case "read_agenda":
            let days = (arguments["days"] as? Int) ?? (arguments["days"] as? NSNumber)?.intValue ?? 7
            let store = AgendaStore.shared
            if store.items.isEmpty, store.access == .fullAccess {
                await store.refresh()
            }
            guard store.access == .fullAccess || store.reminderAccess == .fullAccess else {
                return "Lush does not have calendar access."
            }
            let horizon = Date().addingTimeInterval(TimeInterval(max(days, 1)) * 86_400)
            let items = store.items.filter { $0.start <= horizon }
            guard !items.isEmpty else { return "Nothing scheduled in the next \(days) days." }
            return items.prefix(40).map {
                "\($0.id) — \($0.title) — \($0.start.formatted(date: .abbreviated, time: .shortened)) — \($0.listName)"
            }.joined(separator: "\n")

        case "edit_note":
            let ops = NoteChatOp.list(from: arguments["ops"])
            guard !ops.isEmpty else { return "edit_note needs at least one op." }
            let applied = NoteChatEdits.apply(ops, to: spans)
            guard applied.failures.count < ops.count else {
                return "Nothing was changed: \(applied.failures.joined(separator: "; "))."
            }
            spans = applied.spans
            propose(.editNote(url: url, ops: ops, spans: SpanNode.encodeList(applied.spans)))
            let trouble = applied.failures.isEmpty ? "" : " Skipped: \(applied.failures.joined(separator: "; "))."
            return """
            Queued for the person to accept.\(trouble) The note now reads:
            \(outline)
            """

        case "create_note":
            let title = arguments["title"] as? String ?? ""
            guard !title.isEmpty || arguments["markdown"] is String else {
                return "create_note needs a title or markdown."
            }
            propose(.createNote(
                title: title,
                folderUrl: arguments["folder_url"] as? String,
                markdown: arguments["markdown"] as? String ?? ""
            ))
            return "Queued for the person to accept. It does not exist yet, so it cannot be read."

        case "append_to_note":
            guard let url = arguments["url"] as? String, !url.isEmpty,
                  let markdown = arguments["markdown"] as? String, !markdown.isEmpty
            else { return "append_to_note needs a url and markdown." }
            propose(.appendToNote(url: url, name: displayName(of: url), markdown: markdown))
            return "Queued for the person to accept."

        case "rename_note":
            guard let url = arguments["url"] as? String, !url.isEmpty,
                  let title = arguments["title"] as? String, !title.isEmpty
            else { return "rename_note needs a url and title." }
            propose(.renameNote(url: url, name: displayName(of: url), title: title))
            return "Queued for the person to accept."

        case "link_note_to_event":
            let ids = (arguments["event_ids"] as? [String]) ?? [arguments["event_id"] as? String].compactMap { $0 }
            guard !ids.isEmpty else { return "link_note_to_event needs event_ids." }
            let target = (arguments["url"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url
            let titles = AgendaStore.shared.items
            let events = ids.map { id in
                NoteChatAction.LinkedEvent(id: id, title: titles.first { $0.id == id }?.title ?? id)
            }
            propose(.linkEvent(url: target, name: displayName(of: target), events: events))
            return "Queued for the person to accept."

        default:
            return "There is no tool called \(name)."
        }
    }

    private func propose(_ action: NoteChatAction) {
        proposals.append(NoteChatProposal(action: action))
    }

    private func displayName(of url: String) -> String {
        url == self.url ? title : (model.node(for: url)?.displayName ?? "Untitled")
    }
}
