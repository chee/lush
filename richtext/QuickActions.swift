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
        case note(String)
        case search(String)
    }

    var pending: Action?

    func handle(_ url: URL) {
        guard url.scheme == "lush" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        switch url.host() {
        case "new":
            pending = .newNote
        case "show":
            if let doc = components?.queryItems?.first(where: { $0.name == "doc" })?.value {
                if doc == "quick" {
                    pending = .quickNote
                } else if doc.hasPrefix("automerge:") {
                    pending = .note(doc)
                }
            }
        case "search":
            if let q = components?.queryItems?.first(where: { $0.name == "q" })?.value {
                pending = .search(q)
            }
        default:
            break
        }
    }
}

struct NewNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "New Note"
    static let description = IntentDescription("Create a new note and start writing.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.pending = .newNote
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

struct RichtextShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewNoteIntent(),
            phrases: ["New note in \(.applicationName)"],
            shortTitle: "New Note",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: OpenQuickNoteIntent(),
            phrases: ["Open my quick note in \(.applicationName)"],
            shortTitle: "Quick Note",
            systemImageName: "bolt.circle"
        )
    }
}
