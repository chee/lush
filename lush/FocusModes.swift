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

/// A named set of Lush settings, edited in the app and linked to a system Focus
/// from Settings › Focus › Focus Filters › Lush. The system owns which Focus is
/// on; Lush owns what the filter contains.
struct FocusPreset: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var name: String = "Untitled"
    var filter = FocusFilterState()
}

@MainActor @Observable
final class FocusModes {
    private static let stateKey = "lushFocusFilterState"
    nonisolated static let presetsKey = "lushFocusPresets"

    /// nil when no Focus with a Lush filter is on.
    private(set) var state: FocusFilterState?
    private(set) var presets: [FocusPreset] = []
    /// Set by the model so edits reach the synced config doc.
    @ObservationIgnored var publishPresets: (([FocusPreset]) -> Void)?
    @ObservationIgnored private var lastIsFocused: Bool?
    @ObservationIgnored private var watcher: Task<Void, Never>?

    init() {
        state = UserDefaults.standard.data(forKey: Self.stateKey)
            .flatMap { try? JSONDecoder().decode(FocusFilterState.self, from: $0) }
        presets = Self.loadPresets()
    }

    // Presets ---------------------------------------------------------------

    /// Read from disk rather than memory: the Focus filter's entity query and
    /// the filter's own `state` run outside the app's main actor.
    nonisolated static func loadPresets() -> [FocusPreset] {
        UserDefaults.standard.data(forKey: presetsKey)
            .flatMap { try? JSONDecoder().decode([FocusPreset].self, from: $0) } ?? []
    }

    nonisolated static func preset(id: String) -> FocusPreset? {
        loadPresets().first { $0.id == id }
    }

    func save(_ preset: FocusPreset) {
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        persistPresets()
        publishPresets?(presets)
    }

    func deletePresets(_ ids: Set<String>) {
        presets.removeAll { ids.contains($0.id) }
        persistPresets()
        publishPresets?(presets)
    }

    /// Takes what the synced config carries, without echoing it back.
    func adoptPresets(_ presets: [FocusPreset]) {
        guard presets != self.presets else { return }
        self.presets = presets
        persistPresets()
    }

    private func persistPresets() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Self.presetsKey)
        }
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

struct LushFocusPresetEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Lush Focus Set")
    static let defaultQuery = LushFocusPresetQuery()

    let id: String

    @Property(title: "Name")
    var name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(_ preset: FocusPreset) {
        self.init(id: preset.id, name: preset.name)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct LushFocusPresetQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [LushFocusPresetEntity] {
        let all = FocusModes.loadPresets()
        return identifiers.compactMap { id in
            all.first { $0.id == id }.map(LushFocusPresetEntity.init)
        }
    }

    func entities(matching string: String) async throws -> [LushFocusPresetEntity] {
        let all = FocusModes.loadPresets().map(LushFocusPresetEntity.init)
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    func suggestedEntities() async throws -> [LushFocusPresetEntity] {
        FocusModes.loadPresets().map(LushFocusPresetEntity.init)
    }
}

/// Linked per system Focus in Settings › Focus › Focus Filters › Lush. The
/// filter itself carries nothing but a name: what that name means is built in
/// the app, under Settings › System › Focus, so the notebooks and calendars are
/// picked in Lush's own UI rather than through the system's entity pickers.
struct LushFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Lush Focus Filter"
    static let description = IntentDescription("Pick a Focus Set built in Lush under Settings › System › Focus.")

    @Parameter(title: "Lush Focus Set")
    var preset: LushFocusPresetEntity?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "Lush",
            subtitle: preset.map { "\($0.name)" } ?? "Everything"
        )
    }

    var state: FocusFilterState {
        preset.flatMap { FocusModes.preset(id: $0.id) }?.filter ?? FocusFilterState()
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let state = state
        NotesModel.shared.focus.apply(state.isEmpty ? nil : state)
        return .result()
    }
}
