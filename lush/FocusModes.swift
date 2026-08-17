import Foundation
import AppIntents
import Intents
import EventKit

/// What a system Focus is currently doing to Lush. The user configures it per
/// Focus under Settings › Focus › Focus Filters › Lush; the system performs the
/// filter when that Focus turns on.
struct FocusFilterState: Codable, Equatable {
    var shownFolderUrls: [String] = []
    var inboxUrl: String?
    var quickNoteUrl: String?
    var shownCalendarIds: [String] = []

    var isEmpty: Bool {
        shownFolderUrls.isEmpty && inboxUrl == nil && quickNoteUrl == nil && shownCalendarIds.isEmpty
    }
}

@MainActor @Observable
final class FocusModes {
    private static let stateKey = "lushFocusFilterState"

    /// nil when no Focus with a Lush filter is on.
    private(set) var state: FocusFilterState?
    @ObservationIgnored private var lastIsFocused: Bool?
    @ObservationIgnored private var watcher: Task<Void, Never>?

    init() {
        state = UserDefaults.standard.data(forKey: Self.stateKey)
            .flatMap { try? JSONDecoder().decode(FocusFilterState.self, from: $0) }
    }

    var isActive: Bool { state != nil }

    func apply(_ state: FocusFilterState?) {
        self.state = state
        if let state, let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.stateKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.stateKey)
        }
    }

    func hides(_ folderUrl: String) -> Bool {
        guard let shown = state?.shownFolderUrls, !shown.isEmpty else { return false }
        return !shown.contains(folderUrl)
    }

    /// Drops a deleted note or folder out of the applied filter.
    func forgetDocument(_ url: String) {
        guard var state else { return }
        state.shownFolderUrls.removeAll { $0 == url }
        if state.inboxUrl == url { state.inboxUrl = nil }
        if state.quickNoteUrl == url { state.quickNoteUrl = nil }
        apply(state.isEmpty ? nil : state)
    }

    // System Focus ----------------------------------------------------------

    var focusStatusAuthorization: INFocusStatusAuthorizationStatus {
        INFocusStatusCenter.default.authorizationStatus
    }

    func requestFocusStatusAuthorization() async {
        _ = await withCheckedContinuation { continuation in
            INFocusStatusCenter.default.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        await reconcileWithSystemFocus()
    }

    /// The system runs the filter when a Focus turns on, but delivers nothing
    /// when one turns off, so the applied filter is re-read on launch, on
    /// activation, and whenever the focus-status flag flips.
    func reconcileWithSystemFocus() async {
        lastIsFocused = INFocusStatusCenter.default.focusStatus.isFocused
        apply(try? await LushFocusFilter.current.state)
    }

    /// Picks up a Focus starting or ending while Lush sits in the background.
    /// Needs the focus-status entitlement authorized; without it `isFocused` is
    /// nil and this settles into a no-op, leaving the reconcile on activation
    /// to do the work.
    ///
    /// A backgrounded iOS app is suspended, so there the poll can't do what it
    /// is for and only burns battery in the foreground; it parks and lets the
    /// reconcile on activation cover the gap. On macOS the gate is always open.
    func watchSystemFocus() {
        guard watcher == nil else { return }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                await AppActivity.waitUntilActive()
                guard !Task.isCancelled else { break }
                try? await Task.sleep(for: .seconds(20))
                guard let self else { return }
                let isFocused = INFocusStatusCenter.default.focusStatus.isFocused
                guard isFocused != lastIsFocused else { continue }
                await reconcileWithSystemFocus()
            }
        }
    }
}

struct LushNoteEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Lush Note")
    static let defaultQuery = LushNoteQuery()

    let id: String

    @Property(title: "Name")
    var name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct LushNoteQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [LushNoteEntity] {
        await NotesModel.shared.start()
        let all = Self.all()
        return identifiers.compactMap { identifier in
            all.first { $0.id == identifier }
                ?? (identifier.hasPrefix("automerge:")
                    ? LushNoteEntity(id: identifier, name: "Note")
                    : nil)
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [LushNoteEntity] {
        await NotesModel.shared.start()
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Self.all() }
        return Self.all().filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    @MainActor
    func suggestedEntities() async throws -> [LushNoteEntity] {
        await NotesModel.shared.start()
        return Self.all()
    }

    @MainActor
    private static func all() -> [LushNoteEntity] {
        NotesModel.shared.noteChoices().map { LushNoteEntity(id: $0.url, name: $0.path) }
    }
}

struct LushCalendarEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Calendar")
    static let defaultQuery = LushCalendarQuery()

    let id: String

    @Property(title: "Name")
    var name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct LushCalendarQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [LushCalendarEntity] {
        let all = Self.all()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func entities(matching string: String) async throws -> [LushCalendarEntity] {
        let all = Self.all()
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    func suggestedEntities() async throws -> [LushCalendarEntity] { Self.all() }

    private static func all() -> [LushCalendarEntity] {
        let store = EKEventStore()
        var seen = Set<String>()
        return (store.calendars(for: .event) + store.calendars(for: .reminder)).compactMap { cal in
            guard seen.insert(cal.calendarIdentifier).inserted else { return nil }
            return LushCalendarEntity(id: cal.calendarIdentifier, name: cal.title)
        }
    }
}

/// Configured per system Focus in Settings › Focus › Focus Filters › Lush.
/// There are no Lush-side focus modes: the Focus is the mode, and this is what
/// it carries.
struct LushFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Lush Focus Filter"
    static let description = IntentDescription("Choose the folders, inbox, and Quick Note Lush uses during this Focus.")

    @Parameter(title: "Folders")
    var folders: [LushFolderEntity]?

    @Parameter(title: "Inbox")
    var inbox: LushFolderEntity?

    @Parameter(title: "Quick Note")
    var quickNote: LushNoteEntity?

    @Parameter(title: "Calendars")
    var calendars: [LushCalendarEntity]?

    var displayRepresentation: DisplayRepresentation {
        var parts: [String] = []
        if let folders, !folders.isEmpty { parts.append("\(folders.count) folders") }
        if let inbox { parts.append("inbox: \(inbox.name)") }
        if let quickNote { parts.append("quick note: \(quickNote.name)") }
        if let calendars, !calendars.isEmpty { parts.append("\(calendars.count) calendars") }
        return DisplayRepresentation(
            title: "Lush",
            subtitle: parts.isEmpty ? "Everything" : "\(parts.joined(separator: ", "))"
        )
    }

    var state: FocusFilterState {
        FocusFilterState(
            shownFolderUrls: (folders ?? []).compactMap { $0.isInbox ? nil : $0.url },
            inboxUrl: inbox.flatMap { $0.isInbox ? nil : $0.url },
            quickNoteUrl: quickNote?.id,
            shownCalendarIds: (calendars ?? []).map(\.id)
        )
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        NotesModel.shared.focus.apply(state)
        return .result()
    }
}
