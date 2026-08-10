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

    static func content(of url: String, title: String, format: LushContentFormat) async throws -> IntentFile {
        let json = await NotesModel.shared.spansJSON(for: url)
        let spans = SpanNode.decodeList(json)
        let filename = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let basename = filename.isEmpty ? "Untitled" : filename
        switch format {
        case .spansJSON:
            return IntentFile(data: Data(json.utf8), filename: "\(basename).json", type: .json)
        case .html:
            return IntentFile(
                data: Data(NoteExporter.htmlFragment(from: spans).utf8),
                filename: "\(basename).html",
                type: .html
            )
        case .rtf:
            return IntentFile(
                data: try NoteExporter.rtfData(from: spans),
                filename: "\(basename).rtf",
                type: .rtf
            )
        case .text:
            return IntentFile(
                data: Data(plainText(spans).utf8),
                filename: "\(basename).txt",
                type: .plainText
            )
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
    case rtf
    case spansJSON

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Note Format")
    static let caseDisplayRepresentations: [LushContentFormat: DisplayRepresentation] = [
        .text: "Plain Text",
        .html: "HTML",
        .rtf: "Rich Text",
        .spansJSON: "Spans JSON"
    ]
}

struct GetNoteContentIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Note Content"
    static let description = IntentDescription("Export the contents of a Lush note.")
    static let openAppWhenRun = false

    @Parameter(title: "Note", inputConnectionBehavior: .connectToPreviousIntentResult)
    var note: LushDocumentEntity

    @Parameter(title: "Format", default: .text)
    var format: LushContentFormat

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$format) of \(\.$note)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        await NotesModel.shared.start()
        return .result(value: try await LushDocuments.content(of: note.id, title: note.title, format: format))
    }
}

struct GetQuickNoteTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Quick Note Content"
    static let description = IntentDescription("Export the contents of your Quick Note.")
    static let openAppWhenRun = false

    @Parameter(title: "Format", default: .text)
    var format: LushContentFormat

    static var parameterSummary: some ParameterSummary {
        Summary("Get Quick Note as \(\.$format)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        await NotesModel.shared.start()
        guard let url = await NotesModel.shared.ensureQuickNote() else {
            throw LushIntentError.operationFailed("Quick Note could not be opened.")
        }
        return .result(value: try await LushDocuments.content(of: url, title: "Quick Note", format: format))
    }
}

struct SearchNotesIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Notes"
    static let description = IntentDescription("Find Lush notes matching a query, by text and by meaning.")
    static let openAppWhenRun = false

    @Parameter(title: "Query", inputConnectionBehavior: .connectToPreviousIntentResult)
    var query: String

    @Parameter(title: "Limit", default: 20, inclusiveRange: (1, 100))
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Search notes for \(\.$query)") {
            \.$limit
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[LushDocumentEntity]> {
        await NotesModel.shared.start()
        let hits = await LushDocuments.search(query)
        return .result(value: Array(hits.prefix(min(100, max(1, limit)))))
    }
}

struct GetRecentNotesIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Recent Notes"
    static let description = IntentDescription("The most recently changed Lush notes.")
    static let openAppWhenRun = false

    @Parameter(title: "Limit", default: 20, inclusiveRange: (1, 100))
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$limit) recent notes")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[LushDocumentEntity]> {
        await NotesModel.shared.start()
        return .result(value: LushDocuments.recents(limit: UInt32(min(100, max(1, limit)))))
    }
}

struct GetFolderContentsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Folder Contents"
    static let description = IntentDescription("List the documents in a Lush folder.")
    static let openAppWhenRun = false

    @Parameter(title: "Folder")
    var folder: LushFolderEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get contents of \(\.$folder)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[LushDocumentEntity]> {
        await NotesModel.shared.start()
        guard let core = NotesModel.shared.core,
              let url = folder.isInbox
                ? (NotesModel.shared.effectiveInboxUrl ?? NotesModel.shared.folderUrl)
                : (folder.url ?? folder.id)
        else { throw LushIntentError.operationFailed("The folder could not be opened.") }
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

    @Parameter(
        title: "Automerge URL",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var url: String

    static var parameterSummary: some ParameterSummary {
        Summary("Get Automerge document \(\.$url)")
    }

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
        Run a script in the Patchwork runtime. repo, handle, doc, url, and \
        Patchwork are in scope. Documentation: lush://help/shortcuts
        """
    )
    static let openAppWhenRun = false

    @Parameter(
        title: "Script",
        inputOptions: String.IntentInputOptions(
            keyboardType: .asciiCapable,
            capitalizationType: .none,
            multiline: true,
            autocorrect: false,
            smartQuotes: false,
            smartDashes: false
        ),
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var script: String

    @Parameter(
        title: "Document URL",
        description: "Optional Automerge URL to expose as handle, doc, and url."
    )
    var url: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Run JavaScript in Patchwork") {
            \.$script
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
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAnAutomergeURL: "That is not an automerge: URL."
        case .operationFailed(let message): message
        }
    }
}
