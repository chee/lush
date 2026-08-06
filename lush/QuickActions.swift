import SwiftUI
import AppIntents

/// Pending navigation from a widget tap, url open, or app intent — the app
/// picks it up once the model is ready.
@MainActor @Observable
final class AppRouter {
    static let shared = AppRouter()

    enum Action: Equatable {
        case newNote
        case quickNote
        case capture
        case insertQuickNote(String)
        case note(String)
        case folder(String)
        case search(String)
        case createPatchwork(preferredType: String?, toolId: String?, folderUrl: String?)
        case share(String)
    }

    var pending: Action?

    func handle(_ url: URL) {
        guard url.scheme == "lush" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        switch url.host() {
        case "new":
            pending = .newNote
        case "capture":
            pending = .capture
        case "insert":
            if let text = components?.queryItems?.first(where: { $0.name == "text" })?.value {
                pending = .insertQuickNote(text)
            }
        case "show":
            if let doc = components?.queryItems?.first(where: { $0.name == "doc" })?.value {
                if doc == "quick" {
                    pending = .quickNote
                } else if doc.hasPrefix("automerge:") {
                    pending = .note(doc)
                }
            }
        case "folder":
            if let folder = components?.queryItems?.first(where: { $0.name == "url" })?.value,
               folder.hasPrefix("automerge:") {
                pending = .folder(folder)
            }
        case "search":
            if let q = components?.queryItems?.first(where: { $0.name == "q" })?.value {
                pending = .search(q)
            }
        case "patchwork":
            let type = components?.queryItems?.first(where: { $0.name == "type" })?.value
            let toolId = components?.queryItems?.first(where: { $0.name == "tool-id" })?.value
                ?? components?.queryItems?.first(where: { $0.name == "toolid" })?.value
            let folder = components?.queryItems?.first(where: { $0.name == "folder" })?.value
            pending = .createPatchwork(preferredType: type, toolId: toolId, folderUrl: folder)
        case "share":
            if let id = components?.queryItems?.first(where: { $0.name == "id" })?.value {
                pending = .share(id)
            }
        default:
            break
        }
    }
}

struct LushFolderEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Lush Folder")
    static let defaultQuery = LushFolderQuery()

    let id: String
    let name: String
    let url: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: url.map { "\($0)" }
        )
    }

    var isInbox: Bool { id == LushFolderQuery.inboxIdentifier }
}

struct LushFolderQuery: EntityStringQuery {
    static let inboxIdentifier = "__lush_inbox__"

    @MainActor
    func entities(for identifiers: [String]) async throws -> [LushFolderEntity] {
        await NotesModel.shared.start()
        let all = Self.entitiesFromModel()
        return identifiers.compactMap { identifier in
            if let entity = all.first(where: { $0.id == identifier || $0.url == identifier }) {
                return entity
            }
            if identifier.hasPrefix("automerge:") {
                return LushFolderEntity(id: identifier, name: "Folder URL", url: identifier)
            }
            return nil
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [LushFolderEntity] {
        await NotesModel.shared.start()
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.hasPrefix("automerge:") {
            return [LushFolderEntity(id: query, name: "Folder URL", url: query)]
        }
        guard !query.isEmpty else { return Self.entitiesFromModel() }
        return Self.entitiesFromModel().filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.url?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [LushFolderEntity] {
        await NotesModel.shared.start()
        return Self.entitiesFromModel()
    }

    @MainActor
    private static func entitiesFromModel() -> [LushFolderEntity] {
        let model = NotesModel.shared
        var entities: [LushFolderEntity] = [
            LushFolderEntity(id: inboxIdentifier, name: "Inbox", url: model.inboxUrl ?? model.folderUrl)
        ]
        let choices = model.folderChoices()
        if choices.isEmpty {
            entities += model.rootFolderUrls.map { url in
                LushFolderEntity(
                    id: url,
                    name: model.node(for: url)?.displayName ?? "Folder",
                    url: url
                )
            }
        } else {
            entities += choices.map { choice in
                LushFolderEntity(id: choice.url, name: choice.path, url: choice.url)
            }
        }
        var seen = Set<String>()
        return entities.filter { entity in
            let key = entity.id
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }
}

@MainActor
private func resolvedFolderUrl(_ entity: LushFolderEntity?) -> String? {
    guard let entity else { return nil }
    if entity.isInbox {
        return NotesModel.shared.inboxUrl ?? NotesModel.shared.folderUrl
    }
    return entity.url ?? entity.id
}

struct NewNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Note"
    static let description = IntentDescription("Create a new Lush note in Inbox or a selected folder.")
    static let openAppWhenRun = true

    @Parameter(title: "Folder")
    var folder: LushFolderEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        let url = await NotesModel.shared.createNoteForShortcut(inFolder: resolvedFolderUrl(folder))
        if url == nil {
            AppRouter.shared.pending = .newNote
        }
        return .result()
    }
}

struct AddFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Add File"
    static let description = IntentDescription("Create a new Lush file document in Inbox or a selected folder.")
    static let openAppWhenRun = true

    @Parameter(title: "Folder")
    var folder: LushFolderEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = await NotesModel.shared.createFileForShortcut(inFolder: resolvedFolderUrl(folder))
        return .result()
    }
}

struct AddDictionaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Dictionary"
    static let description = IntentDescription("Open Lush to create a Patchwork dictionary in Inbox or a selected folder.")
    static let openAppWhenRun = true

    @Parameter(title: "Folder")
    var folder: LushFolderEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.pending = .createPatchwork(
            preferredType: "dictionary",
            toolId: nil,
            folderUrl: resolvedFolderUrl(folder)
        )
        return .result()
    }
}

struct AddAutomergeURLIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Automerge URL"
    static let description = IntentDescription("Add an existing Automerge document URL to Inbox or a selected folder.")
    static let openAppWhenRun = true

    @Parameter(title: "Automerge URL")
    var url: String

    @Parameter(title: "Folder")
    var folder: LushFolderEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("automerge:") else { return .result() }
        await NotesModel.shared.addDocToFolder(url: trimmed, folderUrl: resolvedFolderUrl(folder))
        return .result()
    }
}

struct LogInAccountIntent: AppIntent {
    static let title: LocalizedStringResource = "Log In to Lush Account"
    static let description = IntentDescription("Log in with an account: or automerge: account URL.")
    static let openAppWhenRun = true

    @Parameter(title: "Account URL")
    var accountURL: String

    @MainActor
    func perform() async throws -> some IntentResult {
        await NotesModel.shared.start()
        _ = await NotesModel.shared.logIn(accountUrl: accountURL)
        return .result()
    }
}

struct OpenQuickNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Quick Note"
    static let description = IntentDescription("Open your Quick Note.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.pending = .quickNote
        return .result()
    }
}

@available(iOS 18.0, macOS 15.0, *)
enum LushControlDestination: String, AppEnum {
    case quickNote
    case newNote

    static let typeDisplayRepresentation = TypeDisplayRepresentation("Lush destination")
    static let caseDisplayRepresentations: [LushControlDestination: DisplayRepresentation] = [
        .quickNote: "Quick Note",
        .newNote: "New Note"
    ]
}

@available(iOS 18.0, macOS 15.0, *)
struct OpenLushControlIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Lush"
    static let description = IntentDescription("Open Lush to a note action.")

    @Parameter(title: "Destination")
    var target: LushControlDestination

    init() {
        target = .quickNote
    }

    init(target: LushControlDestination) {
        self.target = target
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        switch target {
        case .quickNote:
            AppRouter.shared.pending = .quickNote
        case .newNote:
            AppRouter.shared.pending = .newNote
        }
        return .result()
    }
}

struct LushShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewNoteIntent(),
            phrases: [
                "Add note in \(.applicationName)",
                "New note in \(.applicationName)"
            ],
            shortTitle: "Add Note",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: AddFileIntent(),
            phrases: ["Add file in \(.applicationName)"],
            shortTitle: "Add File",
            systemImageName: "doc.badge.plus"
        )
        AppShortcut(
            intent: AddDictionaryIntent(),
            phrases: ["Add dictionary in \(.applicationName)"],
            shortTitle: "Add Dictionary",
            systemImageName: "text.book.closed"
        )
        AppShortcut(
            intent: AddAutomergeURLIntent(),
            phrases: ["Add Automerge URL in \(.applicationName)"],
            shortTitle: "Add URL",
            systemImageName: "link.badge.plus"
        )
        AppShortcut(
            intent: LogInAccountIntent(),
            phrases: ["Log in to \(.applicationName)"],
            shortTitle: "Log In",
            systemImageName: "person.crop.circle.badge.checkmark"
        )
        AppShortcut(
            intent: OpenQuickNoteIntent(),
            phrases: ["Open my quick note in \(.applicationName)"],
            shortTitle: "Quick Note",
            systemImageName: "bolt.circle"
        )
    }
}
