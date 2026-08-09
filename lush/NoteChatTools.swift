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
        case .createFolder(let name, _): "New folder “\(name)”"
        case .moveNote(_, let name, _, let folder): "Move “\(name)” into “\(folder)”"
        case .deleteNote(_, let name): "Delete “\(name)”"
        case .revertNote(_, let name, _, let when): "Revert “\(name)” to \(when)"
        }
    }

    var detail: [String] {
        switch action {
        case .editNote(_, let ops, _, _): ops.map(\.summary)
        case .createNote(_, _, let markdown): markdown.components(separatedBy: "\n")
        case .appendToNote(_, _, let markdown): markdown.components(separatedBy: "\n")
        case .renameNote: []
        case .linkEvent(_, _, let events): events.map(\.title)
        case .createFolder: []
        case .moveNote: []
        case .deleteNote: ["This cannot be undone."]
        case .revertNote: ["Everything written since then is undone."]
        }
    }
}

enum NoteChatAction: Codable, Equatable {
    /// `spans` is the note as it looks with `ops` already applied, computed
    /// when the model proposed them so that Apply is exactly what was shown.
    /// `heads` are the note's heads when the model read it, so the core
    /// applies the edit as a fork of that state and merges it — anything
    /// written in the meantime, here or from a peer, survives.
    case editNote(url: String, ops: [NoteChatOp], spans: String, heads: [String])
    case createNote(title: String, folderUrl: String?, markdown: String)
    case appendToNote(url: String, name: String, markdown: String)
    case renameNote(url: String, name: String, title: String)
    case linkEvent(url: String, name: String, events: [LinkedEvent])
    case createFolder(name: String, parentUrl: String?)
    case moveNote(url: String, name: String, folderUrl: String, folderName: String)
    case deleteNote(url: String, name: String)
    case revertNote(url: String, name: String, heads: [String], when: String)

    struct LinkedEvent: Codable, Equatable {
        let id: String
        let title: String
    }

    @MainActor
    func apply(model: NotesModel) async -> String? {
        switch self {
        case .editNote(let url, _, let spans, let heads):
            let decoded = SpanNode.decodeList(spans)
            guard !decoded.isEmpty else { return "The edit produced an empty note." }
            await model.updateDocument(
                url, json: spans, title: RichText.title(from: decoded), heads: heads.isEmpty ? nil : heads
            )
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
                        try await core.linkNoteToFolder(noteUrl: url, title: title)
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
            guard let snapshot = await model.spansSnapshot(for: url) else {
                return "That note could not be read."
            }
            let spans = SpanNode.decodeList(snapshot.spansJson)
                + RichTextClipboard.spans(fromMarkdown: markdown)
            await model.updateDocument(
                url,
                json: SpanNode.encodeList(spans),
                title: RichText.title(from: spans),
                heads: snapshot.heads.isEmpty ? nil : snapshot.heads
            )
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
            let items = AgendaStore.shared.items
            guard let snapshot = await model.spansSnapshot(for: url) else {
                return "That note could not be read."
            }
            var spans = SpanNode.decodeList(snapshot.spansJson)
            let linked = Set(CalendarLinks.eventIds(in: spans))
            let fresh = events.compactMap { event in
                linked.contains(event.id) ? nil : items.first { $0.id == event.id }
            }
            guard !fresh.isEmpty else { return nil }
            spans += fresh.map { SpanNode.block(.calendarEventBlock($0)) }
            await model.updateDocument(
                url,
                json: SpanNode.encodeList(spans),
                title: RichText.title(from: spans),
                heads: snapshot.heads.isEmpty ? nil : snapshot.heads
            )
            return nil
        case .createFolder(let name, let parentUrl):
            guard let core = model.core else { return "Lush is still starting." }
            do {
                _ = try await Task.detached { [core, name, parentUrl] () -> String in
                    if let parentUrl, !parentUrl.isEmpty {
                        return try core.createSubfolderIn(folderUrl: parentUrl, title: name)
                    }
                    return try core.createSubfolder(title: name)
                }.value
                model.refreshNotes()
                return nil
            } catch {
                return error.localizedDescription
            }
        case .moveNote(let url, _, let folderUrl, _):
            guard model.node(for: url) != nil else { return "That note is no longer here." }
            guard model.node(for: folderUrl)?.kind == "folder" else { return "That destination is not a folder." }
            model.moveItem(url, into: folderUrl)
            return nil
        case .deleteNote(let url, _):
            model.deleteNote(url)
            return nil
        case .revertNote(let url, _, let heads, _):
            guard !heads.isEmpty else { return "That version is missing its heads." }
            await model.revertNote(url, to: heads)
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
    /// The note's heads when this turn read it — carried into any edit so the
    /// write merges instead of overwriting.
    let heads: [String]
    var spans: [SpanNode]
    var attachments: [NoteAttachment]
    private(set) var calls: [NoteChatToolCall] = []
    private(set) var proposals: [NoteChatProposal] = []
    /// Whether this turn was a request for a change at all, and whether it was
    /// a request for one of the two that cannot be undone. The catalog leaves
    /// out what these rule out, and `execute` refuses it if the model invents
    /// the name anyway.
    var allowsWrites = true
    var allowsDestructive = false

    init(
        model: NotesModel,
        url: String,
        title: String,
        snapshot: NoteSpansSnapshot,
        attachments: [NoteAttachment]
    ) {
        self.model = model
        self.url = url
        self.title = title
        self.heads = snapshot.heads
        self.spans = SpanNode.decodeList(snapshot.spansJson)
        self.attachments = attachments
    }

    var outline: String { NoteChatEdits.outlineText(spans) }

    /// A model shown a page of tool syntax imitates it, so it is only ever
    /// shown the tools this turn can actually use: the writing half is left out
    /// of a question, and the two irreversible ones out of everything but an
    /// explicit ask. `brief` is the same catalog spelled as tersely as it can
    /// be read, for models whose context window cannot afford the long one.
    static func catalog(brief: Bool, writes: Bool, destructive: Bool) -> String {
        var parts = [brief ? briefReads : fullReads]
        if writes {
            parts.append(brief ? briefWrites : fullWrites)
            if destructive {
                parts.append(brief ? briefDestructive : fullDestructive)
            }
            parts.append(brief ? briefOps : fullOps)
            parts.append(writeTail)
        } else {
            parts.append(readTail)
        }
        return parts.joined(separator: "\n\n")
    }

    private static let briefReads = """
    Tools, arguments as JSON. url defaults to the open note everywhere.
    find_notes{query?,folder_url?,limit?} — query searches, folder_url lists, neither is recents
    read{url?,attachment?,heads?,history?} — a note's outline, an attachment, an old version, or the version list
    read_agenda{days?} — events and reminders
    """

    private static let briefWrites = """
    edit_note{ops,url?} append_to_note{markdown,url?} create_note{title,markdown?,folder_url?}
    create_folder{name,parent_url?}
    rename_note{url?,title} move_note{url?,folder_url} link_note_to_event{event_ids,url?}
    """

    private static let briefDestructive = """
    delete_note{url?} revert_note{heads,url?}
    """

    private static let briefOps = """
    edit_note ops, addressing blocks by their outline number:
    {"op":"replace","block":3,"markdown":"…"}, same shape for insert_after and insert_before
    {"op":"delete","block":3} {"op":"move_block","block":3,"after":1}
    {"op":"set_type","block":3,"style":"heading2"} {"op":"set_indent","block":3,"level":1}
    {"op":"set_code_language","block":3,"language":"swift"}
    {"op":"mark","block":3,"text":"exact words","mark":"strong","value":null}
    {"op":"insert_table","after":3,"header":true,"rows":[["Name","Qty"]]}
    {"op":"insert_columns","after":3,"columns":["left","right"]}
    {"op":"insert_embed","after":3,"url":"automerge:…"}
    styles: \(NoteChatEdits.styles.joined(separator: " "))
    marks: \(NoteChatEdits.marks.joined(separator: " ")); value is the link url, \
    a highlight colour (\(Highlight.names.joined(separator: " "))), or a font role \
    (\(RichText.fontRoles.map(\.key).joined(separator: " ")))
    markdown: **bold** *italic* `code` ~~strike~~ [text](url) <u> <mark class="yellow"> \
    <sup> <sub> and # - 1. - [ ] > at the start of a line
    """

    private static let fullReads = """
    Every url argument defaults to the note being discussed.

    find_notes {"query": string?, "folder_url": string?, "limit": int?} — with a
      query, searches every note by text and meaning; with a folder url, lists what
      is in it; with neither, the notes worked on most recently
    read {"url": string?, "attachment": int?, "heads": [string]?, "history": bool?} —
      a note as a numbered block outline. attachment reads an attachment of this note
      instead, heads reads the note as it was at that version, history lists the
      versions and the heads that address them
    read_agenda {"days": int?} — calendar events and reminders, default 7 days
    """

    private static let fullWrites = """
    edit_note {"ops": [op, ...], "url": string?} — propose changes to a note; ops
      address the blocks of whichever note the url names, so read it first
    append_to_note {"markdown": string, "url": string?} — add to the end of a note
    create_note {"title": string, "markdown": string?, "folder_url": string?}
    create_folder {"name": string, "parent_url": string?}
    rename_note {"title": string, "url": string?}
    move_note {"folder_url": string, "url": string?}
    link_note_to_event {"event_ids": [string], "url": string?}
    """

    private static let fullDestructive = """
    delete_note {"url": string?}
    revert_note {"heads": [string], "url": string?}
    """

    private static let fullOps = """
    Ops for edit_note, each addressing a block by its number in the outline:
    {"op": "replace", "block": 3, "markdown": "new text"}
    {"op": "insert_after", "block": 3, "markdown": "a line\\nanother line"}
    {"op": "insert_before", "block": 3, "markdown": "..."}
    {"op": "delete", "block": 3}
    {"op": "set_type", "block": 3, "style": "heading2"}
    {"op": "mark", "block": 3, "text": "exact words", "mark": "strong"}
    {"op": "insert_table", "after": 3, "header": true, "rows": [["Name", "Qty"], ["Milk", "2"]]}
    {"op": "insert_columns", "after": 3, "columns": ["left side", "right side"]}
    {"op": "insert_embed", "after": 3, "url": "automerge:…"}
    {"op": "move_block", "block": 7, "after": 2}
    {"op": "set_code_language", "block": 3, "language": "swift"}
    {"op": "set_indent", "block": 3, "level": 1}

    Styles: \(NoteChatEdits.styles.joined(separator: ", ")).
    Marks: \(NoteChatEdits.marks.joined(separator: ", ")); value carries the link \
    url, the highlight colour (\(Highlight.names.joined(separator: ", "))), or the \
    font role (\(RichText.fontRoles.map(\.key).joined(separator: ", "))).
    Markdown in any op: **bold**, *italic*, `code`, ~~strike~~, [text](url), \
    <u>underline</u>, <mark class="yellow">highlight</mark>, <sup>x</sup>, <sub>x</sub>, \
    # heading, - bullet, 1. number, - [ ] to-do, > quote.
    """

    private static let writeTail = """
    Every tool that changes something queues a proposal for the person to \
    accept or reject; nothing is written when you call one. Do not call one \
    twice for the same change.
    """

    private static let readTail = """
    None of these change anything, and there is no tool here that can. The \
    person asked a question — find what you need and answer it.
    """

    static let writeTools: Set<String> = [
        "edit_note", "append_to_note", "create_note", "create_folder",
        "rename_note", "move_note", "link_note_to_event", "delete_note", "revert_note",
    ]

    static let destructiveTools: Set<String> = ["delete_note", "revert_note"]

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
        if Self.writeTools.contains(name) {
            guard allowsWrites else {
                return "The person asked a question, not for a change. There is no \(name) here — answer them."
            }
            guard allowsDestructive || !Self.destructiveTools.contains(name) else {
                return "\(name) cannot be undone and the person has not asked for it. Do not propose it."
            }
        }
        switch name {
        case "find_notes", "search_notes", "recent_notes", "list_folder":
            if let query = Self.string(arguments["query"]) {
                let hits = await model.search(query)
                guard !hits.isEmpty else { return "No notes matched \(query)." }
                return hits.prefix(12).map {
                    "\($0.name.isEmpty ? "Untitled" : $0.name) — \($0.url)\n  \(NoteChatEdits.short($0.snippet, limit: 160))"
                }.joined(separator: "\n")
            }
            if let folder = Self.string(arguments["folder_url"]) ?? Self.string(arguments["url"]) {
                guard let node = model.node(for: folder) else { return "Nothing is at that url." }
                let children = node.children ?? []
                guard !children.isEmpty else { return "Empty." }
                return children.map { "\($0.kind): \($0.displayName) — \($0.url)" }.joined(separator: "\n")
            }
            if name == "list_folder" {
                let roots = model.folderTree
                guard !roots.isEmpty else { return "No folders." }
                return roots.map { "\($0.kind): \($0.displayName) — \($0.url)" }.joined(separator: "\n")
            }
            await model.refreshRecents()
            let recents = model.recents.prefix(max(Self.count(arguments["limit"]) ?? 20, 1))
            guard !recents.isEmpty else { return "Nothing recent." }
            return recents.map {
                "\($0.node.displayName) — \($0.node.url) — \($0.modified.formatted(date: .abbreviated, time: .shortened))"
            }.joined(separator: "\n")

        case "read", "read_note", "read_attachment", "read_version", "note_history":
            let target = Self.string(arguments["url"]) ?? url
            if let number = Self.count(arguments["attachment"]) ?? Self.count(arguments["number"]) {
                guard let attachment = attachments.first(where: { $0.number == number }) else {
                    return "This note has no attachment \(number)."
                }
                if attachment.isPatchworkDoc, let attachmentUrl = attachment.url,
                   let json = try? await PatchworkScripting.shared.documentJSON(attachmentUrl) {
                    return String(json.prefix(8_000))
                }
                let parts = [attachment.description, attachment.text, attachment.summary]
                    .filter { !$0.isEmpty }
                return parts.isEmpty
                    ? "Nothing has been extracted from that attachment."
                    : parts.joined(separator: "\n")
            }
            if arguments["history"] as? Bool == true || name == "note_history" {
                let history = await model.documentHistorySummary(url: target)
                guard !history.entries.isEmpty else { return "No recorded history." }
                return history.entries.suffix(20).reversed().map { entry in
                    let when = Date(timeIntervalSince1970: TimeInterval(entry.time))
                    return "\(when.formatted(date: .abbreviated, time: .shortened)) — +\(entry.additions)/-\(entry.deletions) — heads [\(entry.heads.joined(separator: ","))]"
                }.joined(separator: "\n")
            }
            let spans: [SpanNode] = if let heads = arguments["heads"] as? [String], !heads.isEmpty {
                SpanNode.decodeList(await model.spansSnapshot(for: target, heads: heads).spansJson)
            } else if target == url {
                self.spans
            } else {
                SpanNode.decodeList(await model.spansJSON(for: target))
            }
            guard !spans.isEmpty else { return "That note is empty or could not be read." }
            return "\(displayName(of: target))\n\(NoteChatEdits.outlineText(spans))"

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
            let ops = NoteChatOp.list(from: arguments["ops"] ?? (arguments["op"] is String ? arguments : nil))
            guard !ops.isEmpty else { return "edit_note needs at least one op." }
            let target = Self.string(arguments["url"]) ?? url
            // another note's blocks are numbered from its own outline, which
            // the model has to have read; its heads come with that read
            let editing = target == url
            let snapshot = editing ? nil : await model.spansSnapshot(for: target)
            let before = editing ? spans : SpanNode.decodeList(snapshot?.spansJson ?? "[]")
            guard !before.isEmpty else { return "That note is empty or could not be read." }
            let applied = NoteChatEdits.apply(ops, to: before)
            guard applied.failures.count < ops.count else {
                return "Nothing was changed: \(applied.failures.joined(separator: "; "))."
            }
            if editing { spans = applied.spans }
            propose(.editNote(
                url: target,
                ops: ops,
                spans: SpanNode.encodeList(applied.spans),
                heads: editing ? heads : (snapshot?.heads ?? [])
            ))
            let trouble = applied.failures.isEmpty ? "" : " Skipped: \(applied.failures.joined(separator: "; "))."
            return """
            Queued for the person to accept.\(trouble) It now reads:
            \(NoteChatEdits.outlineText(applied.spans))
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
            guard let markdown = Self.string(arguments["markdown"]) else {
                return "append_to_note needs markdown."
            }
            let target = Self.string(arguments["url"]) ?? url
            propose(.appendToNote(url: target, name: displayName(of: target), markdown: markdown))
            return "Queued for the person to accept."

        case "rename_note":
            guard let title = Self.string(arguments["title"]) else { return "rename_note needs a title." }
            let target = Self.string(arguments["url"]) ?? url
            propose(.renameNote(url: target, name: displayName(of: target), title: title))
            return "Queued for the person to accept."

        case "move_note":
            guard let folder = Self.string(arguments["folder_url"]) else {
                return "move_note needs a folder_url."
            }
            let target = Self.string(arguments["url"]) ?? url
            guard let destination = model.node(for: folder), destination.kind == "folder" else {
                return "There is no folder at \(folder)."
            }
            propose(.moveNote(
                url: target,
                name: displayName(of: target),
                folderUrl: folder,
                folderName: destination.displayName
            ))
            return "Queued for the person to accept."

        case "delete_note":
            let target = Self.string(arguments["url"]) ?? url
            propose(.deleteNote(url: target, name: displayName(of: target)))
            return "Queued for the person to accept."

        case "revert_note":
            guard let heads = arguments["heads"] as? [String], !heads.isEmpty else {
                return "revert_note needs heads from note_history."
            }
            let target = Self.string(arguments["url"]) ?? url
            let history = await model.documentHistorySummary(url: target)
            let entry = history.entries.first { $0.heads == heads }
            let when = entry.map {
                Date(timeIntervalSince1970: TimeInterval($0.time))
                    .formatted(date: .abbreviated, time: .shortened)
            } ?? "an earlier version"
            propose(.revertNote(url: target, name: displayName(of: target), heads: heads, when: when))
            return "Queued for the person to accept."

        case "create_folder":
            guard let name = Self.string(arguments["name"]) else { return "create_folder needs a name." }
            propose(.createFolder(name: name, parentUrl: Self.string(arguments["parent_url"])))
            return "Queued for the person to accept. It does not exist yet."

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

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func count(_ value: Any?) -> Int? {
        (value as? Int) ?? (value as? NSNumber)?.intValue
    }

    private func propose(_ action: NoteChatAction) {
        proposals.append(NoteChatProposal(action: action))
    }

    private func displayName(of url: String) -> String {
        url == self.url ? title : (model.node(for: url)?.displayName ?? "Untitled")
    }
}
