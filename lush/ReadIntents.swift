import AppIntents
import Foundation
import UniformTypeIdentifiers

struct LushDocumentEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Lush Document")
    static let defaultQuery = LushDocumentQuery()

    let id: String

    @Property(title: "Title")
    var title: String

    @Property(title: "Automerge URL")
    var url: String

    @Property(title: "Kind")
    var kind: String

    @Property(title: "Snippet")
    var snippet: String

    init(id: String, title: String, kind: String, snippet: String = "") {
        self.id = id
        self.title = title.isEmpty ? "Untitled" : title
        self.url = id
        self.kind = kind
        self.snippet = snippet
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(snippet.isEmpty ? id : snippet)")
    }

    @MainActor
    init(node: FolderNode) {
        self.init(id: node.url, title: node.displayName, kind: node.kind)
    }
}

struct LushDocumentQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [LushDocumentEntity] {
        await NotesModel.shared.start()
        return identifiers.compactMap { LushDocuments.entity(for: $0) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [LushDocumentEntity] {
        await NotesModel.shared.start()
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.hasPrefix("automerge:") {
            return [LushDocuments.entity(for: query)].compactMap { $0 }
        }
        guard !query.isEmpty else { return try await suggestedEntities() }
        return await LushDocuments.search(query)
    }

    @MainActor
    func suggestedEntities() async throws -> [LushDocumentEntity] {
        await NotesModel.shared.start()
        return LushDocuments.recents(limit: 25)
    }
}

@MainActor
enum LushDocuments {
    static func entity(for url: String) -> LushDocumentEntity? {
        if let node = NotesModel.shared.node(for: url) {
            return LushDocumentEntity(node: node)
        }
        guard url.hasPrefix("automerge:") else { return nil }
        return LushDocumentEntity(id: url, title: "Document", kind: "")
    }

    static func search(_ query: String) async -> [LushDocumentEntity] {
        let model = NotesModel.shared
        let hits = await model.search(query)
        return hits.map { hit in
            LushDocumentEntity(
                id: hit.url,
                title: hit.name,
                kind: model.node(for: hit.url)?.kind ?? "",
                snippet: hit.snippet
            )
        }
    }

    static func recents(limit: UInt32) -> [LushDocumentEntity] {
        let model = NotesModel.shared
        guard let core = model.core else { return [] }
        return core.recentNotes(limit: limit).map { note in
            LushDocumentEntity(
                id: note.url,
                title: note.name,
                kind: model.node(for: note.url)?.kind ?? ""
            )
        }
    }

    static func content(of url: String, format: LushContentFormat) async -> String {
        let json = await NotesModel.shared.spansJSON(for: url)
        switch format {
        case .spansJSON:
            return json
        case .html:
            return NoteExporter.htmlFragment(from: SpanNode.decodeList(json))
        case .text:
            return plainText(SpanNode.decodeList(json))
        }
    }

    static func plainText(_ spans: [SpanNode]) -> String {
        var parts: [String] = []
        for span in spans {
            switch span {
            case .block:
                if parts.last != "\n" { parts.append("\n") }
            case .text(let text, _):
                parts.append(text)
            }
        }
        return parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum LushContentFormat: String, AppEnum {
    case text
    case html
    case spansJSON

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Note Format")
    static let caseDisplayRepresentations: [LushContentFormat: DisplayRepresentation] = [
        .text: "Plain Text",
        .html: "HTML",
        .spansJSON: "Spans JSON"
    ]
}

struct GetNoteContentIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Note Content"
    static let description = IntentDescription("Read the text of a Lush note.")
    static let openAppWhenRun = false

    @Parameter(title: "Note")
    var note: LushDocumentEntity

    @Parameter(title: "Format", default: .text)
    var format: LushContentFormat

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$format) of \(\.$note)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        await NotesModel.shared.start()
        return .result(value: await LushDocuments.content(of: note.id, format: format))
    }
}

struct GetQuickNoteTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Quick Note Text"
    static let description = IntentDescription("The text of your Quick Note, as a value.")
    static let openAppWhenRun = false

    @Parameter(title: "Format", default: .text)
    var format: LushContentFormat

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        await NotesModel.shared.start()
        guard let url = await NotesModel.shared.ensureQuickNote() else {
            return .result(value: "")
        }
        return .result(value: await LushDocuments.content(of: url, format: format))
    }
}

struct SearchNotesIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Notes"
    static let description = IntentDescription("Find Lush notes matching a query, by text and by meaning.")
    static let openAppWhenRun = false

    @Parameter(title: "Query")
    var query: String

    @Parameter(title: "Limit", default: 20)
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Search Lush for \(\.$query)") {
            \.$limit
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[LushDocumentEntity]> {
        await NotesModel.shared.start()
        let hits = await LushDocuments.search(query)
        return .result(value: Array(hits.prefix(max(1, limit))))
    }
}

struct GetRecentNotesIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Recent Notes"
    static let description = IntentDescription("The most recently changed Lush notes.")
    static let openAppWhenRun = false

    @Parameter(title: "Limit", default: 20)
    var limit: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[LushDocumentEntity]> {
        await NotesModel.shared.start()
        return .result(value: LushDocuments.recents(limit: UInt32(max(1, limit))))
    }
}

struct GetFolderContentsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Folder Contents"
    static let description = IntentDescription("List the documents in a Lush folder.")
    static let openAppWhenRun = false

    @Parameter(title: "Folder")
    var folder: LushFolderEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[LushDocumentEntity]> {
        await NotesModel.shared.start()
        guard let core = NotesModel.shared.core,
              let url = folder.isInbox
                ? (NotesModel.shared.effectiveInboxUrl ?? NotesModel.shared.folderUrl)
                : (folder.url ?? folder.id)
        else { return .result(value: []) }
        let entries = await core.folderEntriesOf(url: url)
        return .result(value: entries.map {
            LushDocumentEntity(id: $0.url, title: $0.name, kind: $0.kind)
        })
    }
}

struct GetDocumentIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Automerge Document"
    static let description = IntentDescription(
        "Read any Automerge document as JSON, ready for Get Dictionary from Input."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Automerge URL")
    var url: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        await NotesModel.shared.start()
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("automerge:") else {
            throw LushIntentError.notAnAutomergeURL
        }
        let json = try await PatchworkScripting.shared.documentJSON(trimmed)
        return .result(value: IntentFile(
            data: Data(json.utf8),
            filename: "document.json",
            type: .json
        ))
    }
}

struct RunPatchworkJavaScriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Run JavaScript in Patchwork"
    static let description = IntentDescription(
        """
        Run a script in the Patchwork runtime. `repo`, `handle`, `doc`, and \
        `docUrl` are in scope; return a value to hand it back as JSON.
        """
    )
    static let openAppWhenRun = false

    @Parameter(title: "Script")
    var script: String

    @Parameter(title: "Automerge URL")
    var url: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$script) in Patchwork") {
            \.$url
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        await NotesModel.shared.start()
        let docUrl = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = try await PatchworkScripting.shared.evaluate(
            script,
            docUrl: (docUrl?.hasPrefix("automerge:") ?? false) ? docUrl : nil
        )
        return .result(value: IntentFile(
            data: Data(json.utf8),
            filename: "result.json",
            type: .json
        ))
    }
}

enum LushIntentError: LocalizedError {
    case notAnAutomergeURL

    var errorDescription: String? { "That is not an automerge: URL." }
}
