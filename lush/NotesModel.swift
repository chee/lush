import Foundation
import Observation
import SwiftUI
import WidgetKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

func reordered<T: Equatable>(_ items: [T], moving item: T, adjacentTo target: T, after: Bool) -> [T] {
    guard item != target else { return items }
    var next = items
    next.removeAll { $0 == item }
    guard let index = next.firstIndex(of: target) else { return items }
    next.insert(item, at: after ? index + 1 : index)
    return next
}

/// Something holding typed text that hasn't reached the doc yet. Both halves
/// matter at suspend: `pushNow` starts every writer at once from the
/// synchronous termination paths, `flushNow` is what waits for them.
@MainActor
protocol LiveWriter: AnyObject {
    /// Give up whatever debounce is running and start writing. Returns
    /// immediately.
    func pushNow()
    /// The same, and wait for it to land.
    func flushNow() async
}

@Observable @MainActor
final class NotesModel {
    static let shared = NotesModel()
    @ObservationIgnored let undoManager = UndoManager()
    private static let applyIncomingKey = "focusApplyIncoming"
    private static let sendChangesKey = "focusSendChanges"
    private static let presenceKey = "focusPresence"
    private static let irohKey = "peerSyncEnabled"

    private(set) var core: Core?
    var notes: [NoteInfo] = []
    /// The sidebar search query, mirrored here so the editor can tint the
    /// matches inside an opened note.
    var searchQuery = ""
    /// The frontmost note's editor, for inspector tabs that talk to it.
    weak var activeEditor: EditorController?
    let presence = PresenceManager()
    /// Note scratchpads and the pocket pad.
    let pads = PadStore()
    /// The logged-in account's contact doc url — the presence identity key.
    private(set) var presenceContactUrl: String?
    private(set) var applyingIncomingChanges = UserDefaults.standard.object(forKey: applyIncomingKey) as? Bool ?? true
    private(set) var sendingChanges = UserDefaults.standard.object(forKey: sendChangesKey) as? Bool ?? true
    private(set) var sharingPresence = UserDefaults.standard.object(forKey: presenceKey) as? Bool ?? true
    private(set) var changingIncomingChanges = false
    private(set) var changingSendingChanges = false
    /// Peer-to-peer sync. Off unless she asks for it: binding the iroh
    /// endpoint reaches for a relay, which can hang a fresh install's launch.
    private(set) var irohEnabled = UserDefaults.standard.bool(forKey: irohKey)
    private(set) var changingIroh = false
    private(set) var irohError: String?

    var focusModeEnabled: Bool {
        !applyingIncomingChanges && !sendingChanges && !sharingPresence
    }

    /// Any one of the three held back, which is what the moon fills in for.
    /// `focusModeEnabled` wants all three: the icon means something is being
    /// held back, the window's border means everything is.
    var focusModeEngaged: Bool {
        !applyingIncomingChanges || !sendingChanges || !sharingPresence
    }

    func setApplyingIncomingChanges(_ enabled: Bool) {
        guard let core else {
            applyingIncomingChanges = enabled
            UserDefaults.standard.set(enabled, forKey: Self.applyIncomingKey)
            return
        }
        changingIncomingChanges = true
        Task { [weak self] in
            let actual = await Task.detached {
                await core.setApplyIncoming(enabled: enabled)
                return core.isApplyingIncoming()
            }.value
            guard let self else { return }
            self.applyingIncomingChanges = actual
            self.changingIncomingChanges = false
            UserDefaults.standard.set(actual, forKey: Self.applyIncomingKey)
        }
    }

    func setSendingChanges(_ enabled: Bool) {
        guard let core else {
            sendingChanges = enabled
            UserDefaults.standard.set(enabled, forKey: Self.sendChangesKey)
            return
        }
        changingSendingChanges = true
        Task { [weak self] in
            let actual = await Task.detached {
                await core.setSendChanges(enabled: enabled)
                return core.isSendingChanges()
            }.value
            guard let self else { return }
            self.sendingChanges = actual
            self.changingSendingChanges = false
            UserDefaults.standard.set(actual, forKey: Self.sendChangesKey)
        }
    }

    func setIrohEnabled(_ enabled: Bool) {
        guard let core else {
            irohEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: Self.irohKey)
            return
        }
        changingIroh = true
        irohError = nil
        Task { [weak self] in
            let failure = await Task.detached { () -> String? in
                do {
                    try await core.setIrohEnabled(enabled: enabled)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard let self else { return }
            let actual = core.irohNodeId() != nil
            self.irohEnabled = actual
            self.irohError = actual == enabled ? nil : failure
            self.changingIroh = false
            UserDefaults.standard.set(actual, forKey: Self.irohKey)
            self.refreshPeers()
        }
    }

    func setSharingPresence(_ enabled: Bool) {
        sharingPresence = enabled
        UserDefaults.standard.set(enabled, forKey: Self.presenceKey)
        presence.setEnabled(enabled, url: nil)
    }

    func setFocusMode(_ enabled: Bool) {
        setApplyingIncomingChanges(!enabled)
        setSendingChanges(!enabled)
        setSharingPresence(!enabled)
    }

    func ephemeralMessageReceived(url: String, payload: Data) {
        presence.receive(url: url, payload: payload)
    }
    var folderUrl: String?
    var folderTitle: String = ""
    var connected = false
    /// The core has read what is on disk. Until then an empty answer only
    /// means nothing has been loaded to answer with.
    fileprivate(set) var storageLoaded = false
    /// Set when the core says every note on disk has reached the search index.
    /// Anything that would read an empty result as "nothing there" waits for
    /// it rather than guessing how long loading takes.
    private(set) var startupSettled = false
    private var startupWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    var irohPeers: [IrohPeer] = []

    func refreshPeers() {
        irohPeers = core?.irohPeers() ?? []
    }
    var selectedNoteUrl: String? {
        didSet {
            UserDefaults.standard.set(selectedNoteUrl, forKey: Self.lastOpenNoteKey)
            #if os(macOS)
            updateDockTilePreview()
            #endif
        }
    }
    var pendingFocusUrl: String?
    var status: String = "Starting…"
    var exportsInFlight = 0
    @ObservationIgnored private var noteRows: [String: NoteRow] = [:]
    var rootFolderUrl: String? { rootFolderUrls.first }
    var rootFolderUrls: [String] = []
    var folderTree: [FolderNode] = [] {
        didSet { rebuildNodeIndex() }
    }
    private var nodeIndex: [String: FolderNode] = [:]
    let focus = FocusModes()

    /// The sidebar's tree, cut down to the folders the running Focus allows. A
    /// folder outside the list stays if one of its descendants is in it, so the
    /// chosen folder is still reachable.
    var visibleFolderTree: [FolderNode] {
        guard let shown = focus.state?.shownFolderUrls, !shown.isEmpty else { return folderTree }
        let allowed = Set(shown)
        func filter(_ nodes: [FolderNode]) -> [FolderNode] {
            nodes.compactMap { node in
                guard node.kind == "folder" else { return node }
                if allowed.contains(node.url) { return node }
                let children = filter(node.children ?? [])
                guard children.contains(where: { $0.kind == "folder" }) else { return nil }
                return FolderNode(
                    url: node.url,
                    name: node.name,
                    kind: node.kind,
                    parentUrl: node.parentUrl,
                    children: children
                )
            }
        }
        return filter(folderTree)
    }

    var effectiveInboxUrl: String? { focus.state?.inboxUrl ?? inboxUrl }
    private(set) var syncLog: [String] = []
    private(set) var draftLists: [String: DraftListState] = [:]
    private(set) var checkedOutDrafts: [String: String] = [:]
    /// Bumped per docChanged; views watching docs without previews
    /// (patchwork docs, draft clones) key their refreshes off this.
    private(set) var docVersions: [String: Int] = [:]
    private(set) var checkoutDocs: [String: String] = UserDefaults.standard
        .dictionary(forKey: "lushDraftCheckoutDocs") as? [String: String] ?? [:]
    @ObservationIgnored private var checkoutWriteTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var checkoutDocCreation: [String: Task<String?, Never>] = [:]
    @ObservationIgnored private var draftDocHosts: [String: String] = [:]
    @ObservationIgnored private var draftCloneOrigins: [String: String] = [:]

    func appendSyncEvent(_ message: String) {
        let ts = Date().formatted(.dateTime.hour().minute().second())
        let entry = "[\(ts)] \(message)"
        if syncLog.count >= 100 { syncLog.removeFirst() }
        syncLog.append(entry)
    }
    private let semanticSearch = SemanticSearchIndex()
    private let spotlightIndex = SpotlightIndex()
    private var semanticIndexTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var semanticIndexTokens: [String: UUID] = [:]
    @ObservationIgnored private var spotlightIndexTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var spotlightIndexTokens: [String: UUID] = [:]
    @ObservationIgnored private var spotlightBackfilled: Set<String> = []
    @ObservationIgnored private var calendarNotesReindexed = false
    private var previewUpdateTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var previewUpdateTokens: [String: UUID] = [:]
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var noteWriteTasks: [String: Task<[String]?, Never>] = [:]
    @ObservationIgnored private var configWriteTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var noteObservers: [UUID: @MainActor (String) -> Void] = [:]
    @ObservationIgnored private var delegateBridge: DelegateBridge?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var documentHistoryCache: [String: DocumentHistorySummary] = [:]
    @ObservationIgnored private var snapshotCache: [HistorySnapshotKey: NoteSpansSnapshot] = [:]
    @ObservationIgnored private var snapshotRecency: [HistorySnapshotKey] = []
    @ObservationIgnored private var renderedSnapshotCache: [HistorySnapshotKey: NSAttributedString] = [:]
    @ObservationIgnored private var renderedRecency: [HistorySnapshotKey] = []
    private static let snapshotCacheCapacity = 12
    @ObservationIgnored private var pendingRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSmartNotebookCheckTask: Task<Void, Never>?
    @ObservationIgnored private var widgetSnapshotTask: Task<Void, Never>?
    @ObservationIgnored private var lastWidgetSnapshot: LushWidgetSnapshot?
    private var lastKnownCounts: [String: Int] = [:]
    private static let patchworkDocUrlsKey = "patchworkDocUrls"
    nonisolated private static let bootStart = Date()
    private(set) var patchworkDocUrls: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: patchworkDocUrlsKey) ?? []
    )
    @ObservationIgnored private var folderNodeCache: [String: (heads: [String], node: FolderNode)] = [:]
    @ObservationIgnored private var treeGeneration = 0
    @ObservationIgnored private var refreshGeneration = 0
    /// Notes whose preview + thumbnail have been read from the core. A refresh
    /// must not re-read the whole tree; docChanged drops the entries it stales.
    @ObservationIgnored private var metaFetched: Set<String> = []
    @ObservationIgnored private var contextMetaLoading: Set<String> = []
    @ObservationIgnored private var prefetchedUrls: Set<String> = []
    @ObservationIgnored private var visionBackfillTask: Task<Void, Never>?
    @ObservationIgnored private var visionBackfillToken = UUID()
    @ObservationIgnored private var visionBackfillAllowed = true
    @ObservationIgnored private var prewarmTask: Task<Core?, Never>?
    @ObservationIgnored private var prewarmWalkTask: Task<TreeWalk?, Never>?
    @ObservationIgnored private var deferredStartupRefresh = false

    init() {
        Self.bootLog("model init")
        pads.attach(self)
    }

    /// Open editors register here to hear about local and remote changes.
    func addNoteObserver(_ handler: @escaping @MainActor (String) -> Void) -> UUID {
        let id = UUID()
        noteObservers[id] = handler
        return id
    }

    func removeNoteObserver(_ id: UUID) {
        noteObservers[id] = nil
    }

    private func notifyNoteObservers(_ url: String, excluding origin: UUID? = nil) {
        for (id, observer) in noteObservers where id != origin {
            observer(url)
        }
    }

    private static let lastOpenNoteKey = "lastOpenNoteUrl"

    private(set) var accountUrl: String? = LushShared.accountUrl
    private(set) var accountUrls: [String] = LushShared.accountUrls
    /// Login progress and its last failure live on the model, not in a settings
    /// view that gets torn down whenever she navigates away mid-login.
    private(set) var loggingInUrl: String?
    private(set) var loginError: String?
    private(set) var accountNames: [String: String] = LushShared.accountNames
    private(set) var accountConfigUrl: String?
    private(set) var accountModuleSettingsUrl: String? = PatchworkWeb.accountModuleUrl
    private(set) var packageListUrls: [String] = PatchworkWeb.moduleUrls
    private(set) var inboxUrl: String?
    /// Notes about calendar items are filed here rather than in whichever
    /// notebook happened to be open. Made the first time one is written and
    /// kept on the account config, so every device files them together.
    private(set) var calendarFolderUrl: String?
    private(set) var contactName: String?
    private(set) var contactAvatarData: Data?
    var smartNotebooks: [SmartNotebook] = SmartNotebookStore.load()
    var smartHits: [String: [SearchHit]] = [:]
    var folderSettings: [String: FolderSettings] = FolderSettingsStore.load()
    @ObservationIgnored var smartHitTasks: [String: Task<Void, Never>] = [:]

    var loggedIn: Bool { accountUrl != nil }

    /// Same rule as the web side's `parseAccountInput`: `account:name/DocumentId`
    /// with exactly one slash, and an alphanumeric document id either way.
    static func normalizedAccountUrl(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.wholeMatch(of: /account:[^\/]+\/([A-Za-z0-9]+)/)
            .map { "automerge:" + $0.1 } ?? trimmed
        guard candidate.wholeMatch(of: /automerge:[A-Za-z0-9]+/) != nil else { return nil }
        return candidate
    }

    func logIn(accountUrl url: String) async -> Bool {
        guard let normalized = Self.normalizedAccountUrl(url) else {
            loginError = "Expected an automerge: or account: URL"
            return false
        }
        if core == nil { await start() }
        guard let core else {
            loginError = "Lush hasn't opened its storage yet"
            return false
        }
        loggingInUrl = normalized
        loginError = nil
        defer { loggingInUrl = nil }
        status = "Logging in…"
        // Folders and the scratchpad made before logging in belong to her, not
        // to this install: they're folded into the account she signs into.
        let localFolders = loggedIn ? [] : rootFolderUrls
        let localScratchpad = loggedIn ? nil : quickNoteUrl
        let localPins = pinnedUrls
        let localQuickNote = quickNoteUrl
        let localDocs = loggedIn ? [] : (
            [localScratchpad].compactMap { $0 } + localPins + CalendarLinks.noteUrls
        )
        do {
            var state = try await Task.detached {
                try await core.loginAccount(accountUrl: normalized)
            }.value
            if !localFolders.isEmpty || !localDocs.isEmpty {
                let account = state.accountUrl
                let merged = await Task.detached { () -> [String]? in
                    try? await core.adoptLocalDocs(
                        accountUrl: account,
                        folderUrls: localFolders,
                        docUrls: localDocs
                    )
                }.value
                if let merged { state.folders = merged }
            }
            if accountUrl != state.accountUrl { clearAccountState() }
            accountUrl = state.accountUrl
            LushShared.accountUrl = state.accountUrl
            if !accountUrls.contains(state.accountUrl) {
                accountUrls.append(state.accountUrl)
                LushShared.accountUrls = accountUrls
            }
            await applyAccount(state, localPins: localPins, localQuickNote: localQuickNote)
            status = ""
            appendSyncEvent("Logged in: \(state.accountUrl)")
            return true
        } catch {
            status = ""
            loginError = error.localizedDescription
            appendSyncEvent("Login failed: \(error.localizedDescription)")
            return false
        }
    }

    func logOut() {
        clearAccountState()
        accountUrl = nil
        LushShared.accountUrl = nil
        appendSyncEvent("Logged out")
    }

    /// Forget an account entirely. Logs out first when it's the active one.
    func forgetAccount(_ url: String) {
        if accountUrl == url { logOut() }
        accountUrls.removeAll { $0 == url }
        LushShared.accountUrls = accountUrls
        accountNames.removeValue(forKey: url)
        LushShared.accountNames = accountNames
    }

    func accountName(_ url: String) -> String? {
        url == accountUrl ? (contactName ?? accountNames[url]) : accountNames[url]
    }

    /// Everything derived from the account: its config and what the config
    /// carries. Cleared before another account's state lands so one account's
    /// notebooks and packages can never be pushed into another's config.
    private func clearAccountState() {
        accountConfigUrl = nil
        accountModuleSettingsUrl = nil
        PatchworkWeb.accountModuleUrl = nil
        inboxUrl = nil
        calendarFolderUrl = nil
        contactName = nil
        contactAvatarData = nil
        presenceContactUrl = nil
        presence.leave()
        smartNotebooks = []
        SmartNotebookStore.save([])
        folderSettings = [:]
        FolderSettingsStore.save([:])
        applyPackageLists([])
        applyQuickNote(nil)
        applyPinnedUrls([])
        rootFolderUrls = []
        persistRoots()
        folderUrl = nil
        refreshNotes()
    }

    private func applyAccount(
        _ state: AccountState,
        localPins: [String],
        localQuickNote: String?
    ) async {
        accountConfigUrl = state.configUrl
        inboxUrl = state.inbox
        accountModuleSettingsUrl = state.moduleSettingsUrl
        PatchworkWeb.accountModuleUrl = state.moduleSettingsUrl
        if let core, let configUrl = state.configUrl {
            let config = await Task.detached { core.configState(configUrl: configUrl) }.value
            if let config {
                if config.pinsConfigured {
                    applyPinnedUrls(config.pins)
                } else {
                    applyPinnedUrls(localPins)
                    syncConfigPins()
                }
                if config.quickNoteConfigured {
                    applyQuickNote(config.quickNote)
                } else {
                    applyQuickNote(localQuickNote)
                    syncConfigQuickNote()
                }
            }
        }
        loadSmartNotebooks()
        loadPackageLists()
        if !state.folders.isEmpty, state.folders != rootFolderUrls {
            rootFolderUrls = state.folders
            persistRoots()
            if folderUrl == nil || node(for: folderUrl ?? "") == nil {
                let first = state.folders[0]
                folderUrl = first
                try? core?.startFolderUrl(url: first)
            }
            refreshNotes()
        }
        guard let contactUrl = state.contactUrl, let core else { return }
        presenceContactUrl = contactUrl
        let info = await Task.detached { await core.contactInfo(url: contactUrl) }.value
        contactName = info?.name
        if let name = info?.name, !name.isEmpty {
            accountNames[state.accountUrl] = name
            LushShared.accountNames = accountNames
        }
        if let avatarUrl = info?.avatarUrl {
            contactAvatarData = await assetBytes(avatarUrl)
        }
    }

    /// Root-folder edits mirror into the synced config doc when logged in.
    private func syncConfigFolders() {
        guard let core, let configUrl = accountConfigUrl else { return }
        let urls = rootFolderUrls
        Task.detached { try? core.setConfigFolders(configUrl: configUrl, urls: urls) }
    }

    /// The extra package lists live in the synced config when logged in; the
    /// local mirror in PatchworkWeb is what the embeds actually read.
    func loadPackageLists() {
        guard let core, let configUrl = accountConfigUrl else { return }
        Task { @MainActor in
            let state = await Task.detached { core.configState(configUrl: configUrl) }.value
            guard let state else { return }
            if state.packages.isEmpty, !self.packageListUrls.isEmpty {
                self.syncConfigPackages()
            } else if state.packages != self.packageListUrls {
                self.applyPackageLists(state.packages)
            }
        }
    }

    func setPackageLists(_ urls: [String]) {
        applyPackageLists(urls)
        syncConfigPackages()
    }

    private func applyPackageLists(_ urls: [String]) {
        packageListUrls = urls
        PatchworkWeb.setModuleUrls(urls)
    }

    private func syncConfigPackages() {
        guard let core, let configUrl = accountConfigUrl else { return }
        let urls = packageListUrls
        Task.detached { try? core.setConfigPackages(configUrl: configUrl, urls: urls) }
    }

    /// The calendar folder, made on first use. It is a folder like any other —
    /// it syncs, it is searched, and its notes are indexed — it is only where
    /// they go that is decided here.
    func calendarFolder() async -> String? {
        guard let core else { return nil }
        if let url = calendarFolderUrl { return url }
        if let configUrl = accountConfigUrl {
            let existing = await Task.detached { [core, configUrl] () -> String? in
                core.configState(configUrl: configUrl)?.calendar
            }.value
            if let existing {
                calendarFolderUrl = existing
                return existing
            }
        }
        let created = try? await Task.detached { [core] () -> String in
            try core.createSubfolder(title: "Calendar")
        }.value
        guard let url = created else { return nil }
        calendarFolderUrl = url
        if let configUrl = accountConfigUrl {
            Task.detached { [core, configUrl, url] in
                try? core.setConfigCalendar(configUrl: configUrl, url: url)
            }
        }
        refreshNotes()
        return url
    }

    func setInbox(_ url: String) {
        inboxUrl = url
        guard let core, let configUrl = accountConfigUrl else { return }
        Task.detached { try? core.setConfigInbox(configUrl: configUrl, url: url) }
    }

    /// Widget/shortcut note creation lands in the configured inbox folder.
    @discardableResult
    func createNoteInInbox(snap: ContextSnapshot? = nil) async -> String? {
        if let inbox = effectiveInboxUrl {
            return await createNote(inFolder: inbox, snap: snap)
        } else {
            return await createNote(snap: snap)
        }
    }

    private func persistRoots() {
        LushShared.rootFolderUrls = rootFolderUrls
    }

    /// Written to a file as well as the log: os_log drops messages under load,
    /// and a boot trace with holes in it is worse than none.
    nonisolated static func bootLog(_ message: String) {
        let ms = Int(Date().timeIntervalSince(bootStart) * 1000)
        NSLog("lush boot +%dms %@", ms, message)
        bootTraceLock.lock()
        bootTrace.append("+\(ms)ms \(message)")
        let text = bootTrace.joined(separator: "\n") + "\n"
        bootTraceLock.unlock()
        bootTraceQueue.async {
            try? FileManager.default.createDirectory(
                at: bootTraceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? text.write(to: bootTraceURL, atomically: true, encoding: .utf8)
        }
    }

    nonisolated private static let bootTraceLock = NSLock()
    nonisolated private static let bootTraceQueue = DispatchQueue(
        label: "party.chee.lush.boot-trace",
        qos: .utility
    )
    nonisolated(unsafe) private static var bootTrace: [String] = []
    nonisolated static let bootTraceURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Lush", isDirectory: true)
        .appendingPathComponent("boot-trace.log")

    /// Builds the core off the main actor and starts the root folder loading
    /// from storage. Called from `LushApp.init`, where a `Task { @MainActor }`
    /// would sit behind a second of scene construction before it ran.
    func prewarm() {
        guard prewarmTask == nil else { return }
        let dataDir = LushShared.coreDataDirectory()
        let saved = LushShared.rootFolderUrls
        let applyIncoming = applyingIncomingChanges
        let sendChanges = sendingChanges
        let enableIroh = irohEnabled
        let bridge = DelegateBridge(model: self)
        delegateBridge = bridge
        let priority: String? = {
            if case .note(let url) = AppRouter.shared.pending { return url }
            guard saved.first != nil else { return nil }
            return UserDefaults.standard.string(forKey: Self.lastOpenNoteKey)
        }()
        let task = Task.detached { () -> Core? in
            Self.bootLog("prewarm begin")
            guard let core = try? Core.newWithIroh(
                dataDir: dataDir.path,
                serverUrl: nil,
                enableIroh: enableIroh
            ) else { return nil }
            Self.bootLog("core constructed")
            await core.setApplyIncoming(enabled: applyIncoming)
            await core.setSendChanges(enabled: sendChanges)
            core.setDelegate(delegate: bridge)
            guard let first = saved.first else { return core }
            // The note being opened goes in before the folder tree, so its
            // storage load and background sync are queued ahead of the flood.
            if let priority { core.prefetchNotes(urls: [priority]) }
            try? core.startFolderUrl(url: first)
            core.prefetchNotes(urls: Array(saved.dropFirst()))
            Self.bootLog("root folder scheduled for local load")
            return core
        }
        prewarmTask = task
        guard let first = saved.first else { return }
        prewarmWalkTask = Task.detached { () -> TreeWalk? in
            guard let core = await task.value else { return nil }
            try? await core.openNote(url: first)
            defer { try? core.closeNote(url: first) }
            Self.bootLog("root folder loaded")
            let walk = await Self.walkTree(core: core, rootUrls: saved, cache: [:], prefetched: [])
            Self.bootLog("prewarm walk done visible=\(walk.visible.count) localMs=\(walk.localMs)")
            return walk
        }
    }

    func start() async {
        if core != nil { return }
        if let startTask {
            await startTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            await self?.startOnce()
            return
        }
        startTask = task
        await task.value
        startTask = nil
    }

    private func startOnce() async {
        guard core == nil else { return }
        Self.bootLog("startOnce begin")
        AppActivity.watch()
        focus.watchSystemFocus()
        Task { await focus.reconcileWithSystemFocus() }
        do {
            var saved = LushShared.rootFolderUrls
            prewarm()
            guard let core = await prewarmTask?.value else {
                status = "Failed to start"
                Self.bootLog("prewarm produced no core")
                return
            }
            Self.bootLog("Core adopted")
            self.core = core
            #if os(iOS) || os(visionOS)
            // A core built while the app is already in the background starts
            // out thinking it may work freely; tell it where we actually are.
            BackgroundSync.applyCoreActivity()
            #endif
            watchMemoryPressure()
            LushAgentServer.shared.start(model: self)
            applyingIncomingChanges = core.isApplyingIncoming()
            sendingChanges = core.isSendingChanges()
            PatchworkWeb.coreServerPort = core.localServerPort()
            Task.detached {
                let fm = FileManager.default
                guard let container = fm.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first else { return }
                let entries = (try? fm.contentsOfDirectory(
                    at: container,
                    includingPropertiesForKeys: nil
                )) ?? []
                for entry in entries where entry.lastPathComponent.hasPrefix("LushWebStorage") {
                    try? fm.removeItem(at: entry)
                }
            }
            Task { [semanticSearch] in await semanticSearch.attach(core) }
            presence.model = self
            presence.setEnabled(sharingPresence, url: nil)
            connected = core.isConnected()
            Self.bootLog("Core bridged")

            if case .note(let url) = AppRouter.shared.pending {
                selectedNoteUrl = url
            } else if saved.first != nil {
                selectedNoteUrl = UserDefaults.standard.string(forKey: Self.lastOpenNoteKey)
            }

            if let first = saved.first {
                rootFolderUrls = saved
                persistRoots()
                folderUrl = first
                status = ""
                refreshNotes(prepared: await prewarmWalkTask?.value)
                startPolling()
                startMaintenancePolling()
                Self.bootLog("startup UI state queued")
                appendSyncEvent("Started: \(saved.count) root folder(s)")
                if let account = accountUrl {
                    Task { await self.logIn(accountUrl: account) }
                }
            } else {
                // Fresh install: create the folder doc (one-time wait, acceptable).
                status = "Creating folder…"
                let url = try await Task.detached {
                    try core.ensureFolder(existingUrl: nil)
                }.value
                Self.bootLog("fresh root folder created")
                saved = [url]
                rootFolderUrls = saved
                persistRoots()
                folderUrl = url
                status = ""
                refreshNotes()
                startPolling()
                startMaintenancePolling()
                Self.bootLog("fresh startup UI state queued")
                appendSyncEvent("Started: new folder created")
            }
        } catch {
            status = "Failed to start: \(error.localizedDescription)"
            Self.bootLog("startOnce failed \(error.localizedDescription)")
        }
    }

    func selectFolder(_ url: String?) async {
        guard let url else { return }
        selectedNoteUrl = nil
        guard let core else { return }
        do {
            _ = try await Task.detached { try core.ensureFolder(existingUrl: url) }.value
            folderUrl = url
            refreshNotes()
        } catch {
            status = "Couldn't open folder: \(error.localizedDescription)"
        }
    }

    func createFolder() {
        if let folderUrl {
            createSubfolder(in: folderUrl)
            return
        }
        guard let core else { return }
        Task.detached { [core, weak self] in
            do {
                _ = try core.createSubfolder(title: "New Folder")
                await MainActor.run { [weak self] in self?.refreshNotes() }
            } catch {
                await MainActor.run { [weak self] in
                    self?.status = "Couldn't create folder: \(error.localizedDescription)"
                }
            }
        }
    }

    func createSubfolder(in folderUrl: String) {
        guard let core else { return }
        Task.detached { [core, weak self, folderUrl] in
            do {
                _ = try core.createSubfolderIn(folderUrl: folderUrl, title: "New Folder")
                await MainActor.run { [weak self] in self?.refreshNotes() }
            } catch {
                await MainActor.run { [weak self] in
                    self?.status = "Couldn't create folder: \(error.localizedDescription)"
                }
            }
        }
    }

    func addDocToCurrentFolder(url: String) {
        guard let core else { return }
        patchworkDocUrls.insert(url)
        let atTop = newNoteAtTop(in: folderUrl)
        Task.detached { [core, weak self, url, atTop] in
            do {
                try await core.linkNoteToFolder(noteUrl: url, title: "", atTop: atTop)
            } catch {
                await MainActor.run { [weak self] in
                    self?.patchworkDocUrls.remove(url)
                    self?.status = "Couldn't add document: \(error.localizedDescription)"
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                UserDefaults.standard.set(Array(self.patchworkDocUrls), forKey: Self.patchworkDocUrlsKey)
                self.selectedNoteUrl = url
                self.refreshNotes()
            }
        }
    }

    func removeEntry(parentUrl: String?, url: String) {
        guard let core, let parent = parentUrl ?? folderUrl else { return }
        let title = node(for: url)?.name ?? ""
        removeEntry(core: core, parent: parent, url: url, title: title)
    }

    private func removeEntry(core: Core, parent: String, url: String, title: String) {
        let linkedItems = CalendarLinks.itemIds(for: url)
        Task.detached { [core, weak self, parent, url, title] in
            do {
                try core.removeEntry(folderUrl: parent, url: url)
            } catch {
                await MainActor.run { [weak self] in
                    self?.status = "Couldn't remove note: \(error.localizedDescription)"
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                CalendarLinks.set([], for: url)
                self.undoManager.registerUndo(withTarget: self) { model in
                    model.restoreEntry(parent: parent, url: url, title: title, linkedItems: linkedItems)
                }
                self.undoManager.setActionName("Remove Note")
                self.refreshNotes()
            }
        }
    }

    private func restoreEntry(parent: String, url: String, title: String, linkedItems: [String] = []) {
        guard let core else { return }
        undoManager.registerUndo(withTarget: self) { model in
            model.removeEntry(core: core, parent: parent, url: url, title: title)
        }
        undoManager.setActionName("Remove Note")
        let atTop = newNoteAtTop(in: parent)
        Task.detached { [core, weak self, parent, url, title, atTop] in
            do {
                try core.linkNoteToFolderIn(
                    folderUrl: parent,
                    noteUrl: url,
                    title: title,
                    atTop: atTop
                )
            } catch {
                await MainActor.run { [weak self] in
                    self?.status = "Couldn't restore note: \(error.localizedDescription)"
                }
                return
            }
            await MainActor.run { [weak self] in
                if !linkedItems.isEmpty { CalendarLinks.set(linkedItems, for: url) }
                self?.refreshNotes()
            }
        }
    }

    /// Top-level notebooks have no parent folder to hold their name, so their
    /// title is written into the folder doc itself.
    func renameNode(_ node: FolderNode, to name: String) {
        if let parent = node.parentUrl {
            renameEntry(parentUrl: parent, url: node.url, to: name)
            return
        }
        guard let core else { return }
        Task.detached { [core, weak self, node, name] in
            try? core.renameNote(url: node.url, title: name)
            await MainActor.run { [weak self] in self?.refreshNotes() }
        }
    }

    func renameEntry(parentUrl: String?, url: String, to name: String) {
        guard let core, let parent = parentUrl ?? folderUrl else { return }
        Task.detached { [core, weak self, parent, url, name] in
            try? core.renameEntry(folderUrl: parent, url: url, title: name)
            await MainActor.run { [weak self] in self?.refreshNotes() }
        }
    }

    private nonisolated static func computeTree(
        core: Core,
        rootFolderUrls: [String],
        cache: [String: (heads: [String], node: FolderNode)]
    ) async -> (tree: [FolderNode], newCache: [String: (heads: [String], node: FolderNode)]) {
        let rootUrls = Set(rootFolderUrls)
        var visited = Set<String>()
        var newCache = cache
        func folderNode(url: String, name: String, parent: String?) async -> FolderNode {
            guard visited.insert(url).inserted else {
                return FolderNode(url: url, name: name, kind: "folder", parentUrl: parent, children: [])
            }
            let currentHeads = await core.docHeads(url: url)
            if let cached = newCache[url], cached.heads == currentHeads {
                let cachedChildren = cached.node.children ?? []
                var subfolderChildren: [FolderNode] = []
                for child in cachedChildren where child.kind == "folder" {
                    subfolderChildren.append(await folderNode(url: child.url, name: child.name, parent: url))
                }
                let noteChildren = cachedChildren.filter { $0.kind != "folder" }
                let children = subfolderChildren + noteChildren
                let node = FolderNode(url: url, name: cached.node.name, kind: "folder", parentUrl: parent, children: children)
                newCache[url] = (heads: currentHeads, node: node)
                return node
            }
            let entries = await core.folderEntriesOf(url: url)
            var children: [FolderNode] = []
            for entry in entries where entry.kind == "folder" && !rootUrls.contains(entry.url) {
                children.append(await folderNode(url: entry.url, name: entry.name, parent: url))
            }
            children += entries
                .filter { $0.kind != "folder" }
                .map { FolderNode(url: $0.url, name: $0.name, kind: $0.kind, parentUrl: url, children: nil) }
            let node = FolderNode(url: url, name: name, kind: "folder", parentUrl: parent, children: children)
            newCache[url] = (heads: currentHeads, node: node)
            return node
        }
        var tree: [FolderNode] = []
        for url in rootFolderUrls {
            let name = await core.noteTitle(url: url)
            tree.append(await folderNode(url: url, name: name, parent: nil))
        }
        return (tree, newCache)
    }

    /// Preview + thumbnail for each url. The core reads are async across the
    /// FFI, so these are suspended futures rather than parked threads and the
    /// fan-out no longer has to be rationed.
    private nonisolated static func fetchMeta(
        core: Core,
        urls: [String]
    ) async -> ([String: String], [String: Data]) {
        var previews: [String: String] = [:]
        var thumbnails: [String: Data] = [:]
        await withTaskGroup(of: (String, String, Data?).self) { group in
            for url in urls {
                group.addTask {
                    async let preview = core.notePreview(url: url)
                    async let thumbnail = core.noteThumbnailBytes(url: url)
                    return (url, await preview, await thumbnail.map { Data($0) })
                }
            }
            for await (url, preview, thumbnail) in group {
                previews[url] = preview
                if let thumbnail { thumbnails[url] = thumbnail }
            }
        }
        return (previews, thumbnails)
    }

    private nonisolated static func visibleNotes(in tree: [FolderNode]) -> [FolderNode] {
        var out: [FolderNode] = []
        func walk(_ nodes: [FolderNode]) {
            for node in nodes {
                if node.kind == "lush" || node.kind == "rich" { out.append(node) }
                if let children = node.children { walk(children) }
            }
        }
        walk(tree)
        return out
    }

    private func buildTree() {
        treeGeneration += 1
        guard let core else { folderTree = []; return }
        let generation = treeGeneration
        let rootUrls = rootFolderUrls
        let cache = folderNodeCache
        Task.detached { [core, rootUrls, cache, generation, weak self] in
            let (tree, newCache) = await Self.computeTree(core: core, rootFolderUrls: rootUrls, cache: cache)
            guard let self else { return }
            await MainActor.run {
                guard self.treeGeneration == generation else { return }
                self.folderTree = tree
                self.folderNodeCache = newCache
                self.writeWidgetSnapshot()
            }
            let parentMap = await self.notebookTree.parents
            core.setSearchParents(parents: parentMap.map { SearchParent(url: $0.key, parent: $0.value) })
        }
    }

    func noteRow(for url: String) -> NoteRow {
        if let row = noteRows[url] { return row }
        let row = NoteRow()
        noteRows[url] = row
        return row
    }

    func preview(_ url: String) -> String { noteRows[url]?.preview ?? "" }

    private func setPreview(_ url: String, _ text: String) {
        noteRow(for: url).preview = text
    }

    private func mergeMeta(previews: [String: String], thumbnails: [String: Data]) {
        for (url, preview) in previews { noteRow(for: url).preview = preview }
        for (url, thumbnail) in thumbnails { noteRow(for: url).thumbnail = thumbnail }
    }

    private func clearRow(_ url: String) {
        guard let row = noteRows[url] else { return }
        if !row.preview.isEmpty { row.preview = "" }
        if row.thumbnail != nil { row.thumbnail = nil }
        if row.contextMeta != nil { row.contextMeta = nil }
    }

    private func pruneRows(to liveUrls: Set<String>) {
        for url in noteRows.keys where !liveUrls.contains(url) { clearRow(url) }
    }

    private func rebuildNodeIndex() {
        var index: [String: FolderNode] = [:]
        func walk(_ nodes: [FolderNode]) {
            for node in nodes {
                index[node.url] = node
                if let children = node.children { walk(children) }
            }
        }
        walk(folderTree)
        nodeIndex = index
    }

    func node(for url: String) -> FolderNode? {
        if let found = nodeIndex[url] { return found }
        // a draft clone borrows its origin's node so titles stay right
        if let origin = draftCloneOrigins[url], origin != url {
            return node(for: origin)
        }
        return nil
    }

    private var visibleNoteNodes: [FolderNode] { Self.visibleNotes(in: folderTree) }

    /// Sidebar selection: folders become the target for new items; notes open
    /// in the editor (and retarget creation to their parent folder).
    func selectItem(_ url: String?) async {
        guard let url else { return }
        guard let node = node(for: url) else {
            // search hit for a note outside the built tree
            selectedNoteUrl = url
            return
        }
        if node.kind == "folder" {
            await selectFolder(url)
        } else {
            // open instantly; folder retargeting happens behind the scenes
            selectedNoteUrl = url
            if let parent = node.parentUrl {
                if let core {
                    Task.detached { [core, parent, url] in
                        core.refreshFolderEntry(folderUrl: parent, url: url)
                    }
                }
                folderUrl = parent
            }
        }
    }

    /// A fresh folder doc pinned to the sidebar as its own top-level notebook.
    @discardableResult
    func createNotebook(named name: String = "New Notebook") async -> String? {
        guard let core else { return nil }
        do {
            let url = try await Task.detached { [core, name] in
                let url = try core.ensureFolder(existingUrl: nil)
                try core.renameNote(url: url, title: name)
                return url
            }.value
            rootFolderUrls.append(url)
            persistRoots()
            syncConfigFolders()
            folderUrl = url
            refreshNotes()
            return url
        } catch {
            status = "Couldn't create notebook: \(error.localizedDescription)"
            return nil
        }
    }

    func addRootFolder(_ url: String) async {
        guard let core else { return }
        guard !rootFolderUrls.contains(url) else { return }
        status = "Opening folder…"
        do {
            let opened = try await Task.detached {
                try core.ensureFolder(existingUrl: url)
            }.value
            rootFolderUrls.append(opened)
            persistRoots()
            syncConfigFolders()
            folderUrl = opened
            refreshNotes()
            status = ""
        } catch {
            status = "Couldn't open folder: \(error.localizedDescription)"
        }
    }

    func removeRootFolder(_ url: String) {
        guard rootFolderUrls.count > 1,
              let index = rootFolderUrls.firstIndex(of: url)
        else { return }
        rootFolderUrls.remove(at: index)
        persistRoots()
        syncConfigFolders()
        if folderUrl == url || node(for: folderUrl ?? "") == nil {
            selectedNoteUrl = nil
            let fallback = rootFolderUrls[0]
            Task { await selectFolder(fallback) }
        }
        refreshNotes()
    }

    /// iOS edit mode moves rows within whatever is on screen; anything the
    /// current focus hides keeps its place at the end.
    func moveRootFolders(displayed: [String], from: IndexSet, to: Int) {
        var urls = displayed
        urls.move(fromOffsets: from, toOffset: to)
        let hidden = rootFolderUrls.filter { !urls.contains($0) }
        applyRootFolderOrder(urls + hidden)
    }

    private func applyRootFolderOrder(_ urls: [String]) {
        guard urls != rootFolderUrls else { return }
        rootFolderUrls = urls
        let ordered = urls.compactMap { url in folderTree.first { $0.url == url } }
        if ordered.count == folderTree.count { folderTree = ordered }
        persistRoots()
        syncConfigFolders()
        buildTree()
    }

    func reorderRootFolder(_ url: String, adjacentTo targetUrl: String, after: Bool) {
        applyRootFolderOrder(reordered(rootFolderUrls, moving: url, adjacentTo: targetUrl, after: after))
    }

    typealias FolderNodeCacheEntry = (heads: [String], node: FolderNode)

    struct TreeWalk: Sendable {
        let notes: [NoteInfo]
        let folderTitle: String
        let tree: [FolderNode]
        let cache: [String: FolderNodeCacheEntry]
        let visible: [FolderNode]
        let unprefetched: [String]
        let localMs: Int
    }

    nonisolated private static func walkTree(
        core: Core,
        rootUrls: [String],
        cache: [String: FolderNodeCacheEntry],
        prefetched: Set<String>
    ) async -> TreeWalk {
        let start = Date()
        async let notesTask = core.listNotes()
        async let titleTask = core.folderTitle()
        let notes = await notesTask
        let folderTitle = await titleTask
        let (tree, newCache) = await computeTree(core: core, rootFolderUrls: rootUrls, cache: cache)
        let visible = visibleNotes(in: tree)
        let localMs = Int(Date().timeIntervalSince(start) * 1000)
        let unprefetched = notes.map(\.url).filter { !prefetched.contains($0) }
        return TreeWalk(
            notes: notes,
            folderTitle: folderTitle,
            tree: tree,
            cache: newCache,
            visible: visible,
            unprefetched: unprefetched,
            localMs: localMs
        )
    }

    func refreshNotes(prepared: TreeWalk? = nil) {
        guard let core else { return }
        treeGeneration += 1
        refreshGeneration += 1
        let treeGen = treeGeneration
        let refreshGen = refreshGeneration
        let rootUrls = rootFolderUrls
        let cache = folderNodeCache
        let fetched = metaFetched
        let prefetched = prefetchedUrls
        Self.bootLog("refreshNotes begin roots=\(rootUrls.count)")
        if let prepared {
            guard publishRefresh(prepared, treeGen: treeGen, refreshGen: refreshGen) else { return }
            finishRefresh(core: core, walk: prepared, fetched: fetched, refreshGen: refreshGen)
            return
        }
        Task.detached { [core, rootUrls, cache, fetched, prefetched, treeGen, refreshGen, weak self] in
            let walk = await Self.walkTree(
                core: core,
                rootUrls: rootUrls,
                cache: cache,
                prefetched: prefetched
            )
            await MainActor.run { [weak self] in
                guard let self,
                      self.publishRefresh(walk, treeGen: treeGen, refreshGen: refreshGen)
                else { return }
                self.finishRefresh(core: core, walk: walk, fetched: fetched, refreshGen: refreshGen)
            }
        }
    }

    private func publishRefresh(_ walk: TreeWalk, treeGen: Int, refreshGen: Int) -> Bool {
        guard refreshGeneration == refreshGen else { return false }
        prefetchedUrls.formUnion(walk.unprefetched)
        notes = walk.notes
        folderTitle = walk.folderTitle
        if treeGeneration == treeGen {
            folderTree = walk.tree
            folderNodeCache = walk.cache
        }
        if let selected = selectedNoteUrl, node(for: selected) == nil {
            selectedNoteUrl = nil
        }
        Self.bootLog(
            "sidebar published notes=\(walk.notes.count) visible=\(walk.visible.count) localMs=\(walk.localMs)"
        )
        return true
    }

    private func finishRefresh(core: Core, walk: TreeWalk, fetched: Set<String>, refreshGen: Int) {
        let visible = walk.visible
        let unprefetched = walk.unprefetched
        let urlsNeedingMeta = visible.map(\.url).filter { !fetched.contains($0) }
        let richNotes = visible.filter { $0.kind == "rich" }.map {
            NoteInfo(url: $0.url, name: $0.name, kind: $0.kind)
        }
        let fileNotes = visible.filter { $0.kind == "file" }.map {
            NoteInfo(url: $0.url, name: $0.name, kind: $0.kind)
        }
        if !unprefetched.isEmpty {
            Task.detached { [core, unprefetched] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                core.prefetchNotes(urls: unprefetched)
            }
        }
        Task.detached { [core, urlsNeedingMeta, visible, richNotes, fileNotes, refreshGen, weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled,
                  await MainActor.run(body: { [weak self] in self?.refreshGeneration == refreshGen })
            else { return }
            let metaStart = Date()
            let (newPreviews, newThumbnails) = await Self.fetchMeta(
                core: core,
                urls: urlsNeedingMeta
            )
            let metaMs = Int(Date().timeIntervalSince(metaStart) * 1000)
            await MainActor.run { [weak self] in
                guard let self, self.refreshGeneration == refreshGen else { return }
                self.mergeMeta(previews: newPreviews, thumbnails: newThumbnails)
                let liveUrls = Set(visible.map(\.url))
                self.pruneRows(to: liveUrls)
                self.metaFetched.formUnion(newPreviews.keys)
                self.metaFetched.formIntersection(liveUrls)
                self.backfillSemanticIndex(for: richNotes)
                self.backfillFileSemanticIndex(for: fileNotes)
                self.backfillSpotlightIndex(for: richNotes)
                self.backfillAssetVision()
                Self.bootLog(
                    "metadata published previews=\(newPreviews.count) thumbnails=\(newThumbnails.count) metaMs=\(metaMs)"
                )
                self.writeWidgetSnapshot()
            }
        }
    }

    func reindexAll() {
        guard let core else { return }
        Task { [spotlightIndex] in
            let urls = await Task.detached { core.noteEmbeddingDigests().keys }.value
            for url in urls {
                await Task.detached { core.removeNoteEmbeddings(url: url) }.value
            }
            await spotlightIndex.reset()
        }
        spotlightBackfilled.removeAll()
        let richNotes = notes.filter { $0.kind == "rich" }
        backfillSemanticIndex(for: richNotes)
        backfillSpotlightIndex(for: richNotes)
    }

    /// Drops loose commits already covered by a fragment. Nothing reclaims them
    /// otherwise, so they accumulate for the life of the account.
    func reclaimLooseCommits() async -> String {
        guard let core else { return "Lush is still starting." }
        do {
            let result = try await Task.detached { [core] in
                try core.reclaimLooseCommits()
            }.value
            let summary = "\(result.dropped) dropped across \(result.trees) docs"
            appendSyncEvent("Reclaimed loose commits: \(summary)")
            return summary
        } catch {
            return error.localizedDescription
        }
    }

    func forceSync() {
        guard let core else { return }
        appendSyncEvent("Force sync: resyncing \(rootFolderUrls.count) root folder(s)")
        Task {
            for url in rootFolderUrls {
                let changes = await Task.detached { core.docChangeCount(url: url) }.value
                let entries = await core.folderEntriesOf(url: url).count
                appendSyncEvent("  \(url.suffix(12)): \(entries) entries, \(changes) changes locally")
                await Task.detached { try? await core.resyncDoc(url: url) }.value
            }
            try? await Task.sleep(for: .seconds(5))
            refreshNotes()
            for url in rootFolderUrls {
                let changes = await Task.detached { core.docChangeCount(url: url) }.value
                let entries = await core.folderEntriesOf(url: url).count
                appendSyncEvent("  post-sync \(url.suffix(12)): \(entries) entries, \(changes) changes")
            }
        }
    }

    /// Get everything typed but not yet durable onto disk.
    ///
    /// This is the suspend path, and on iOS it is the last moment the app
    /// reliably runs code: the system suspends a backgrounded app and can
    /// kill it later without ever sending `willTerminate`, which is the only
    /// place `shutdown()` was wired up. Until this runs, a recent edit exists
    /// only in memory — behind the editor's 300ms push debounce, then behind
    /// the core's save debounce — and a kill in that window loses it.
    func flushPendingWrites() async {
        for writer in liveWriters {
            await writer.flushNow()
        }
        for task in Array(noteWriteTasks.values) {
            _ = await task.value
        }
        guard let core else { return }
        await core.flushPendingSaves()
    }

    func syncNow(budget: Duration) async {
        if core == nil { await start() }
        guard let core else { return }
        pushLiveEditors()
        core.connect()
        await drainSharedIntake()
        let urls = rootFolderUrls
        await Task.detached { for url in urls { try? await core.resyncDoc(url: url) } }.value

        let deadline = ContinuousClock.now.advanced(by: budget)
        var counts = lastKnownCounts
        var quiet = 0
        while ContinuousClock.now < deadline, quiet < 3, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            var changed = false
            for url in urls {
                let count = await core.folderEntriesOf(url: url).count
                if counts[url] != count {
                    counts[url] = count
                    changed = true
                }
            }
            quiet = changed ? 0 : quiet + 1
        }

        lastKnownCounts = counts
        refreshNotes()
        try? await Task.sleep(for: .seconds(1))
        writeWidgetSnapshot()
        appendSyncEvent("Background sync finished")
    }

    /// A safety net, not the mechanism: `docChanged` already refreshes when a
    /// folder moves. This only catches a change the delegate never announced.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                await AppActivity.waitUntilActive()
                guard !Task.isCancelled else { break }
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { break }
                guard let (core, rootUrls, knownCounts) = await MainActor.run(body: { [weak self] () -> (Core, [String], [String: Int])? in
                    guard let self, let core = self.core else { return nil }
                    return (core, self.rootFolderUrls, self.lastKnownCounts)
                }) else { break }
                var newCounts: [String: Int] = [:]
                for url in rootUrls {
                    newCounts[url] = await core.folderEntriesOf(url: url).count
                }
                await MainActor.run { [weak self, newCounts] in
                    guard let self else { return }
                    var anyChanged = false
                    for (url, count) in newCounts {
                        let last = knownCounts[url] ?? -1
                        if count != last {
                            self.appendSyncEvent("[poll] \(url.suffix(12)): \(last) → \(count) entries")
                            self.lastKnownCounts[url] = count
                            anyChanged = true
                        }
                    }
                    if anyChanged { self.refreshNotes() }
                }
            }
        }
    }

    /// The core announces this once the prefetch walk has indexed every note it
    /// found on disk. Before it, an empty search means the search was early.
    func notesPrefetched() {
        guard !startupSettled else { return }
        startupSettled = true
        drainStartupWaiters()
        Task { [weak self] in await self?.checkSmartNotebooks() }
        if deferredStartupRefresh {
            deferredStartupRefresh = false
            refreshNotes()
        }
    }

    private func drainStartupWaiters() {
        let waiters = startupWaiters
        startupWaiters = [:]
        for waiter in waiters.values { waiter.resume() }
    }

    func awaitStartup() async {
        guard !startupSettled else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if startupSettled || Task.isCancelled {
                    continuation.resume()
                } else {
                    startupWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.startupWaiters.removeValue(forKey: id)?.resume()
            }
        }
    }

    private func startMaintenancePolling() {
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                // the intake is also drained on activation, so nothing is
                // missed by leaving this parked while backgrounded
                await AppActivity.waitUntilActive()
                guard !Task.isCancelled else { break }
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { break }
                await self.drainSharedIntake()
            }
        }
    }

    func writeWidgetSnapshot() {
        guard widgetSnapshotTask == nil else { return }
        widgetSnapshotTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            self.widgetSnapshotTask = nil
            guard let root = LushShared.container else { return }

            let folders = self.widgetFolders(from: self.folderTree)
            let defaultFolderUrl = self.folderUrl ?? self.rootFolderUrls.first ?? folders.first?.url
            let url = root.appendingPathComponent(LushShared.widgetSnapshotFileName)
            let previous = self.lastWidgetSnapshot
            do {
                let (snapshot, wrote) = try await Task.detached { () throws -> (LushWidgetSnapshot, Bool) in
                    let old = previous ?? (try? Data(contentsOf: url)).flatMap {
                        try? JSONDecoder().decode(LushWidgetSnapshot.self, from: $0)
                    }
                    if let old, old.defaultFolderUrl == defaultFolderUrl, old.folders == folders {
                        return (old, false)
                    }
                    let snapshot = LushWidgetSnapshot(
                        updatedAt: Date(),
                        defaultFolderUrl: defaultFolderUrl,
                        folders: folders
                    )
                    try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
                    return (snapshot, true)
                }.value
                self.lastWidgetSnapshot = snapshot
                if wrote {
                    WidgetCenter.shared.reloadTimelines(ofKind: LushShared.folderContentWidgetKind)
                }
            } catch {
                self.appendSyncEvent("Widget snapshot failed: \(error.localizedDescription)")
            }
        }
    }

    private func widgetFolders(from nodes: [FolderNode]) -> [LushWidgetFolderSnapshot] {
        var folders: [LushWidgetFolderSnapshot] = []

        func walk(_ nodes: [FolderNode], prefix: String) {
            for node in nodes where node.kind == "folder" {
                let title = node.displayName
                let path = prefix.isEmpty ? title : "\(prefix) / \(title)"
                let children = node.children ?? []
                let items = children
                    .filter { $0.kind != "folder" }
                    .prefix(6)
                    .map {
                        LushWidgetItemSnapshot(
                            url: $0.url,
                            title: $0.displayName,
                            preview: preview($0.url),
                            kind: $0.kind
                        )
                    }
                folders.append(LushWidgetFolderSnapshot(
                    url: node.url,
                    title: title,
                    path: path,
                    totalItemCount: children.filter { $0.kind != "folder" }.count,
                    items: Array(items)
                ))
                walk(children, prefix: path)
            }
        }

        walk(nodes, prefix: "")
        return folders
    }

    /// The two seeds and the peer list are this device's identity: erase them
    /// and every friend code you handed out points at a stranger.
    static let identityFiles = ["identity.seed", "iroh.key", "iroh-peers.json"]

    func clearStorage(keepingIdentity: Bool = false) {
        let dataDir = LushShared.coreDataDirectory()
        do {
            if keepingIdentity {
                let kept = Set(Self.identityFiles)
                for name in try FileManager.default.contentsOfDirectory(atPath: dataDir.path)
                where !kept.contains(name) {
                    try FileManager.default.removeItem(at: dataDir.appendingPathComponent(name))
                }
                appendSyncEvent("Cleared local storage, kept this device's identity — quitting")
            } else {
                try FileManager.default.removeItem(at: dataDir)
                appendSyncEvent("Cleared local storage — quitting")
            }
        } catch {
            appendSyncEvent("Clear failed: \(error.localizedDescription)")
            return
        }
        #if os(macOS)
        NSApplication.shared.terminate(nil)
        #else
        exit(0)
        #endif
    }

    func loadFolder(url: String) async {
        guard let core else { return }
        do {
            _ = try await Task.detached { [core] in try core.ensureFolder(existingUrl: url) }.value
            refreshNotes()
        } catch {
            appendSyncEvent("Couldn't load folder \(url.suffix(12)): \(error.localizedDescription)")
        }
    }

    func loadContextMeta(url: String) async {
        guard noteRow(for: url).contextMeta == nil,
              !contextMetaLoading.contains(url),
              let core
        else { return }
        contextMetaLoading.insert(url)
        defer { contextMetaLoading.remove(url) }
        guard let json = try? await core.noteSpansJson(url: url) else { return }
        let spans = await Task.detached { SpanNode.decodeList(json) }.value
        let fmt = ISO8601DateFormatter()
        var meta = NoteContextMeta()
        for span in spans {
            guard case .block(let b) = span, b.type == "context" else { continue }
            if let s = (b.attrs["created"] ?? b.attrs["ts"])?.stringValue { meta.created = fmt.date(from: s) }
            meta.location = b.attrs["location"]?.stringValue
            meta.weather = b.attrs["weather"]?.stringValue
            meta.nowPlaying = b.attrs["nowPlaying"]?.stringValue
            break
        }
        noteRow(for: url).contextMeta = meta
    }

    /// Every logline that carries a fix. The indexer reads each note as it
    /// lands and keeps its placed loglines, so this is one query against the
    /// index rather than a walk of the whole collection — and it waits for the
    /// startup crawl, since an early answer would be a short one.
    func noteLocations() async -> [NoteLocation] {
        if core == nil { await start() }
        guard let core else { return [] }
        _ = await waitForStartup()
        let places = await Task.detached { NoteLocation.from(core.notePlaces()) }.value
        return places.filter { node(for: $0.noteUrl) != nil }
    }

    /// Every note the calendar can show on a day of its own, by day. The
    /// indexer keeps each note's logline stamps as it reads it, so this is one
    /// query against the index rather than a walk of the whole collection —
    /// and it waits for the startup crawl, since an early answer would be a
    /// short one. A note kept for a calendar event is left out: it belongs to
    /// that event's row, whether the index has caught up with its link yet or
    /// the link was only just made.
    func noteDays() async -> [Date: [DayNote]] {
        if core == nil { await start() }
        guard let core else { return [:] }
        _ = await waitForStartup()
        let byDay = await Task.detached { DayNote.from(core.noteDays()) }.value
        let linked = Set(CalendarLinks.noteUrlByItem.values)
        return byDay.compactMapValues { notes in
            let kept = notes.filter { node(for: $0.noteUrl) != nil && !linked.contains($0.noteUrl) }
            return kept.isEmpty ? nil : kept
        }
    }

    func documentHistorySummary(url: String) async -> DocumentHistorySummary {
        guard let core else {
            return DocumentHistorySummary(changeCount: 0, heads: [], modified: nil, entries: [], pendingEntries: [])
        }
        let currentHeads = await core.docHeads(url: url)
        let pendingEntries = await Task.detached { core.pendingDocHistory(url: url) }.value
        if let cached = documentHistoryCache[url],
           cached.heads == currentHeads,
           cached.pendingEntries == pendingEntries {
            return cached
        }
        async let entries = Task.detached { core.docHistory(url: url) }.value
        let modifiedSeconds = await Task.detached { core.noteModified(url: url) }.value
        let modified = modifiedSeconds > 0
            ? Date(timeIntervalSince1970: TimeInterval(modifiedSeconds))
            : nil
        let historyEntries = await entries
        let summary = DocumentHistorySummary(
            changeCount: historyEntries.count,
            heads: currentHeads,
            modified: modified,
            entries: historyEntries,
            pendingEntries: pendingEntries
        )
        documentHistoryCache[url] = summary
        return summary
    }

    private var pendingRefreshUrls: Set<String> = []

    /// The core's indexer rewrote this doc's extracted-content row; everything
    /// that feeds on note content reads the row from here, no doc open needed.
    func docIndexed(url: String) {
        scheduleSemanticIndex(url: url)
        scheduleSpotlightIndex(url: url)
    }

    func docChanged(url: String) {
        pads.docChanged(url: url)
        folderNodeCache.removeValue(forKey: url)
        documentHistoryCache.removeValue(forKey: url)
        noteRows[url]?.thumbnail = nil
        metaFetched.remove(url)
        docVersions[url, default: 0] += 1
        notifyNoteObservers(url)
        if let host = draftDocHosts[url] {
            Task { [weak self] in await self?.refreshDrafts(for: host) }
        }
        if url == accountConfigUrl, let core, let configUrl = accountConfigUrl {
            Task { @MainActor [weak self] in
                let state = await Task.detached { core.configState(configUrl: configUrl) }.value
                guard let self, let state else { return }
                self.inboxUrl = state.inbox
                self.calendarFolderUrl = state.calendar
                if state.smart != self.smartNotebooks {
                    self.smartNotebooks = state.smart
                    SmartNotebookStore.save(state.smart)
                }
                self.applyConfigFolderSettings(state.folderSettings)
                if state.packages != self.packageListUrls {
                    self.applyPackageLists(state.packages)
                }
                if state.pinsConfigured, state.pins != self.pinnedUrls {
                    self.applyPinnedUrls(state.pins)
                }
                if state.quickNoteConfigured, state.quickNote != self.quickNoteUrl {
                    self.applyQuickNote(state.quickNote)
                }
                if !state.folders.isEmpty, state.folders != self.rootFolderUrls {
                    self.rootFolderUrls = state.folders
                    self.persistRoots()
                    self.refreshNotes()
                }
            }
        }
        if startupSettled,
           smartNotebooks.contains(where: \.notifyOnChange)
               || folderSettings.values.contains(where: \.notifyOnChange),
           pendingSmartNotebookCheckTask == nil {
            pendingSmartNotebookCheckTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                await self.checkSmartNotebooks()
                self.pendingSmartNotebookCheckTask = nil
            }
        }
        pendingRefreshUrls.insert(url)
        if pendingRefreshTask == nil {
        pendingRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            let urls = self.pendingRefreshUrls
            self.pendingRefreshUrls = []
            let needsFullRefresh = urls.contains(where: {
                $0 == self.folderUrl || self.rootFolderUrls.contains($0)
            })
            if needsFullRefresh {
                // Every prefetched note announces itself, and the roots are in
                // that flood. One walk when the flood ends beats a walk that
                // runs during it.
                if self.startupSettled {
                    self.refreshNotes()
                } else {
                    self.deferredStartupRefresh = true
                }
            } else {
                let treeChanged = urls.contains(where: { self.isFolderInTree($0) })
                if treeChanged { self.buildTree() }
                let known = Set(self.notes.map(\.url))
                let stale = urls.filter { known.contains($0) }
                guard !stale.isEmpty, let core = self.core else {
                    self.writeWidgetSnapshot()
                    return
                }
                let (freshPreviews, freshThumbnails) = await Self.fetchMeta(core: core, urls: Array(stale))
                self.mergeMeta(previews: freshPreviews, thumbnails: freshThumbnails)
                self.metaFetched.formUnion(freshPreviews.keys)
                self.writeWidgetSnapshot()
            }
            self.pendingRefreshTask = nil
        }
        }
    }

    private func isFolderInTree(_ url: String) -> Bool {
        nodeIndex[url] != nil
    }

    @discardableResult
    func createNote(snap: ContextSnapshot? = nil) async -> String? {
        if let folderUrl {
            return await createNote(inFolder: folderUrl, snap: snap)
        }
        guard let core else { return nil }
        let pending = snap != nil && ContextTracker.stampsContext
        let atTop = newNoteAtTop(in: folderUrl)
        do {
            let url = try await Task.detached { [core, snap, pending, atTop] () -> String in
                let url = try core.createNoteDoc(title: "")
                let initial: [SpanNode] = [
                    .block(.creationBlock(snap: snap, pending: pending)),
                    .block(.heading(level: 1)),
                ]
                _ = try? core.updateNoteSpans(url: url, spansJson: SpanNode.encodeList(initial), heads: nil)
                try await core.linkNoteToFolder(noteUrl: url, title: "", atTop: atTop)
                return url
            }.value
            pendingFocusUrl = url
            selectedNoteUrl = url
            refreshNotes()
            return url
        } catch {
            status = "Couldn't create note: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func createNote(inFolder folderUrl: String, snap: ContextSnapshot? = nil) async -> String? {
        guard let core else { return nil }
        let pending = snap != nil && ContextTracker.stampsContext
        let atTop = newNoteAtTop(in: folderUrl)
        do {
            let url = try await Task.detached { [core, folderUrl, snap, pending, atTop] () -> String in
                let url = try core.createNoteIn(folderUrl: folderUrl, title: "", atTop: atTop)
                let initial: [SpanNode] = [
                    .block(.creationBlock(snap: snap, pending: pending)),
                    .block(.heading(level: 1)),
                ]
                _ = try? core.updateNoteSpans(url: url, spansJson: SpanNode.encodeList(initial), heads: nil)
                return url
            }.value
            pendingFocusUrl = url
            selectedNoteUrl = url
            refreshNotes()
            return url
        } catch {
            status = "Couldn't create note: \(error.localizedDescription)"
            return nil
        }
    }

    func createNoteForShortcut(
        title: String? = nil,
        text: String? = nil,
        inFolder folderUrl: String?
    ) async -> String? {
        if core == nil {
            await start()
        }
        guard let core else { return nil }
        let target = folderUrl ?? effectiveInboxUrl ?? self.folderUrl
        guard let target else { return nil }
        let noteTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let noteText = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let atTop = newNoteAtTop(in: target)
        do {
            let url = try await Task.detached {
                let url = try core.createNoteIn(folderUrl: target, title: noteTitle, atTop: atTop)
                var initial: [SpanNode] = [.block(.creationBlock(snap: nil)), .block(.heading(level: 1))]
                if !noteTitle.isEmpty {
                    initial.append(.text(noteTitle, [:]))
                }
                if !noteText.isEmpty {
                    for line in noteText.components(separatedBy: .newlines) {
                        initial.append(.block(.paragraph))
                        if !line.isEmpty { initial.append(.text(line, [:])) }
                    }
                }
                _ = try? core.updateNoteSpans(url: url, spansJson: SpanNode.encodeList(initial), heads: nil)
                return url
            }.value
            pendingFocusUrl = url
            selectedNoteUrl = url
            refreshNotes()
            return url
        } catch {
            status = "Couldn't create note: \(error.localizedDescription)"
            return nil
        }
    }

    func createScript() {
        guard let folderUrl else { return }
        createScript(in: folderUrl)
    }

    func createScript(in folderUrl: String) {
        guard let core else { return }
        Task.detached { [core, weak self, folderUrl] in
            do {
                let url = try core.createScriptIn(folderUrl: folderUrl, name: "")
                await MainActor.run { [weak self] in
                    self?.refreshNotes()
                    self?.selectedNoteUrl = url
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.status = "Couldn't create script: \(error.localizedDescription)"
                }
            }
        }
    }

    func createFileForShortcut(name: String? = nil, inFolder folderUrl: String?) async -> String? {
        if core == nil {
            await start()
        }
        guard let core else { return nil }
        let target = folderUrl ?? effectiveInboxUrl ?? self.folderUrl
        guard let target else { return nil }
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        do {
            let url = try await Task.detached {
                try core.createScriptIn(folderUrl: target, name: name)
            }.value
            refreshNotes()
            selectedNoteUrl = url
            return url
        } catch {
            status = "Couldn't create file: \(error.localizedDescription)"
            return nil
        }
    }

    func importFileForShortcut(
        data: Data,
        name: String,
        fileExtension: String,
        mimeType: String,
        inFolder folderUrl: String?
    ) async -> String? {
        if core == nil {
            await start()
        }
        guard let core else { return nil }
        let target = folderUrl ?? effectiveInboxUrl ?? self.folderUrl
        guard let target else { return nil }
        do {
            let url = try await Task.detached {
                try core.createAssetIn(
                    folderUrl: target,
                    name: name,
                    extension: fileExtension,
                    mimeType: mimeType,
                    data: data
                )
            }.value
            refreshNotes()
            selectedNoteUrl = url
            return url
        } catch {
            status = "Couldn't add file: \(error.localizedDescription)"
            return nil
        }
    }

    func addDocToFolder(url: String, folderUrl: String?) async -> Bool {
        if core == nil {
            await start()
        }
        guard let core else { return false }
        let target = folderUrl ?? effectiveInboxUrl ?? self.folderUrl
        let atTop = newNoteAtTop(in: target)
        do {
            if let target {
                try await Task.detached {
                    try core.linkNoteToFolderIn(
                        folderUrl: target,
                        noteUrl: url,
                        title: "",
                        atTop: atTop
                    )
                }.value
            } else {
                try await core.linkNoteToFolder(noteUrl: url, title: "", atTop: atTop)
            }
            patchworkDocUrls.insert(url)
            UserDefaults.standard.set(Array(patchworkDocUrls), forKey: Self.patchworkDocUrlsKey)
            selectedNoteUrl = url
            refreshNotes()
            return true
        } catch {
            status = "Couldn't add document: \(error.localizedDescription)"
            return false
        }
    }

    func createDictionaryForShortcut(
        json: String,
        name: String?,
        type: String?,
        inFolder folderUrl: String?
    ) async -> String? {
        guard let data = json.data(using: .utf8) else {
            status = "Couldn't create dictionary: the input is not a JSON dictionary"
            return nil
        }
        let jsonValue = try? JSONSerialization.jsonObject(with: data)
        let propertyListValue = try? PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = (jsonValue ?? propertyListValue) as? [String: Any],
              JSONSerialization.isValidJSONObject(dictionary)
        else {
            status = "Couldn't create dictionary: the input is not a JSON dictionary"
            return nil
        }
        if core == nil { await start() }
        guard let core else {
            status = "Couldn't create dictionary: Lush is not ready"
            return nil
        }
        let type = type?.trimmingCharacters(in: .whitespacesAndNewlines)
        let documentType = type?.isEmpty == false ? type : nil
        let metadata = dictionary["@patchwork"] as? [String: Any]
        let requestedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let documentName = requestedName.flatMap { $0.isEmpty ? nil : $0 }
            ?? dictionary["name"] as? String
            ?? dictionary["title"] as? String
            ?? metadata?["title"] as? String
            ?? documentType
            ?? "Dictionary"
        do {
            let url = try await PatchworkScripting.shared.createDictionary(
                dictionary,
                type: documentType
            )
            let target = folderUrl ?? effectiveInboxUrl ?? self.folderUrl
            let atTop = newNoteAtTop(in: target)
            if let target {
                try await Task.detached {
                    try core.linkNoteToFolderIn(
                        folderUrl: target,
                        noteUrl: url,
                        title: documentName,
                        atTop: atTop
                    )
                }.value
            } else {
                try await core.linkNoteToFolder(noteUrl: url, title: documentName, atTop: atTop)
            }
            patchworkDocUrls.insert(url)
            UserDefaults.standard.set(Array(patchworkDocUrls), forKey: Self.patchworkDocUrlsKey)
            selectedNoteUrl = url
            refreshNotes()
            return url
        } catch {
            status = "Couldn't create dictionary: \(error.localizedDescription)"
            return nil
        }
    }

    func deleteNote(_ url: String) {
        guard let core else { return }
        Task { [weak self, core, url] in
            do {
                try await Task.detached { try core.deleteNote(url: url) }.value
            } catch {
                self?.status = "Couldn't delete note: \(error.localizedDescription)"
                return
            }
            guard let self else { return }
            self.purgeNoteState(url)
            Task { [semanticSearch = self.semanticSearch] in await semanticSearch.remove(url: url) }
            Task { [spotlightIndex = self.spotlightIndex] in await spotlightIndex.remove(url: url) }
            self.refreshNotes()
        }
    }

    private func purgeNoteState(_ url: String) {
        semanticIndexTasks[url]?.cancel()
        semanticIndexTasks[url] = nil
        semanticIndexTokens[url] = nil
        spotlightIndexTasks[url]?.cancel()
        spotlightIndexTasks[url] = nil
        spotlightIndexTokens[url] = nil
        spotlightBackfilled.remove(url)
        previewUpdateTasks[url]?.cancel()
        previewUpdateTasks[url] = nil
        previewUpdateTokens[url] = nil
        noteWriteTasks[url]?.cancel()
        noteWriteTasks[url] = nil
        clearRow(url)
        metaFetched.remove(url)
        folderNodeCache.removeValue(forKey: url)
        documentHistoryCache.removeValue(forKey: url)
        snapshotCache = snapshotCache.filter { $0.key.url != url }
        snapshotRecency.removeAll { $0.url == url }
        renderedSnapshotCache = renderedSnapshotCache.filter { $0.key.url != url }
        renderedRecency.removeAll { $0.url == url }
        lastKnownCounts.removeValue(forKey: url)
        if pinnedUrls.contains(url) {
            pinnedUrls.removeAll { $0 == url }
            UserDefaults.standard.set(pinnedUrls, forKey: Self.pinnedKey)
            syncConfigPins()
        }
        childOrder.removeValue(forKey: url)
        for (folder, order) in childOrder where order.contains(url) {
            childOrder[folder] = order.filter { $0 != url }
        }
        if quickNoteUrl == url {
            setQuickNote(nil)
        }
        focus.forgetDocument(url)
        CalendarLinks.set([], for: url)
        if selectedNoteUrl == url { selectedNoteUrl = nil }
    }

    func copyFolderUrl() {
        guard let folderUrl else { return }
        Clipboard.copy(folderUrl)
    }

    static func patchworkUrl(for documentUrl: String) -> String {
        "https://patchwork.inkandswitch.com/#\(documentUrl)"
    }

    func copyPatchworkUrl(for documentUrl: String) {
        Clipboard.copy(Self.patchworkUrl(for: documentUrl))
    }

    func openInPatchwork(_ documentUrl: String) {
        guard let url = URL(string: Self.patchworkUrl(for: documentUrl)) else { return }
        ExternalBrowser.open(url)
    }

    func documentKind(for url: String) async -> String? {
        if core == nil {
            await start()
        }
        guard let core else { return nil }
        return try? await core.documentKind(url: url)
    }

    func rememberPatchworkDocument(_ url: String) {
        patchworkDocUrls.insert(url)
        UserDefaults.standard.set(Array(patchworkDocUrls), forKey: Self.patchworkDocUrlsKey)
    }

    func moveItem(_ url: String, into destination: String) {
        guard let core else { return }
        guard let moving = node(for: url), let from = moving.parentUrl else { return }
        guard from != destination, url != destination else { return }
        guard let target = node(for: destination), target.kind == "folder" else { return }
        Task.detached { [core, weak self, from, destination, url] in
            do {
                try core.moveEntry(fromFolder: from, toFolder: destination, url: url)
                await MainActor.run { [weak self] in self?.refreshNotes() }
            } catch {
                await MainActor.run { [weak self] in
                    self?.status = "Couldn't move: \(error.localizedDescription)"
                }
            }
        }
    }

    private static let childOrderKey = "folderChildOrder"

    var childOrder: [String: [String]] =
        (UserDefaults.standard.object(forKey: "folderChildOrder") as? [String: [String]]) ?? [:] {
        didSet { UserDefaults.standard.set(childOrder, forKey: Self.childOrderKey) }
    }

    func orderedChildren(_ children: [FolderNode], in folderUrl: String) -> [FolderNode] {
        let folders = children.filter { $0.kind == "folder" }
        let notes = children.filter { $0.kind != "folder" }
        guard let order = childOrder[folderUrl], !order.isEmpty else { return folders + notes }
        var byUrl = Dictionary(uniqueKeysWithValues: notes.map { ($0.url, $0) })
        let ordered: [FolderNode] = order.compactMap { byUrl.removeValue(forKey: $0) }
        // Notes the stored order has never seen — made since it was written,
        // or arrived from another device — go wherever new notes go. Pinning
        // them to the end regardless made a folder that had once been dragged
        // into shape ignore the setting.
        let unplaced = notes.filter { byUrl[$0.url] != nil }
        guard !unplaced.isEmpty else { return folders + ordered }
        return folders + (newNoteAtTop(in: folderUrl) ? unplaced + ordered : ordered + unplaced)
    }

    func moveChildren(in folderUrl: String, displayed: [String], from: IndexSet, to: Int) {
        var urls = displayed
        urls.move(fromOffsets: from, toOffset: to)
        childOrder[folderUrl] = urls.filter { node(for: $0)?.kind != "folder" }
    }

    /// Reorders a folder's notes among themselves, leaving whatever else it
    /// holds in the slots it already had. `moveChildren` takes the displayed
    /// list to be the whole folder; the notebook shows only the notes, and
    /// handing that list over would drop a script or a patchwork doc out of
    /// the order entirely.
    func moveNotes(in folderUrl: String, displayed: [String], from: IndexSet, to: Int) {
        var moved = displayed
        moved.move(fromOffsets: from, toOffset: to)
        let shown = Set(displayed)
        let children = orderedChildren(node(for: folderUrl)?.children ?? [], in: folderUrl)
            .filter { $0.kind != "folder" }
        var order: [String] = []
        var index = 0
        for child in children {
            if shown.contains(child.url), index < moved.count {
                order.append(moved[index])
                index += 1
            } else {
                order.append(child.url)
            }
        }
        childOrder[folderUrl] = order
    }

    /// Puts a note straight after another in its folder's order. Unlike
    /// `reorderChild` it does not need the note to be in the tree yet: a note
    /// is created before the walk that will find it has finished, and waiting
    /// for that walk is what makes a new note appear at the bottom and then
    /// jump.
    func placeChild(_ url: String, after targetUrl: String, in folderUrl: String) {
        var urls = orderedChildren(node(for: folderUrl)?.children ?? [], in: folderUrl)
            .filter { $0.kind != "folder" }
            .map(\.url)
        urls.removeAll { $0 == url }
        if let index = urls.firstIndex(of: targetUrl) {
            urls.insert(url, at: index + 1)
        } else {
            urls.append(url)
        }
        childOrder[folderUrl] = urls
    }

    func reorderChild(_ url: String, adjacentTo targetUrl: String, after: Bool) {
        guard url != targetUrl,
              let movingNode = node(for: url),
              let targetNode = node(for: targetUrl),
              movingNode.parentUrl == targetNode.parentUrl,
              let folderUrl = movingNode.parentUrl,
              let folder = node(for: folderUrl),
              let rawChildren = folder.children
        else { return }
        let urls = orderedChildren(rawChildren, in: folderUrl)
            .filter { $0.kind != "folder" }
            .map(\.url)
        childOrder[folderUrl] = reordered(urls, moving: url, adjacentTo: targetUrl, after: after)
    }

    // Editor support -----------------------------------------------------

    private struct LiveWriterBox {
        weak var writer: (any LiveWriter)?
    }

    /// Everything holding an edit behind a debounce, not just the focused
    /// editor. A folder shows many editors at once, the notebook is a writer
    /// in its own right, and each keeps its own debounce for a suspend-time
    /// kill to lose.
    @ObservationIgnored private var liveWriterBoxes: [ObjectIdentifier: LiveWriterBox] = [:]

    /// Keyed and held by the writer itself rather than by anything pointing
    /// at it. A view rebuild can hand a new core the same controller, and
    /// reaching writers through `controller.core` would then flush the new
    /// core twice and the old one — the one still holding the edit — never.
    func registerLiveWriter(_ writer: any LiveWriter) {
        liveWriterBoxes[ObjectIdentifier(writer)] = LiveWriterBox(writer: writer)
    }

    func unregisterLiveWriter(_ id: ObjectIdentifier) {
        liveWriterBoxes[id] = nil
    }

    /// Focused editor first: if the suspend window closes early, the note
    /// being typed in is the one that had to reach disk.
    var liveWriters: [any LiveWriter] {
        var seen: Set<ObjectIdentifier> = []
        var result: [any LiveWriter] = []
        if let core = activeEditor?.core {
            seen.insert(ObjectIdentifier(core))
            result.append(core)
        }
        for box in liveWriterBoxes.values {
            guard let writer = box.writer,
                  seen.insert(ObjectIdentifier(writer)).inserted
            else { continue }
            result.append(writer)
        }
        return result
    }

    func pushLiveEditors() {
        for writer in liveWriters { writer.pushNow() }
    }

    private var memoryPressureSource: DispatchSourceMemoryPressure?

    /// Under memory pressure the core evicts every unpinned doc's in-memory
    /// state right away; pinned editor sessions and the folder root stay.
    private func watchMemoryPressure() {
        guard memoryPressureSource == nil, let core else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { core.trimMemory() }
        source.activate()
        memoryPressureSource = source
    }

    /// Keep a note's doc resident while an editor holds it. Counted in the
    /// core, so every pin needs a matching `unpinNote`. Operations on one url
    /// are chained: an unpin can never overtake the open it is balancing.
    private var pinChains: [String: Task<Void, Never>] = [:]

    func pinNote(_ url: String) {
        chainPinOperation(url) { core in try? await core.openNote(url: url) }
    }

    func unpinNote(_ url: String) {
        chainPinOperation(url) { core in try? core.closeNote(url: url) }
    }

    private func chainPinOperation(_ url: String, _ op: @escaping (Core) async -> Void) {
        guard url.hasPrefix("automerge:") else { return }
        let previous = pinChains[url]
        let task = Task { [weak self] in
            await previous?.value
            if self?.core == nil { await self?.start() }
            guard let core = self?.core else { return }
            await op(core)
        }
        pinChains[url] = task
        Task { [weak self] in
            await task.value
            if self?.pinChains[url] == task { self?.pinChains[url] = nil }
        }
    }

    func spansJSON(for url: String) async -> String {
        if core == nil {
            await start()
        }
        guard let core else { return "[]" }
        try? await core.openNote(url: url)
        defer { try? core.closeNote(url: url) }
        return (try? await core.noteSpansJson(url: url)) ?? "[]"
    }

    func spansSnapshot(for url: String) async -> NoteSpansSnapshot? {
        if core == nil {
            await start()
        }
        guard let core else { return nil }
        let start = Date()
        try? await core.openNote(url: url)
        defer { try? core.closeNote(url: url) }
        guard let snapshot = try? await core.noteSpansSnapshot(url: url),
              !snapshot.heads.isEmpty
        else {
            Self.bootLog("note snapshot empty ms=\(Int(Date().timeIntervalSince(start) * 1000))")
            return nil
        }
        Self.bootLog("note snapshot loaded from core ms=\(Int(Date().timeIntervalSince(start) * 1000))")
        return snapshot
    }

    private func cacheSnapshot(_ snapshot: NoteSpansSnapshot, for url: String) {
        guard !snapshot.heads.isEmpty else { return }
        let key = HistorySnapshotKey(url: url, heads: snapshot.heads)
        snapshotCache[key] = snapshot
        snapshotRecency.removeAll { $0 == key }
        snapshotRecency.append(key)
        while snapshotRecency.count > Self.snapshotCacheCapacity {
            snapshotCache.removeValue(forKey: snapshotRecency.removeFirst())
        }
    }

    func spansSnapshot(for url: String, heads: [String]) async -> NoteSpansSnapshot {
        if core == nil {
            await start()
        }
        if !heads.isEmpty {
            let key = HistorySnapshotKey(url: url, heads: heads)
            if let cached = snapshotCache[key] {
                return cached
            }
        }
        guard let core else { return NoteSpansSnapshot(spansJson: "[]", heads: heads) }
        try? await core.openNote(url: url)
        defer { try? core.closeNote(url: url) }
        let snapshot: NoteSpansSnapshot
        if heads.isEmpty {
            snapshot = (try? await core.noteSpansSnapshot(url: url))
                ?? NoteSpansSnapshot(spansJson: "[]", heads: [])
        } else {
            snapshot = await Task.detached {
                (try? await core.noteSpansSnapshotAt(url: url, heads: heads))
                    ?? NoteSpansSnapshot(spansJson: "[]", heads: heads)
            }.value
        }
        cacheSnapshot(snapshot, for: url)
        return snapshot
    }

    #if os(macOS)
    func renderedSnapshot(for url: String, heads: [String]) async -> NSAttributedString {
        if !heads.isEmpty {
            let key = HistorySnapshotKey(url: url, heads: heads)
            if let cached = renderedSnapshotCache[key] {
                return cached
            }
        }
        let snapshot = await spansSnapshot(for: url, heads: heads)
        let key = HistorySnapshotKey(url: url, heads: snapshot.heads)
        if let cached = renderedSnapshotCache[key] {
            return cached
        }
        let spans = await Task.detached {
            SpanNode.decodeList(snapshot.spansJson)
        }.value
        let cache = await snapshotAssetCache(for: spans)
        let attributed = RichText.attributed(from: spans, cache: cache)
        if !snapshot.heads.isEmpty {
            renderedSnapshotCache[key] = attributed
            renderedRecency.removeAll { $0 == key }
            renderedRecency.append(key)
            while renderedRecency.count > Self.snapshotCacheCapacity {
                renderedSnapshotCache.removeValue(forKey: renderedRecency.removeFirst())
            }
        }
        return attributed
    }

    private func snapshotAssetCache(for spans: [SpanNode]) async -> AssetCache {
        let urls = Set(spans.compactMap { span -> String? in
            guard case .block(let block) = span,
                  block.isEmbedBlock,
                  let url = block.embedUrl,
                  url.hasPrefix("automerge:")
            else { return nil }
            return url
        })
        let assets = await withTaskGroup(
            of: (String, Data?, AssetInfo?).self,
            returning: [(String, Data?, AssetInfo?)].self
        ) { group in
            for url in urls {
                group.addTask { [weak self] in
                    guard let self else { return (url, nil, nil) }
                    async let data = self.assetBytes(url)
                    async let info = self.assetInfo(url)
                    return await (url, data, info)
                }
            }
            var assets: [(String, Data?, AssetInfo?)] = []
            for await asset in group {
                assets.append(asset)
            }
            return assets
        }
        let cache = AssetCache()
        for (url, data, info) in assets {
            if let data, cache.storeImage(data, for: url) != nil { continue }
            if let info, !info.name.isEmpty {
                cache.names[url] = info.name
            } else if data == nil {
                cache.patchworkDocs.insert(url)
            }
        }
        return cache
    }

    /// The snapshot with `.amChanged` stamped on paragraphs that differ from
    /// the entry's parent version, for the history viewer's change bars.
    func renderedSnapshot(for url: String, entry: DocHistoryEntry) async -> NSAttributedString {
        let base = await renderedSnapshot(for: url, heads: entry.heads)
        guard !entry.deps.isEmpty else { return base }
        let parentSnapshot = await spansSnapshot(for: url, heads: entry.deps)
        let parentSpans = await Task.detached {
            SpanNode.decodeList(parentSnapshot.spansJson)
        }.value
        let parentText = RichText.attributed(from: parentSpans, cache: AssetCache()).string

        func paragraphs(of text: String) -> (ranges: [NSRange], texts: [String]) {
            let ns = text as NSString
            var ranges: [NSRange] = []
            var texts: [String] = []
            var location = 0
            while location < ns.length {
                let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
                if range.length == 0 { break }
                ranges.append(range)
                texts.append(ns.substring(with: range))
                location = NSMaxRange(range)
            }
            return (ranges, texts)
        }

        let current = paragraphs(of: base.string)
        let parent = paragraphs(of: parentText).texts
        let marked = NSMutableAttributedString(attributedString: base)
        for change in current.texts.difference(from: parent) {
            guard case .insert(let offset, _, _) = change, offset < current.ranges.count else { continue }
            marked.addAttribute(.amChanged, value: true, range: current.ranges[offset])
        }
        return marked
    }
    #endif

    func revertNote(_ url: String, to heads: [String]) async {
        let snapshot = await spansSnapshot(for: url, heads: heads)
        let spans = await Task.detached { SpanNode.decodeList(snapshot.spansJson) }.value
        let title = RichText.title(from: spans)
        await updateDocument(url, json: snapshot.spansJson, title: title)
    }

    // MARK: drafts

    /// The url the editor should open for `url`: the checked-out draft's
    /// clone when one exists, otherwise the doc itself.
    func resolvedNoteUrl(_ url: String) -> String {
        guard let draftUrl = checkedOutDrafts[url],
              let draft = draftLists[url]?.drafts.first(where: { $0.url == draftUrl }),
              let clone = draft.cloneUrl
        else { return url }
        return clone
    }

    func draftName(_ draftUrl: String, in host: String) -> String? {
        draftLists[host]?.drafts.first { $0.url == draftUrl }?.displayName
    }

    /// The editor is handed a clone url and knows nothing about drafts, so it
    /// asks the other way round.
    func checkedOutDraftName(forClone url: String) -> String? {
        for (host, draftUrl) in checkedOutDrafts
        where draftLists[host]?.drafts.first(where: { $0.url == draftUrl })?.cloneUrl == url {
            return draftName(draftUrl, in: host)
        }
        return nil
    }

    /// A read-only automerge url pinned at `heads` (`automerge:<id>#…`).
    func pinnedUrl(_ url: String, heads: [String]) -> String? {
        guard let core, !heads.isEmpty else { return nil }
        return try? core.pinnedDocUrl(url: url, heads: heads)
    }

    /// This device's `CheckedOutDraft` doc for `host` — patchwork's
    /// ephemeral checkout/checkpoint state, served to the webview's draft
    /// overlay so it can pin nested docs while scrubbing. One per
    /// (device, host), reused across launches; never shared between devices.
    private func ensureCheckoutDoc(for host: String) async -> String? {
        if let existing = checkoutDocs[host] { return existing }
        if let inFlight = checkoutDocCreation[host] { return await inFlight.value }
        guard let core else { return nil }
        let task = Task { [weak self] () -> String? in
            let url = await Task.detached { try? core.createCheckoutDoc() }.value
            guard let self else { return url }
            if let url {
                self.checkoutDocs[host] = url
                UserDefaults.standard.set(self.checkoutDocs, forKey: "lushDraftCheckoutDocs")
            }
            self.checkoutDocCreation[host] = nil
            return url
        }
        checkoutDocCreation[host] = task
        return await task.value
    }

    /// Write checkout + per-member checkpoint pins (mimi's DraftCheckpoint:
    /// `at[original] = {from, to}`, both the pinned change hash). Writes are
    /// chained per host so a scrub drag can't land out of order.
    func setDraftCheckpoint(host: String, pins: [CheckpointPin]?) async {
        guard let core, let checkoutUrl = await ensureCheckoutDoc(for: host) else { return }
        let checkedOut = checkedOutDrafts[host]
        let previous = checkoutWriteTasks[host]
        let task = Task {
            await previous?.value
            _ = await Task.detached {
                try? core.setCheckoutState(url: checkoutUrl, checkedOut: checkedOut, pins: pins)
            }.value
        }
        checkoutWriteTasks[host] = task
        await task.value
    }

    func refreshDrafts(for host: String) async {
        guard let core else { return }
        let (state, unresolved) = await Task.detached { () -> (DraftListState, [String]) in
            guard let mainUrl = (try? core.mainDraftUrl(docUrl: host)) ?? nil else {
                return (DraftListState(), [])
            }
            guard let main = (try? core.draftState(url: mainUrl)) ?? nil else {
                return (DraftListState(mainDraftUrl: mainUrl), [mainUrl])
            }
            var drafts: [DraftInfo] = []
            var unresolved: [String] = []
            var queue = main.drafts
            var seen: Set<String> = [mainUrl]
            while !queue.isEmpty {
                let url = queue.removeFirst()
                guard seen.insert(url).inserted else { continue }
                guard let draft = (try? core.draftState(url: url)) ?? nil else {
                    unresolved.append(url)
                    continue
                }
                guard draft.mergedAt == nil else { continue }
                let clone = draft.clones.first(where: { $0.originalUrl == host })
                let members = draft.clones
                    .filter { $0.cloneUrl != $0.originalUrl }
                    .map { DraftMemberInfo(
                        originalUrl: $0.originalUrl,
                        cloneUrl: $0.cloneUrl,
                        clonedAt: $0.clonedAt
                    ) }
                drafts.append(DraftInfo(
                    url: url,
                    name: draft.name,
                    cloneUrl: clone?.cloneUrl,
                    clonedAt: clone?.clonedAt,
                    members: members
                ))
                queue.append(contentsOf: draft.drafts)
            }
            return (DraftListState(mainDraftUrl: mainUrl, drafts: drafts), unresolved)
        }.value
        if draftLists[host] != state { draftLists[host] = state }
        if let mainUrl = state.mainDraftUrl { draftDocHosts[mainUrl] = host }
        for draft in state.drafts {
            draftDocHosts[draft.url] = host
            for member in draft.members {
                draftCloneOrigins[member.cloneUrl] = member.originalUrl
            }
        }
        // docs we couldn't read yet: pull them in; docChanged retries the refresh
        if !unresolved.isEmpty {
            for url in unresolved { draftDocHosts[url] = host }
            core.prefetchNotes(urls: unresolved)
        }
        if let checked = checkedOutDrafts[host],
           !state.drafts.contains(where: { $0.url == checked }) {
            checkedOutDrafts[host] = nil
        }
    }

    @discardableResult
    func createDraft(for host: String) async -> String? {
        guard let core else { return nil }
        let draftUrl = await Task.detached { () -> String? in
            do {
                let mainUrl: String
                if let existing = try core.mainDraftUrl(docUrl: host) {
                    mainUrl = existing
                } else {
                    mainUrl = try core.createDraftDoc(parentUrl: host, isMain: true)
                    try core.setMainDraftUrl(docUrl: host, draftUrl: mainUrl)
                }
                let draftUrl = try core.createDraftDoc(parentUrl: mainUrl, isMain: false)
                try core.draftAddChild(draftUrl: mainUrl, childUrl: draftUrl)
                return draftUrl
            } catch {
                return nil
            }
        }.value
        await refreshDrafts(for: host)
        return draftUrl
    }

    func createDraftAt(for host: String, heads: [String]) async -> String? {
        guard let draftUrl = await createDraft(for: host) else { return nil }
        guard let draft = draftLists[host]?.drafts.first(where: { $0.url == draftUrl }),
              let cloneUrl = draft.cloneUrl else { return draftUrl }
        await revertNote(cloneUrl, to: heads)
        return draftUrl
    }

    /// A draft clone carries the origin's whole history; the card timeline
    /// only wants activity since the fork.
    func draftEntries(cloneUrl: String, since: [String]) async -> [DocHistoryEntry] {
        guard let core else { return [] }
        return await Task.detached {
            core.docHistorySince(url: cloneUrl, heads: since)
        }.value
    }

    /// Checking out lazily forks the host into the draft on first visit,
    /// exactly like patchwork's overlay resolver.
    func checkOutDraft(_ draftUrl: String?, for host: String) async {
        guard let draftUrl else {
            checkedOutDrafts[host] = nil
            await setDraftCheckpoint(host: host, pins: nil)
            return
        }
        guard let core else { return }
        let ready = await Task.detached { () -> Bool in
            do {
                if let state = try core.draftState(url: draftUrl),
                   state.clones.contains(where: { $0.originalUrl == host }) {
                    return true
                }
                let clone = try await core.cloneDoc(url: host)
                try core.draftRecordClone(
                    draftUrl: draftUrl,
                    originalUrl: host,
                    cloneUrl: clone.cloneUrl,
                    clonedAt: clone.clonedAt
                )
                return true
            } catch {
                return false
            }
        }.value
        guard ready else { return }
        await refreshDrafts(for: host)
        checkedOutDrafts[host] = draftUrl
        await setDraftCheckpoint(host: host, pins: nil)
    }

    func renameDraft(_ draftUrl: String, name: String?) async {
        guard let core else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = await Task.detached {
            try? core.draftSetName(draftUrl: draftUrl, name: trimmed?.isEmpty == false ? trimmed : nil)
        }.value
        if let host = draftDocHosts[draftUrl] {
            await refreshDrafts(for: host)
        }
    }

    func mergeDraft(_ draftUrl: String, for host: String) async {
        guard let core else { return }
        let merged = await Task.detached { () -> Bool in
            do {
                guard let state = try core.draftState(url: draftUrl) else { return false }
                for entry in state.clones
                where entry.cloneUrl != entry.originalUrl && entry.mergedAt == nil {
                    let heads = try await core.mergeDoc(intoUrl: entry.originalUrl, fromUrl: entry.cloneUrl)
                    try core.draftRecordMerge(
                        draftUrl: draftUrl,
                        originalUrl: entry.originalUrl,
                        mergedAt: heads
                    )
                }
                try core.draftMarkMerged(
                    draftUrl: draftUrl,
                    timestampMs: Int64(Date().timeIntervalSince1970 * 1000)
                )
                return true
            } catch {
                return false
            }
        }.value
        guard merged else { return }
        checkedOutDrafts[host] = nil
        await setDraftCheckpoint(host: host, pins: nil)
        docChanged(url: host)
        await refreshDrafts(for: host)
    }

    /// Non-nil `heads` makes the core apply the snapshot as-of those heads
    /// (fork + merge when the doc has moved on), so a stale full-document
    /// save no longer stomps concurrent remote edits. Returns the doc's
    /// heads after the change.
    @discardableResult
    func updateSpans(_ url: String, json: String, heads: [String]? = nil) async -> [String]? {
        guard let core else { return nil }
        let newHeads = await Task.detached { () -> [String]? in
            try? core.updateNoteSpans(url: url, spansJson: json, heads: heads)
        }.value
        if let newHeads {
            cacheSnapshot(NoteSpansSnapshot(spansJson: json, heads: newHeads), for: url)
        }
        async let previewTask = core.notePreview(url: url)
        async let titleTask = core.noteTitle(url: url)
        let (preview, title) = await (previewTask, titleTask)
        setPreview(url, preview)
        #if os(macOS)
        if url == selectedNoteUrl { updateDockTilePreview() }
        #endif
        scheduleSemanticIndex(url: url, name: title)
        return newHeads
    }

    @discardableResult
    func updateDocument(
        _ url: String,
        json: String,
        title: String,
        heads: [String]? = nil,
        origin: UUID? = nil
    ) async -> [String]? {
        let previous = noteWriteTasks[url]
        let task = Task { [weak self] () -> [String]? in
            _ = await previous?.value
            let newHeads = await self?.updateSpans(url, json: json, heads: heads)
            await self?.updateTitleIfNeeded(url, title: title)
            self?.notifyNoteObservers(url, excluding: origin)
            return newHeads
        }
        noteWriteTasks[url] = task
        return await task.value
    }

    func spliceNoteText(
        _ url: String,
        index: UInt64,
        deleteCount: Int64,
        insert text: String,
        title: String,
        spansJson: String?,
        heads: [String],
        origin: UUID? = nil
    ) async -> [String]? {
        let previous = noteWriteTasks[url]
        let task = Task { [weak self] () -> [String]? in
            _ = await previous?.value
            guard let self, let core = self.core else { return nil }
            let name = title.isEmpty ? "Untitled" : title
            let newHeads = await Task.detached { () -> [String]? in
                do {
                    return try core.spliceNoteText(
                        url: url,
                        index: index,
                        deleteCount: deleteCount,
                        insert: text,
                        title: name,
                        heads: heads
                    )
                } catch {
                    // keep typing; the next snapshot save can repair this
                    return nil
                }
            }.value
            guard let newHeads else { return nil }
            self.scheduleSemanticIndex(url: url, name: name)
            self.schedulePreviewUpdate(url: url)
            await self.updateTitleIfNeeded(url, title: title)
            return newHeads
        }
        noteWriteTasks[url] = task
        return await task.value
    }

    func applyNoteMark(
        _ url: String,
        start: UInt64,
        end: UInt64,
        name: String,
        valueJson: String?,
        title: String,
        spansJson: String,
        heads: [String],
        origin: UUID? = nil
    ) async -> [String]? {
        let previous = noteWriteTasks[url]
        let task = Task { [weak self] () -> [String]? in
            _ = await previous?.value
            guard let self, let core = self.core else { return nil }
            let noteTitle = title.isEmpty ? "Untitled" : title
            let newHeads = await Task.detached { () -> [String]? in
                do {
                    return try core.applyNoteMark(
                        url: url,
                        start: start,
                        end: end,
                        name: name,
                        valueJson: valueJson,
                        title: noteTitle,
                        heads: heads
                    )
                } catch {
                    // keep editing; the next snapshot save can repair this
                    return nil
                }
            }.value
            guard let newHeads else { return nil }
            self.schedulePreviewUpdate(url: url)
            self.scheduleSemanticIndex(url: url, name: noteTitle)
            await self.updateTitleIfNeeded(url, title: title)
            return newHeads
        }
        noteWriteTasks[url] = task
        return await task.value
    }

    /// A quoted phrase means the user wants that text and nothing like it, so
    /// the semantic pass sits out.
    func search(_ query: String, in scope: String? = nil) async -> [SearchHit] {
        guard let core, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let syntax = SearchSyntax(query)
        // Anything still in the tree, which is what a smart notebook counts
        // too. `notes` is only the open folder's own entries, so using it here
        // quietly threw away every hit that lived anywhere else.
        if Task.isCancelled { return [] }
        let liveUrls = notebookTree.kinds
        var allowed: Set<String>?
        var metadata: [IndexedNote] = []
        if !syntax.clauses.isEmpty || syntax.text.isEmpty {
            let tree = notebookTree
            metadata = await indexedCorpus().filter { note in
                guard liveUrls[note.url] != nil, note.kind != "folder", syntax.matches(note) else { return false }
                return scope.map { tree.contains(note.url, under: $0) } ?? true
            }
            allowed = Set(metadata.map(\.url))
        }
        if syntax.text.isEmpty {
            return metadata.map {
                SearchHit(url: $0.url, name: $0.title, snippet: "")
            }
        }
        let filter = SearchFilter(scope: scope, tags: [], whenFrom: nil, whenTo: nil)
        let exact = await Task.detached { core.searchNotes(query: syntax.text, filter: filter) }.value
            .filter { liveUrls[$0.url] != nil && (allowed?.contains($0.url) ?? true) }
        if Task.isCancelled { return [] }
        if syntax.text.contains("\"") { return exact }
        let seen = Set(exact.map(\.url))
        return await exact + semanticSearch.search(syntax.text, excluding: seen, in: scope)
            .filter { liveUrls[$0.url] != nil && (allowed?.contains($0.url) ?? true) }
    }

    /// Notes the index has never seen — everything else is kept current by
    /// docChanged and the edit paths, so a refresh must not re-embed the world.
    private func backfillSemanticIndex(for notes: [NoteInfo]) {
        Task { [weak self, semanticSearch] in
            let known = await semanticSearch.contextIndexedUrls()
            guard let self else { return }
            for note in notes where !known.contains(note.url) {
                self.scheduleSemanticIndex(url: note.url, name: note.name)
            }
            await self.reindexCalendarNotes(notes)
        }
    }

    /// Notes about calendar items index the event's date, place and calendar
    /// alongside the text, so a note about a meeting last month is findable
    /// long after it left the Calendar view.
    ///
    /// The event links are read back out of the notes first. They live in
    /// UserDefaults, which doesn't sync, so on a second device the only record
    /// of them is the calendar-event blocks in the notes themselves — and a
    /// note whose blocks arrived while the app was closed is never re-indexed.
    private func reindexCalendarNotes(_ notes: [NoteInfo]) async {
        guard !calendarNotesReindexed else { return }
        calendarNotesReindexed = true
        await rebuildCalendarLinks(notes)
        for url in CalendarLinks.noteUrls {
            scheduleSemanticIndex(url: url)
            scheduleSpotlightIndex(url: url)
        }
    }

    private func rebuildCalendarLinks(_ notes: [NoteInfo]) async {
        guard let core else { return }
        let urls = notes.map(\.url)
        let known = CalendarLinks.scannedHeads
        let (links, heads) = await Task.detached {
            [core, urls, known] () -> ([String: [String]], [String: String]) in
            var links: [String: [String]] = [:]
            var heads: [String: String] = [:]
            for url in urls {
                let current = await core.docHeads(url: url).sorted().joined(separator: ",")
                if !current.isEmpty, known[url] == current { continue }
                try? await core.openNote(url: url)
                defer { try? core.closeNote(url: url) }
                guard let json = try? await core.noteSpansJson(url: url) else { continue }
                let ids = CalendarLinks.eventIds(in: SpanNode.decodeList(json))
                if !ids.isEmpty { links[url] = ids }
                heads[url] = current
            }
            return (links, heads)
        }.value
        CalendarLinks.replace(links, scanned: Set(heads.keys), heads: heads)
    }

    private func backfillFileSemanticIndex(for files: [NoteInfo]) {
        Task { [weak self, semanticSearch] in
            let known = await semanticSearch.indexedUrls()
            guard let self else { return }
            for file in files where !known.contains(file.url) {
                self.scheduleFileSemanticIndex(url: file.url, name: file.name)
            }
        }
    }

    private func scheduleFileSemanticIndex(url: String, name: String? = nil) {
        semanticIndexTasks[url]?.cancel()
        let token = UUID()
        semanticIndexTokens[url] = token
        semanticIndexTasks[url] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await self?.indexFileSemantically(url: url, name: name, token: token)
            guard let self, self.semanticIndexTokens[url] == token else { return }
            self.semanticIndexTasks[url] = nil
            self.semanticIndexTokens[url] = nil
        }
    }

    private func indexFileSemantically(url: String, name: String?, token: UUID) async {
        guard let core else { return }
        let (resolvedName, text) = await Task.detached {
            let n = name ?? core.assetInfo(url: url)?.name ?? ""
            var parts: [String] = [n]
            if let vision = core.assetVision(url: url) {
                if !vision.description.isEmpty { parts.append(vision.description) }
                if !vision.ocr.isEmpty { parts.append(vision.ocr) }
            }
            if let ml = core.assetMl(url: url) {
                if !ml.summary.isEmpty { parts.append(ml.summary) }
                if !ml.caption.isEmpty { parts.append(ml.caption) }
                if !ml.keywords.isEmpty { parts.append(ml.keywords) }
            }
            return (n, parts.joined(separator: "\n"))
        }.value
        guard semanticIndexTokens[url] == token, !Task.isCancelled else { return }
        await semanticSearch.indexFile(url: url, name: resolvedName, text: text)
    }

    /// Only notes this launch hasn't queued yet — docChanged keeps changed
    /// notes current, so a refresh must not re-index the whole corpus.
    private func backfillSpotlightIndex(for notes: [NoteInfo]) {
        for note in notes where !spotlightBackfilled.contains(note.url) {
            spotlightBackfilled.insert(note.url)
            scheduleSpotlightIndex(url: note.url, name: note.name)
        }
    }

    private func scheduleSemanticIndex(url: String, name: String? = nil) {
        semanticIndexTasks[url]?.cancel()
        let token = UUID()
        semanticIndexTokens[url] = token
        semanticIndexTasks[url] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await self?.indexSemantically(url: url, name: name, token: token)
            guard let self, self.semanticIndexTokens[url] == token else { return }
            self.semanticIndexTasks[url] = nil
            self.semanticIndexTokens[url] = nil
        }
    }

    private func indexSemantically(url: String, name: String?, token: UUID) async {
        guard let core else { return }
        guard let row = await core.noteContent(url: url), row.kind == "rich" else { return }
        guard semanticIndexTokens[url] == token, !Task.isCancelled else { return }
        CalendarLinks.set(row.eventIds, for: url)
        let resolvedName = row.title.isEmpty
            ? (name ?? node(for: url)?.displayName ?? "")
            : row.title
        await semanticSearch.index(
            url: url,
            name: resolvedName,
            body: row.body,
            context: row.context
        )
    }

    private func scheduleSpotlightIndex(url: String, name: String? = nil) {
        spotlightIndexTasks[url]?.cancel()
        let token = UUID()
        spotlightIndexTokens[url] = token
        spotlightIndexTasks[url] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            await self?.indexForSpotlight(url: url, name: name, token: token)
            guard let self, self.spotlightIndexTokens[url] == token else { return }
            self.spotlightIndexTasks[url] = nil
            self.spotlightIndexTokens[url] = nil
        }
    }

    private func indexForSpotlight(url: String, name: String?, token: UUID) async {
        guard let core else { return }
        guard let row = await core.noteContent(url: url), row.kind == "rich" else { return }
        guard spotlightIndexTokens[url] == token, !Task.isCancelled else { return }
        let resolvedName = row.title.isEmpty
            ? (name ?? node(for: url)?.displayName ?? "")
            : row.title
        await spotlightIndex.index(
            url: url,
            title: resolvedName,
            body: row.body,
            eventStart: row.eventStart > 0 ? Date(timeIntervalSince1970: TimeInterval(row.eventStart)) : nil,
            eventEnd: row.eventEnd > 0 ? Date(timeIntervalSince1970: TimeInterval(row.eventEnd)) : nil
        )
    }

    private func schedulePreviewUpdate(url: String) {
        previewUpdateTasks[url]?.cancel()
        let token = UUID()
        previewUpdateTokens[url] = token
        previewUpdateTasks[url] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self, let core = self.core else { return }
            let preview = await core.notePreview(url: url)
            guard !Task.isCancelled, self.previewUpdateTokens[url] == token else { return }
            self.setPreview(url, preview)
            #if os(macOS)
            if url == self.selectedNoteUrl { self.updateDockTilePreview() }
            #endif
            self.previewUpdateTasks[url] = nil
            self.previewUpdateTokens[url] = nil
        }
    }

    func createAsset(
        data: Data,
        name: String,
        fileExtension: String,
        mimeType: String
    ) async -> String? {
        guard let core else { return nil }
        return await Task.detached {
            try? core.createAsset(
                name: name,
                extension: fileExtension,
                mimeType: mimeType,
                data: data
            )
        }.value
    }

    func assetBytes(_ url: String) async -> Data? {
        guard let core else { return nil }
        return try? await core.assetBytes(url: url)
    }

    func updateAssetVision(_ url: String, description: String, ocr: String) async {
        guard let core else { return }
        await Task.detached {
            try? await core.updateAssetVision(url: url, description: description, ocr: ocr)
        }.value
        scheduleFileSemanticIndex(url: url)
    }

    func updateAssetML(_ url: String, summary: String, caption: String, keywords: String) async {
        guard let core else { return }
        await Task.detached {
            try? await core.updateAssetMl(url: url, summary: summary, caption: caption, keywords: keywords)
        }.value
        scheduleFileSemanticIndex(url: url)
    }

    func assetInfo(_ url: String) async -> AssetInfo? {
        guard let core else { return nil }
        return await Task.detached {
            core.assetInfo(url: url)
        }.value
    }

    func assetVision(_ url: String) async -> AssetVision? {
        guard let core else { return nil }
        return await Task.detached {
            core.assetVision(url: url)
        }.value
    }

    func assetML(_ url: String) async -> AssetMl? {
        guard let core else { return nil }
        return await Task.detached {
            core.assetMl(url: url)
        }.value
    }

    @discardableResult
    func generateAssetML(
        _ url: String,
        name fallbackName: String? = nil,
        choice: ModelChoice? = nil
    ) async -> AssetMl? {
        let info = await assetInfo(url)
        let name = fallbackName ?? info?.name ?? "attachment"
        var vision = await assetVision(url)
        if vision == nil {
            vision = await analyzeAssetVision(url)
        }
        let evidence = AssetMLEvidence(
            name: name,
            kind: AssetCache.kind(forName: name),
            description: vision?.description ?? "",
            text: vision?.ocr ?? ""
        )
        let operation: LocalModelOperation = evidence.kind == "audio"
            ? .voiceNoteSummary
            : .attachmentSummary
        guard let result = try? await MLAnalyzer.analyze(evidence, operation: operation, choice: choice) else {
            return nil
        }
        await updateAssetML(
            url,
            summary: result.summary,
            caption: result.caption,
            keywords: result.keywords
        )
        return result
    }

    /// Run the vision pass on an asset that has none and store the result.
    /// Assets that arrived by sync were analyzed on whichever device inserted
    /// them, if at all, so anything can be missing it.
    @discardableResult
    func analyzeAssetVision(_ url: String) async -> AssetVision? {
        guard let core else { return nil }
        var vision: AssetVision?
        if let data = await assetBytes(url),
           let result = await VisionAnalyzer.analyze(data) {
            await updateAssetVision(url, description: result.description, ocr: result.ocr)
            vision = AssetVision(description: result.description, ocr: result.ocr)
        }
        await Task.detached { core.markVisionAttempted(url: url) }.value
        return vision
    }

    /// Backfill vision for indexed assets that have none. Runs alongside the
    /// semantic backfill and stops when the core has nothing left to offer.
    /// Parked while the app has no permission to work — every item ends in a
    /// core write, and a write still in flight when the process suspends is
    /// one RunningBoard kills (`0xdead10cc`).
    private func backfillAssetVision() {
        guard visionBackfillTask == nil, visionBackfillAllowed else { return }
        let token = UUID()
        visionBackfillToken = token
        visionBackfillTask = Task { [weak self] in
            defer {
                if let self, self.visionBackfillToken == token {
                    self.visionBackfillTask = nil
                }
            }
            while !Task.isCancelled {
                guard let self, self.visionBackfillAllowed, let core = self.core else { return }
                let urls = await Task.detached { core.assetsWithoutVision(limit: 8) }.value
                if urls.isEmpty { return }
                for url in urls {
                    guard !Task.isCancelled, self.visionBackfillAllowed else { return }
                    await self.analyzeAssetVision(url)
                }
            }
        }
    }

    /// Mirrors the core's `setAppActive`: Swift-driven backfill loops issue
    /// core writes the core's own parking can't see coming.
    func setBackfillActive(_ active: Bool) {
        guard visionBackfillAllowed != active else { return }
        visionBackfillAllowed = active
        if active {
            backfillAssetVision()
        } else {
            visionBackfillTask?.cancel()
            visionBackfillTask = nil
        }
    }

    #if os(macOS)
    var importStatus: String = ""

    func importAppleNotes() async {
        guard let core, let target = folderUrl else { return }
        importStatus = "Reading Apple Notes… (this can take a while)"
        let notes: [AppleNotesImporter.ImportedNote]
        do {
            notes = try await Task.detached { try AppleNotesImporter.fetchNotes() }.value
        } catch {
            importStatus = "Couldn't read Apple Notes: \(error.localizedDescription)"
            return
        }
        guard !notes.isEmpty else {
            importStatus = "No notes found."
            return
        }
        let importFolder: String
        do {
            importFolder = try await Task.detached { [core, target] () -> String in
                if let existing = await core.folderEntriesOf(url: target)
                    .first(where: { $0.kind == "folder" && $0.name == "Apple Notes" })?.url {
                    return existing
                }
                return try core.createSubfolderIn(folderUrl: target, title: "Apple Notes")
            }.value
        } catch {
            importStatus = "Import failed: \(error.localizedDescription)"
            return
        }
        // The subfolders are made by the import, so only the setting for every
        // folder can have an opinion about them.
        let atTop = newNoteAtTop(in: nil)
        let (done, skipped, failed) = await Task.detached { [weak self, atTop] in
            var subfolders: [String: String] = [:]
            for entry in await core.folderEntriesOf(url: importFolder) where entry.kind == "folder" {
                subfolders[entry.name] = entry.url
            }
            var priorNames: [String: Set<String>] = [:]
            var importedKeys: Set<String> = []
            var done = 0, skipped = 0, failed = 0
            for note in notes {
                let folderName = note.folder.isEmpty ? "Notes" : note.folder
                do {
                    let sub: String
                    if let known = subfolders[folderName] {
                        sub = known
                    } else {
                        sub = try core.createSubfolderIn(folderUrl: importFolder, title: folderName)
                        subfolders[folderName] = sub
                    }
                    if priorNames[sub] == nil {
                        priorNames[sub] = Set(await core.folderEntriesOf(url: sub).map(\.name))
                    }
                    let key = "\(sub)\u{1}\(note.name)\u{1}\(Self.stableHash(note.html))"
                    if importedKeys.contains(key) || priorNames[sub]?.contains(note.name) == true {
                        skipped += 1
                        continue
                    }
                    let url = try core.createNoteIn(folderUrl: sub, title: note.name, atTop: atTop)
                    let spans = await MainActor.run { RichTextClipboard.spans(fromHTML: note.html) }
                    if !spans.isEmpty {
                        try core.updateNoteSpansAt(
                            url: url,
                            spansJson: SpanNode.encodeList(spans),
                            timestamp: Int64(note.modified.timeIntervalSince1970)
                        )
                    }
                    importedKeys.insert(key)
                    done += 1
                } catch {
                    failed += 1
                }
                if (done + skipped + failed) % 5 == 0 {
                    let d = done, s = skipped
                    await MainActor.run { [weak self] in
                        self?.importStatus = "Imported \(d), skipped \(s)…"
                    }
                }
            }
            return (done, skipped, failed)
        }.value
        var summary = "Imported \(done) notes"
        if skipped > 0 { summary += ", skipped \(skipped) already imported" }
        if failed > 0 { summary += ", \(failed) failed" }
        importStatus = summary + "."
        refreshNotes()
    }

    private nonisolated static func stableHash(_ s: String) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        for byte in s.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return hash
    }
    #endif

    // Quick note ------------------------------------------------------------

    private static let quickNoteKey = "quickNoteUrl"
    var quickNoteUrl: String? = UserDefaults.standard.string(forKey: quickNoteKey)

    var effectiveQuickNoteUrl: String? { focus.state?.quickNoteUrl ?? quickNoteUrl }

    func setQuickNote(_ url: String?) {
        applyQuickNote(url)
        syncConfigQuickNote()
    }

    private func applyQuickNote(_ url: String?) {
        quickNoteUrl = url
        UserDefaults.standard.set(url, forKey: Self.quickNoteKey)
    }

    private func syncConfigQuickNote() {
        guard let core, let configUrl = accountConfigUrl else { return }
        let url = quickNoteUrl
        let previous = configWriteTasks["quickNote"]
        let task = Task.detached {
            _ = await previous?.value
            try? core.setConfigQuickNote(configUrl: configUrl, url: url)
        }
        configWriteTasks["quickNote"] = task
    }

    /// Appends run inside the per-note write chain so the read-modify-write
    /// can't interleave with an open editor's saves for the same note.
    private func chainedNoteWrite(
        _ url: String,
        _ body: @escaping @MainActor () async -> [String]?
    ) async -> [String]? {
        let previous = noteWriteTasks[url]
        let task = Task { () -> [String]? in
            _ = await previous?.value
            return await body()
        }
        noteWriteTasks[url] = task
        return await task.value
    }

    func appendToQuickNote(_ snippet: String) async -> String? {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return effectiveQuickNoteUrl }
        guard let target = await quickNoteTarget() else { return nil }
        return await append(trimmed, to: target.url, using: target.core) ? target.url : nil
    }

    func appendToNote(_ snippet: String, noteUrl: String) async -> Bool {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if core == nil { await start() }
        guard let core, noteUrl.hasPrefix("automerge:") else { return false }
        return await append(trimmed, to: noteUrl, using: core)
    }

    private func append(_ text: String, to url: String, using core: Core) async -> Bool {
        let written = await chainedNoteWrite(url) {
            try? await core.openNote(url: url)
            defer { try? core.closeNote(url: url) }
            let json = (try? await core.noteSpansJson(url: url)) ?? "[]"
            var spans = SpanNode.decodeList(json)
            if !spans.isEmpty {
                spans.append(.text("\n", [:]))
            }
            spans.append(.text(text, [:]))
            return await Task.detached { () -> [String]? in
                try? core.updateNoteSpans(url: url, spansJson: SpanNode.encodeList(spans), heads: nil)
            }.value
        }
        guard written != nil else {
            status = "Couldn't update note"
            return false
        }
        notifyNoteObservers(url)
        refreshQuickNote(url, core: core)
        return true
    }

    func appendRecordingToQuickNote(
        data: Data,
        transcript: String?,
        state: RecordingSaveState?
    ) async -> (url: String?, state: RecordingSaveState?, succeeded: Bool) {
        let core: Core
        var pending: RecordingSaveState
        if let state {
            guard state.accountUrl == accountConfigUrl else { return (nil, state, false) }
            pending = state
            if state.noteUrl.isEmpty {
                guard let target = await quickNoteTarget() else { return (nil, state, false) }
                core = target.core
                pending.noteUrl = target.url
            } else {
                if self.core == nil { await start() }
                guard state.accountUrl == accountConfigUrl, let currentCore = self.core else {
                    return (nil, state, false)
                }
                core = currentCore
            }
        } else {
            guard let target = await quickNoteTarget() else { return (nil, nil, false) }
            core = target.core
            pending = RecordingSaveState(
                assetUrl: nil,
                name: "recording-\(Int(Date().timeIntervalSince1970)).m4a",
                noteUrl: target.url,
                accountUrl: accountConfigUrl,
                embedded: false
            )
        }
        let url = pending.noteUrl
        let recordingName = pending.name
        do {
            let created = pending.assetUrl == nil
            if pending.assetUrl == nil {
                pending.assetUrl = try await Task.detached {
                    try core.createAsset(
                        name: recordingName,
                        extension: "m4a",
                        mimeType: "audio/mp4",
                        data: data
                    )
                }.value
            }
            guard let assetUrl = pending.assetUrl else { return (nil, pending, false) }
            if created, let transcript, !transcript.isEmpty {
                await updateAssetVision(assetUrl, description: "voice recording", ocr: transcript)
                await generateAssetML(assetUrl, name: recordingName)
            }
            let written = await chainedNoteWrite(url) {
                try? await core.openNote(url: url)
                defer { try? core.closeNote(url: url) }
                let json = (try? await core.noteSpansJson(url: url)) ?? "[]"
                var spans = SpanNode.decodeList(json)
                if spans.contains(where: {
                    guard case .block(let block) = $0 else { return false }
                    return block.isEmbedBlock && block.embedUrl == assetUrl
                }) {
                    return []
                }
                if !spans.isEmpty {
                    spans.append(.text("\n", [:]))
                }
                spans.append(.block(.embed(url: assetUrl)))
                if let transcript, !transcript.isEmpty {
                    spans.append(.text("\n\(transcript)", [:]))
                }
                return await Task.detached { () -> [String]? in
                    try? core.updateNoteSpans(url: url, spansJson: SpanNode.encodeList(spans), heads: nil)
                }.value
            }
            guard written != nil else {
                status = "Couldn't add recording to Quick Note"
                return (nil, pending, false)
            }
            pending.embedded = true
            notifyNoteObservers(url)
            refreshQuickNote(url, core: core)
            return (url, pending, true)
        } catch {
            status = "Couldn't add recording to Quick Note: \(error.localizedDescription)"
            return (nil, pending, false)
        }
    }

    /// The configured quick note's url, creating and configuring one only if
    /// none exists yet.
    func ensureQuickNote() async -> String? {
        await quickNoteTarget()?.url
    }

    private func quickNoteTarget() async -> (core: Core, url: String)? {
        if core == nil {
            await start()
        }
        guard let core else { return nil }
        if let url = effectiveQuickNoteUrl {
            return (core, url)
        }
        let target = effectiveInboxUrl ?? folderUrl
        let atTop = newNoteAtTop(in: target)
        do {
            let url = try await Task.detached {
                if let target {
                    return try core.createNoteIn(
                        folderUrl: target,
                        title: "Quick Note",
                        atTop: atTop
                    )
                }
                let noteUrl = try core.createNoteDoc(title: "Quick Note")
                try await core.linkNoteToFolder(
                    noteUrl: noteUrl,
                    title: "Quick Note",
                    atTop: atTop
                )
                return noteUrl
            }.value
            setQuickNote(url)
            return (core, url)
        } catch {
            status = "Couldn't create Quick Note: \(error.localizedDescription)"
            return nil
        }
    }

    private func refreshQuickNote(_ url: String, core: Core) {
        Task {
            setPreview(url, await core.notePreview(url: url))
            pendingFocusUrl = url
            selectedNoteUrl = url
            scheduleSemanticIndex(url: url)
            scheduleSpotlightIndex(url: url)
            refreshNotes()
        }
    }

    /// Every folder in the tree as (url, "parent / child") choices, skipping
    /// the moving items' own subtrees.
    func folderChoices(excluding excluded: Set<String> = []) -> [(url: String, path: String)] {
        var out: [(String, String)] = []
        func walk(_ nodes: [FolderNode], prefix: String) {
            for node in nodes where node.kind == "folder" {
                if excluded.contains(node.url) { continue }
                let path = prefix.isEmpty
                    ? node.displayName
                    : "\(prefix) / \(node.displayName)"
                out.append((node.url, path))
                walk(node.children ?? [], prefix: path)
            }
        }
        walk(folderTree, prefix: "")
        return out
    }

    /// Every note in the tree as (url, "folder / note") choices.
    func noteChoices() -> [(url: String, path: String)] {
        var out: [(String, String)] = []
        func walk(_ nodes: [FolderNode], prefix: String) {
            for node in nodes {
                let name = node.displayName.isEmpty ? "Untitled" : node.displayName
                let path = prefix.isEmpty ? name : "\(prefix) / \(name)"
                if node.kind == "folder" {
                    walk(node.children ?? [], prefix: path)
                } else {
                    out.append((node.url, path))
                }
            }
        }
        walk(folderTree, prefix: "")
        return out
    }

    // Pins & recents --------------------------------------------------------

    private static let pinnedKey = "pinnedNotes"
    var pinnedUrls: [String] = UserDefaults.standard.stringArray(forKey: pinnedKey) ?? []

    func isPinned(_ url: String) -> Bool {
        pinnedUrls.contains(url)
    }

    func togglePin(_ url: String) {
        if let index = pinnedUrls.firstIndex(of: url) {
            pinnedUrls.remove(at: index)
        } else {
            pinnedUrls.insert(url, at: 0)
        }
        UserDefaults.standard.set(pinnedUrls, forKey: Self.pinnedKey)
        syncConfigPins()
    }

    func movePins(displayed: [String], from: IndexSet, to: Int) {
        var urls = displayed
        urls.move(fromOffsets: from, toOffset: to)
        pinnedUrls = urls + pinnedUrls.filter { !urls.contains($0) }
        UserDefaults.standard.set(pinnedUrls, forKey: Self.pinnedKey)
        syncConfigPins()
    }

    func reorderPin(_ url: String, adjacentTo targetUrl: String, after: Bool) {
        let next = reordered(pinnedUrls, moving: url, adjacentTo: targetUrl, after: after)
        guard next != pinnedUrls else { return }
        pinnedUrls = next
        UserDefaults.standard.set(pinnedUrls, forKey: Self.pinnedKey)
        syncConfigPins()
    }

    private func applyPinnedUrls(_ urls: [String]) {
        pinnedUrls = urls
        UserDefaults.standard.set(urls, forKey: Self.pinnedKey)
    }

    private func syncConfigPins() {
        guard let core, let configUrl = accountConfigUrl else { return }
        let urls = pinnedUrls
        let previous = configWriteTasks["pins"]
        let task = Task.detached {
            _ = await previous?.value
            try? core.setConfigPins(configUrl: configUrl, urls: urls)
        }
        configWriteTasks["pins"] = task
    }

    var pinnedNodes: [FolderNode] {
        pinnedUrls.compactMap { node(for: $0) }
    }

    /// Newest-first, served from the core's search index in one query. Never
    /// read this from a view body — call `refreshRecents` and render `recents`.
    private(set) var recents: [RecentEntry] = []

    func refreshRecents(limit: UInt32 = 100) async {
        guard let core else { return }
        let rows = await Task.detached { core.recentNotes(limit: limit) }.value
        var index: [String: FolderNode] = [:]
        func walk(_ nodes: [FolderNode]) {
            for node in nodes {
                index[node.url] = node
                if let children = node.children { walk(children) }
            }
        }
        walk(folderTree)
        recents = rows.compactMap { row in
            guard let node = index[row.url] else { return nil }
            return RecentEntry(node: node, modified: Date(docTimestamp: row.modified))
        }
        #if os(macOS)
        writeDockMenuSnapshot()
        #endif
    }

    #if os(macOS)
    private func writeDockMenuSnapshot() {
        DockMenuSnapshot(
            recents: recents.prefix(8).map {
                DockMenuRecent(
                    title: $0.node.displayName.isEmpty ? "Untitled" : $0.node.displayName,
                    url: $0.node.url,
                    modified: $0.modified.timeIntervalSince1970
                )
            }
        ).write()
    }

    func updateDockTilePreview() {
        guard let url = selectedNoteUrl else {
            DockTilePreview.clear()
            return
        }
        let title = node(for: url)?.displayName ?? ""
        let body = preview(url)
        guard !title.isEmpty || !body.isEmpty else { return }
        DockTilePreview.update(title: title, body: body)
    }
    #endif

    func updateTitleIfNeeded(_ url: String, title: String) async {
        guard let core else { return }
        let name = title.isEmpty ? "Untitled" : title
        let node = node(for: url)
        guard node?.displayName != name else {
            return
        }
        let parent = node?.parentUrl ?? folderUrl
        await Task.detached {
            if let parent {
                try? core.renameEntry(folderUrl: parent, url: url, title: name)
            } else {
                try? core.renameNote(url: url, title: name)
            }
        }.value
        setPreview(url, await core.notePreview(url: url))
        scheduleSemanticIndex(url: url, name: name)
        refreshNotes()
    }

    // Incoming content (share / open-with) ------------------------------------

    var pendingIncoming: IncomingContent?
    var showingFileImporter = false
    var fileImportRequest: FileImportRequest?

    func importAsNewNote(_ content: IncomingContent, textFilesAsNotes: Bool = importsTextFilesAsNotes) async {
        guard let core else { return }
        do {
            var textSpans: [SpanNode] = []
            var textIndexes: Set<Int> = []
            var importedUrls: [String] = []
            let completed = content.completedHandoffItems

            for (index, payload) in content.flattenedPayloads.enumerated() where !completed.contains(index) {
                switch payload {
                case .text(let text):
                    appendText(text, to: &textSpans)
                    textIndexes.insert(index)
                case .file(let url):
                    if textFilesAsNotes, Self.canImportAsNote(url) {
                        let operationKey = "file-note:\(index)"
                        importedUrls.append(try importFileAsNote(
                            url,
                            core: core,
                            folderUrl: nil,
                            existingUrl: content.handoffCreatedUrl(for: operationKey),
                            didCreate: {
                                content.markHandoffCreatedUrl($0, for: operationKey)
                            }
                        ))
                    } else {
                        importedUrls += try await importFileEntries(
                            from: url,
                            core: core,
                            completedRelativePaths: content.completedHandoffChildren(for: index),
                            didImport: {
                                content.markHandoffChildCompleted(index: index, relativePath: $0)
                            },
                            existingUrl: {
                                content.handoffCreatedUrl(for: "file:\(index):\($0)")
                            },
                            didCreate: { relativePath, url in
                                content.markHandoffCreatedUrl(url, for: "file:\(index):\(relativePath)")
                            }
                        )
                    }
                    guard content.markHandoffItemsCompleted([index]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                case .batch:
                    break
                }
            }

            let textJson = SpanNode.encodeList(textSpans)
            if textJson != "[]" {
                let operationKey = "text:\(textIndexes.sorted().map(String.init).joined(separator: ","))"
                let noteUrl: String
                if let existing = content.handoffCreatedUrl(for: operationKey) {
                    noteUrl = existing
                } else {
                    noteUrl = try core.createNote(
                        title: content.textDisplayTitle,
                        atTop: newNoteAtTop(in: folderUrl)
                    )
                    guard content.markHandoffCreatedUrl(noteUrl, for: operationKey) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                _ = try? core.updateNoteSpans(url: noteUrl, spansJson: textJson, heads: nil)
                importedUrls.insert(noteUrl, at: 0)
                guard content.markHandoffItemsCompleted(textIndexes) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }

            refreshNotes()
            selectedNoteUrl = importedUrls.first
            content.cleanupHandoff()
        } catch {
            status = "Couldn't import: \(error.localizedDescription)"
        }
    }

    private func appendText(_ text: String, to spans: inout [SpanNode]) {
        if !spans.isEmpty {
            spans.append(.text("\n\n", [:]))
        }
        spans.append(.text(text, [:]))
    }

    func drainSharedIntake() async {
        if core == nil {
            await start()
        }
        guard core != nil else { return }
        guard let root = LushShared.container else { return }
        let intake = root.appendingPathComponent("SharedIntake", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: intake,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for entry in entries {
            guard FileManager.default.fileExists(atPath: entry.appendingPathComponent("payload.json").path) else {
                continue
            }
            guard let content = IncomingContent.sharedHandoff(id: entry.lastPathComponent) else {
                try? FileManager.default.removeItem(at: entry)
                continue
            }
            if await importToInbox(content) {
                content.cleanupHandoff()
            }
        }
    }

    @discardableResult
    func importToInbox(_ content: IncomingContent, textFilesAsNotes: Bool = importsTextFilesAsNotes) async -> Bool {
        guard let core else { return false }
        let target = effectiveInboxUrl ?? folderUrl
        var textSpans: [SpanNode] = []
        var textIndexes: Set<Int> = []
        var importedUrls: [String] = []
        var failures: [String] = []
        let completed = content.completedHandoffItems

        for (index, payload) in content.flattenedPayloads.enumerated() where !completed.contains(index) {
            switch payload {
            case .text(let text):
                appendText(text, to: &textSpans)
                textIndexes.insert(index)
            case .file(let url):
                do {
                    if textFilesAsNotes, Self.canImportAsNote(url) {
                        let operationKey = "file-note:\(index)"
                        importedUrls.append(try importFileAsNote(
                            url,
                            core: core,
                            folderUrl: target,
                            existingUrl: content.handoffCreatedUrl(for: operationKey),
                            didCreate: {
                                content.markHandoffCreatedUrl($0, for: operationKey)
                            }
                        ))
                    } else {
                        importedUrls += try await importFileEntries(
                            from: url,
                            core: core,
                            folderUrl: target,
                            completedRelativePaths: content.completedHandoffChildren(for: index),
                            didImport: {
                                content.markHandoffChildCompleted(index: index, relativePath: $0)
                            },
                            existingUrl: {
                                content.handoffCreatedUrl(for: "file:\(index):\($0)")
                            },
                            didCreate: { relativePath, url in
                                content.markHandoffCreatedUrl(url, for: "file:\(index):\(relativePath)")
                            }
                        )
                    }
                    if !content.markHandoffItemsCompleted([index]) {
                        failures.append("\(url.lastPathComponent): couldn't record the completed import")
                    }
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            case .batch:
                break
            }
        }

        let textJson = SpanNode.encodeList(textSpans)
        if textJson != "[]" {
            do {
                let operationKey = "text:\(textIndexes.sorted().map(String.init).joined(separator: ","))"
                let noteUrl: String
                if let existing = content.handoffCreatedUrl(for: operationKey) {
                    noteUrl = existing
                } else {
                    let atTop = newNoteAtTop(in: target)
                    if let target {
                        noteUrl = try core.createNoteIn(
                            folderUrl: target,
                            title: content.textDisplayTitle,
                            atTop: atTop
                        )
                    } else {
                        noteUrl = try core.createNote(
                            title: content.textDisplayTitle,
                            atTop: atTop
                        )
                    }
                    guard content.markHandoffCreatedUrl(noteUrl, for: operationKey) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                _ = try? core.updateNoteSpans(url: noteUrl, spansJson: textJson, heads: nil)
                importedUrls.insert(noteUrl, at: 0)
                if !content.markHandoffItemsCompleted(textIndexes) {
                    failures.append("text: couldn't record the completed import")
                }
            } catch {
                failures.append("text: \(error.localizedDescription)")
            }
        }

        refreshNotes()
        if let first = importedUrls.first {
            selectedNoteUrl = first
        }
        if !failures.isEmpty {
            status = "Import incomplete: \(failures.joined(separator: "; "))"
        }
        return failures.isEmpty
    }

    // File import ------------------------------------------------------------

    static let noteImportExtensions: Set<String> = ["md", "markdown", "mdown", "txt", "text", "rtf"]

    nonisolated static let importAsNotesKey = "importTextFilesAsNotes"

    /// Which end of a folder a new note lands at, for folders that haven't
    /// been told otherwise. Unset means the bottom.
    nonisolated static let newNoteAtTopKey = "newNoteAtTop"

    nonisolated static var importsTextFilesAsNotes: Bool {
        UserDefaults.standard.object(forKey: importAsNotesKey) as? Bool ?? true
    }

    static func canImportAsNote(_ url: URL) -> Bool {
        noteImportExtensions.contains(url.pathExtension.lowercased())
    }

    func prepareFileImport(_ urls: [URL], into folderUrl: String?) {
        guard !urls.isEmpty else { return }
        if urls.contains(where: Self.canImportAsNote) {
            fileImportRequest = FileImportRequest(urls: urls, folderUrl: folderUrl)
        } else {
            Task { await importFiles(urls, into: folderUrl, asNotes: false) }
        }
    }

    @discardableResult
    func importFiles(_ urls: [URL], into folderUrl: String?, asNotes: Bool) async -> [String] {
        guard let core else { return [] }
        let target = folderUrl ?? self.folderUrl
        var imported: [String] = []
        var failures: [String] = []
        for url in urls {
            do {
                if asNotes, Self.canImportAsNote(url) {
                    imported.append(try importFileAsNote(url, core: core, folderUrl: target))
                } else {
                    imported += try await importFileEntries(from: url, core: core, folderUrl: target)
                }
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        refreshNotes()
        if let first = imported.first { selectedNoteUrl = first }
        status = failures.isEmpty
            ? "Imported \(imported.count) item\(imported.count == 1 ? "" : "s")"
            : "Import incomplete: \(failures.joined(separator: "; "))"
        return imported
    }

    private func importFileAsNote(
        _ url: URL,
        core: Core,
        folderUrl: String?,
        existingUrl: String? = nil,
        didCreate: ((String) -> Bool)? = nil
    ) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let title = url.deletingPathExtension().lastPathComponent
        let spans = Self.noteSpans(fromFile: url)
        let noteUrl: String
        if let existingUrl {
            noteUrl = existingUrl
        } else {
            // With no folder of its own the note goes to the one that is open,
            // which is the folder `createNote` links it to.
            let atTop = newNoteAtTop(in: folderUrl ?? self.folderUrl)
            if let folderUrl {
                noteUrl = try core.createNoteIn(folderUrl: folderUrl, title: title, atTop: atTop)
            } else {
                noteUrl = try core.createNote(title: title, atTop: atTop)
            }
            guard didCreate?(noteUrl) ?? true else { throw CocoaError(.fileWriteUnknown) }
        }
        if !spans.isEmpty {
            _ = try? core.updateNoteSpans(url: noteUrl, spansJson: SpanNode.encodeList(spans), heads: nil)
        }
        return noteUrl
    }

    static func noteSpans(fromFile url: URL) -> [SpanNode] {
        if url.pathExtension.lowercased() == "rtf" {
            guard let attributed = try? NSAttributedString(
                url: url,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            ),
            let html = try? attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
            ),
            let text = String(data: html, encoding: .utf8)
            else { return [] }
            return RichTextClipboard.spans(fromHTML: text)
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return RichTextClipboard.spans(fromMarkdown: text)
    }

    private func importFileEntries(
        from url: URL,
        core: Core,
        folderUrl: String? = nil,
        completedRelativePaths: Set<String> = [],
        didImport: ((String) -> Bool)? = nil,
        existingUrl: ((String) -> String?)? = nil,
        didCreate: ((String, String) -> Bool)? = nil
    ) async throws -> [String] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            let files = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )?.compactMap { $0 as? URL } ?? []
            var imported: [String] = []
            for file in files {
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                let relativePath = relativeDisplayName(for: file, under: url)
                guard !completedRelativePaths.contains(relativePath) else { continue }
                imported.append(try await importSingleFileEntry(
                    file,
                    displayName: relativePath,
                    core: core,
                    folderUrl: folderUrl,
                    existingUrl: existingUrl?(relativePath),
                    didCreate: { didCreate?(relativePath, $0) ?? true }
                ))
                guard didImport?(relativePath) ?? true else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            return imported
        }
        return [try await importSingleFileEntry(
            url,
            displayName: url.lastPathComponent,
            core: core,
            folderUrl: folderUrl,
            existingUrl: existingUrl?(url.lastPathComponent),
            didCreate: { didCreate?(url.lastPathComponent, $0) ?? true }
        )]
    }

    private func importSingleFileEntry(
        _ url: URL,
        displayName: String,
        core: Core,
        folderUrl: String? = nil,
        existingUrl: String? = nil,
        didCreate: ((String) -> Bool)? = nil
    ) async throws -> String {
        let ext = url.pathExtension.lowercased()
        let name = displayName.isEmpty ? url.lastPathComponent : displayName
        if let folderUrl {
            if let existingUrl { return existingUrl }
            let data = try Data(contentsOf: url)
            let assetUrl = try core.createAssetIn(
                folderUrl: folderUrl,
                name: name,
                extension: ext.isEmpty ? "bin" : ext,
                mimeType: mimeType(for: ext),
                data: data
            )
            guard didCreate?(assetUrl) ?? true else { throw CocoaError(.fileWriteUnknown) }
            return assetUrl
        }
        let assetUrl: String
        if let existingUrl {
            assetUrl = existingUrl
        } else {
            let data = try Data(contentsOf: url)
            assetUrl = try core.createAsset(
                name: name,
                extension: ext.isEmpty ? "bin" : ext,
                mimeType: mimeType(for: ext),
                data: data
            )
            guard didCreate?(assetUrl) ?? true else { throw CocoaError(.fileWriteUnknown) }
        }
        try await core.linkNoteToFolder(
            noteUrl: assetUrl,
            title: name,
            atTop: newNoteAtTop(in: self.folderUrl)
        )
        return assetUrl
    }

    private func relativeDisplayName(for file: URL, under folder: URL) -> String {
        let folderPath = folder.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(folderPath) else { return file.lastPathComponent }
        return String(filePath.dropFirst(folderPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func mimeType(for ext: String) -> String {
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "pdf": return "application/pdf"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "txt": return "text/plain"
        default: return "application/octet-stream"
        }
    }
}

private final class DelegateBridge: CoreDelegate {
    nonisolated(unsafe) private weak var model: NotesModel?

    init(model: NotesModel) {
        self.model = model
    }

    func onDocChanged(url: String) {
        Task { @MainActor [model] in
            model?.docChanged(url: url)
        }
    }

    func onDocIndexed(url: String) {
        Task { @MainActor [model] in
            model?.docIndexed(url: url)
        }
    }

    func onConnectionChanged(connected: Bool) {
        Task { @MainActor [model] in
            model?.connected = connected
            model?.appendSyncEvent(connected ? "Connected to subduction server" : "Disconnected from subduction server")
        }
    }

    func onSyncEvent(message: String) {
        Task { @MainActor [model] in
            model?.appendSyncEvent(message)
        }
    }

    func onEphemeralMessage(url: String, payload: Data) {
        Task { @MainActor [model] in
            model?.ephemeralMessageReceived(url: url, payload: payload)
        }
    }

    func onPeersChanged() {
        Task { @MainActor [model] in
            model?.refreshPeers()
        }
    }

    func onNotesPrefetched() {
        Task { @MainActor [model] in
            model?.notesPrefetched()
        }
    }

    func onStorageLoaded() {
        Task { @MainActor [model] in
            model?.storageLoaded = true
        }
    }
}

extension NoteInfo: Identifiable {
    public var id: String { url }
}

struct RecentEntry: Identifiable {
    let node: FolderNode
    let modified: Date
    var id: String { node.url }
}


@MainActor
@Observable
final class NoteRow {
    var preview: String = ""
    var thumbnail: Data?
    var contextMeta: NoteContextMeta?
}

struct NoteContextMeta {
    var created: Date?
    var location: String?
    var weather: String?
    var nowPlaying: String?
}

struct DocumentHistorySummary: Equatable {
    var changeCount: Int
    var heads: [String]
    var modified: Date?
    var entries: [DocHistoryEntry]
    var pendingEntries: [DocHistoryEntry]

    var pendingChangeCount: Int { pendingEntries.count }
}

struct DraftMemberInfo: Equatable {
    let originalUrl: String
    let cloneUrl: String
    let clonedAt: [String]
}

struct DraftInfo: Identifiable, Equatable {
    let url: String
    var name: String?
    var cloneUrl: String?
    var clonedAt: [String]?
    var members: [DraftMemberInfo] = []

    var id: String { url }
    var displayName: String { name?.isEmpty == false ? name! : "Draft" }
}

struct DraftListState: Equatable {
    var mainDraftUrl: String?
    var drafts: [DraftInfo] = []
}

struct HistorySnapshotKey: Hashable {
    let url: String
    let heads: [String]

    init(url: String, heads: [String]) {
        self.url = url
        self.heads = heads.sorted()
    }
}

struct FolderNode: Identifiable, Hashable {
    let url: String
    let name: String
    let kind: String
    let parentUrl: String?
    var children: [FolderNode]?

    var id: String { url }
    var isNote: Bool { kind == "lush" || kind == "rich" }
    var isPatchworkDoc: Bool {
        kind != "folder" && kind != "lush" && kind != "rich" && kind != "lush:script"
    }
}
