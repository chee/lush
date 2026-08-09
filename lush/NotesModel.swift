import Foundation
import Observation
import WidgetKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@Observable @MainActor
final class NotesModel {
    static let shared = NotesModel()
    private static let applyIncomingKey = "focusApplyIncoming"
    private static let sendChangesKey = "focusSendChanges"
    private static let presenceKey = "focusPresence"

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

    var focusModeEnabled: Bool {
        !applyingIncomingChanges && !sendingChanges && !sharingPresence
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
                core.setApplyIncoming(enabled: enabled)
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
                core.setSendChanges(enabled: enabled)
                return core.isSendingChanges()
            }.value
            guard let self else { return }
            self.sendingChanges = actual
            self.changingSendingChanges = false
            UserDefaults.standard.set(actual, forKey: Self.sendChangesKey)
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
    private(set) var storageLoaded = false
    private(set) var startupSettled = false
    var irohPeers: [IrohPeer] = []

    func refreshPeers() {
        irohPeers = core?.irohPeers() ?? []
    }
    var selectedNoteUrl: String? {
        didSet {
            UserDefaults.standard.set(selectedNoteUrl, forKey: Self.lastOpenNoteKey)
            saveLaunchSnapshot()
            #if os(macOS)
            updateDockTilePreview()
            #endif
        }
    }
    var pendingFocusUrl: String?
    var status: String = "Starting…"
    var previews: [String: String] = [:]
    private(set) var contextMetas: [String: NoteContextMeta] = [:]
    var rootFolderUrl: String? { rootFolderUrls.first }
    var rootFolderUrls: [String] = []
    var folderTree: [FolderNode] = []
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
    @ObservationIgnored private var spotlightIndexTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var spotlightBackfilled: Set<String> = []
    @ObservationIgnored private var calendarNotesReindexed = false
    private var previewUpdateTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var noteWriteTasks: [String: Task<[String]?, Never>] = [:]
    @ObservationIgnored private var noteObservers: [UUID: @MainActor (String) -> Void] = [:]
    @ObservationIgnored private var delegateBridge: DelegateBridge?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var documentHistoryCache: [String: DocumentHistorySummary] = [:]
    @ObservationIgnored private var snapshotCache: [HistorySnapshotKey: NoteSpansSnapshot] = [:]
    @ObservationIgnored private var renderedSnapshotCache: [HistorySnapshotKey: NSAttributedString] = [:]
    private(set) var thumbnails: [String: Data] = [:]
    @ObservationIgnored private var pendingRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSmartNotebookCheckTask: Task<Void, Never>?
    private var lastKnownCounts: [String: Int] = [:]
    private static let patchworkDocUrlsKey = "patchworkDocUrls"
    private static let launchSnapshotFileName = "LaunchStateSnapshot.json"
    private static let bootStart = Date()
    private(set) var patchworkDocUrls: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: patchworkDocUrlsKey) ?? []
    )
    @ObservationIgnored private var folderNodeCache: [String: (heads: [String], node: FolderNode)] = [:]
    /// Notes whose preview + thumbnail have been read from the core. A refresh
    /// must not re-read the whole tree; docChanged drops the entries it stales.
    @ObservationIgnored private var metaFetched: Set<String> = []
    @ObservationIgnored private var launchNoteSnapshots: [String: NoteSpansSnapshot] = [:]
    @ObservationIgnored private var launchSnapshotOrder: [String] = []
    @ObservationIgnored private var launchSnapshotSaveTask: Task<Void, Never>?
    private static let launchSnapshotNoteCap = 8
    @ObservationIgnored private var visionBackfillTask: Task<Void, Never>?

    init() {
        if let saved = Self.loadLaunchSnapshot() {
            launchNoteSnapshots = saved.noteSnapshots
            launchSnapshotOrder = Array(saved.noteSnapshots.keys)
            selectedNoteUrl = saved.selectedNoteUrl
        }
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
    private static let appGroupIdentifier = "group.party.chee.patchwork.lush"
    private static let widgetSnapshotFileName = "LushWidgetSnapshot.json"
    private static let folderContentWidgetKind = "FolderContentWidget"

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
    private(set) var contactName: String?
    private(set) var contactAvatarData: Data?
    var smartNotebooks: [SmartNotebook] = SmartNotebookStore.load()
    var smartHits: [String: [SearchHit]] = [:]
    @ObservationIgnored var smartHitTasks: [String: Task<Void, Never>] = [:]

    var loggedIn: Bool { accountUrl != nil }

    static func normalizedAccountUrl(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("automerge:") { return trimmed }
        if trimmed.hasPrefix("account:") {
            let rest = trimmed.dropFirst("account:".count)
            guard let id = rest.split(separator: "/").last, !id.isEmpty else { return nil }
            return "automerge:" + id
        }
        return nil
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
        let localDocs = loggedIn ? [] : ([localScratchpad].compactMap { $0 } + CalendarLinks.noteUrls)
        do {
            var state = try await Task.detached {
                try core.loginAccount(accountUrl: normalized)
            }.value
            if !localFolders.isEmpty || !localDocs.isEmpty {
                let account = state.accountUrl
                let merged = await Task.detached { () -> [String]? in
                    try? core.adoptLocalDocs(
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
            await applyAccount(state)
            if let localScratchpad { setQuickNote(localScratchpad) }
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
        contactName = nil
        contactAvatarData = nil
        presenceContactUrl = nil
        presence.leave()
        smartNotebooks = []
        SmartNotebookStore.save([])
        applyPackageLists([])
        setQuickNote(nil)
        rootFolderUrls = []
        persistRoots()
        folderUrl = nil
        refreshNotes()
    }

    private func applyAccount(_ state: AccountState) async {
        accountConfigUrl = state.configUrl
        inboxUrl = state.inbox
        accountModuleSettingsUrl = state.moduleSettingsUrl
        PatchworkWeb.accountModuleUrl = state.moduleSettingsUrl
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
        let info = await Task.detached { core.contactInfo(url: contactUrl) }.value
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

    private static func bootLog(_ message: String) {
        let ms = Int(Date().timeIntervalSince(bootStart) * 1000)
        NSLog("lush boot +%dms %@", ms, message)
    }

    private static func loadLaunchSnapshot() -> NotesLaunchSnapshot? {
        guard let data = try? Data(contentsOf: launchSnapshotURL) else { return nil }
        return try? JSONDecoder().decode(NotesLaunchSnapshot.self, from: data)
    }

    /// Keeps only the last few opened notes' snapshots; boot needs the
    /// last-open note, not every note ever visited.
    private func cacheLaunchSnapshot(_ url: String, _ snapshot: NoteSpansSnapshot) {
        launchNoteSnapshots[url] = snapshot
        launchSnapshotOrder.removeAll { $0 == url }
        launchSnapshotOrder.append(url)
        while launchSnapshotOrder.count > Self.launchSnapshotNoteCap {
            launchNoteSnapshots.removeValue(forKey: launchSnapshotOrder.removeFirst())
        }
    }

    /// Debounced; the encode and write run off the main actor.
    private func saveLaunchSnapshot() {
        launchSnapshotSaveTask?.cancel()
        launchSnapshotSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            let snapshot = NotesLaunchSnapshot(
                rootFolderUrls: self.rootFolderUrls,
                folderUrl: self.folderUrl,
                folderTitle: self.folderTitle,
                selectedNoteUrl: self.selectedNoteUrl,
                notes: self.notes,
                folderTree: self.folderTree,
                previews: self.previews,
                thumbnails: self.thumbnails,
                noteSnapshots: self.launchNoteSnapshots
            )
            let url = Self.launchSnapshotURL
            await Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? data.write(to: url, options: [.atomic])
            }.value
        }
    }

    private static var launchSnapshotURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lush", isDirectory: true)
            .appendingPathComponent(launchSnapshotFileName)
    }

    private func refreshCachedOpenNote(_ url: String) {
        Task { @MainActor [weak self] in
            await self?.start()
            guard let self, let core = self.core else { return }
            try? await core.openNote(url: url)
            let snapshot = (try? await core.noteSpansSnapshot(url: url))
                ?? NoteSpansSnapshot(spansJson: "[]", heads: [])
            self.cacheLaunchSnapshot(url, snapshot)
            self.saveLaunchSnapshot()
            self.notifyNoteObservers(url)
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
        focus.watchSystemFocus()
        Task { await focus.reconcileWithSystemFocus() }
        do {
            let dataDir = LushShared.coreDataDirectory()
            var saved = LushShared.rootFolderUrls
            let core = try await Task.detached {
                try Core(dataDir: dataDir.path, serverUrl: nil)
            }.value
            Self.bootLog("Core constructed")
            self.core = core
            LushAgentServer.shared.start(model: self)
            core.setApplyIncoming(enabled: applyingIncomingChanges)
            core.setSendChanges(enabled: sendingChanges)
            applyingIncomingChanges = core.isApplyingIncoming()
            sendingChanges = core.isSendingChanges()
            PatchworkWeb.coreServerPort = core.localServerPort()
            NativeWebStorage.shared.core = core
            Task { [semanticSearch] in await semanticSearch.attach(core) }
            let delegateBridge = DelegateBridge(model: self)
            self.delegateBridge = delegateBridge
            core.setDelegate(delegate: delegateBridge)
            presence.model = self
            presence.setEnabled(sharingPresence, url: nil)
            connected = core.isConnected()
            Self.bootLog("Core bridged")

            // Determine the priority note — the one we know we're opening —
            // so we can kick off its storage load before the full folder tree.
            let priorityNoteUrl: String? = {
                if case .note(let url) = AppRouter.shared.pending { return url }
                if saved.first != nil {
                    return UserDefaults.standard.string(forKey: Self.lastOpenNoteKey)
                }
                return nil
            }()
            if let last = priorityNoteUrl {
                selectedNoteUrl = last
                // Start loading this note immediately — before refreshNotes fans
                // out across the entire folder tree, so it gets first access to
                // the storage layer and its ensure_doc background-sync task is
                // queued before the flood of others.
                core.prefetchNotes(urls: [last])
            }

            if let first = saved.first {
                // Returning user: set folder immediately and return to the UI.
                // startFolderUrl sets self.folder in Rust and loads the doc
                // from redb in the background; docChanged fires when ready.
                try core.startFolderUrl(url: first)
                Self.bootLog("root folder scheduled for local load")
                rootFolderUrls = saved
                persistRoots()
                folderUrl = first
                status = ""
                core.prefetchNotes(urls: Array(saved.dropFirst()))
                refreshNotes()
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
        guard let core, let url else { return }
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
        UserDefaults.standard.set(Array(patchworkDocUrls), forKey: Self.patchworkDocUrlsKey)
        Task.detached { [core, weak self, url] in
            try? core.linkNoteToFolder(noteUrl: url, title: "")
            await MainActor.run { [weak self] in
                self?.selectedNoteUrl = url
                self?.refreshNotes()
            }
        }
    }

    func removeEntry(parentUrl: String?, url: String) {
        guard let core, let parent = parentUrl ?? folderUrl else { return }
        Task.detached { [core, weak self, parent, url] in
            do {
                try core.removeEntry(folderUrl: parent, url: url)
            } catch {
                print("removeEntry failed: parent=\(parent) url=\(url) error=\(error)")
            }
            await MainActor.run { [weak self] in self?.refreshNotes() }
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
        guard let core else { folderTree = []; return }
        let rootUrls = rootFolderUrls
        let cache = folderNodeCache
        Task.detached { [core, rootUrls, cache, weak self] in
            let (tree, newCache) = await Self.computeTree(core: core, rootFolderUrls: rootUrls, cache: cache)
            guard let self else { return }
            await MainActor.run {
                self.folderTree = tree
                self.folderNodeCache = newCache
                self.writeWidgetSnapshot()
            }
            core.setSearchParents(parents: await self.notebookTree.parents)
        }
    }

    func node(for url: String) -> FolderNode? {
        func find(_ nodes: [FolderNode]) -> FolderNode? {
            for node in nodes {
                if node.url == url { return node }
                if let children = node.children, let found = find(children) {
                    return found
                }
            }
            return nil
        }
        if let found = find(folderTree) { return found }
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
            let openNote = selectedNoteUrl
            await selectFolder(url)
            selectedNoteUrl = openNote
        } else {
            // open instantly; folder retargeting happens behind the scenes
            selectedNoteUrl = url
            if let parent = node.parentUrl {
                core?.refreshFolderEntry(folderUrl: parent, url: url)
                if parent != folderUrl {
                    await selectFolder(parent)
                    selectedNoteUrl = url
                }
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

    func reorderRootFolder(_ url: String, adjacentTo targetUrl: String) {
        guard url != targetUrl,
              let sourceIndex = rootFolderUrls.firstIndex(of: url),
              let targetIndex = rootFolderUrls.firstIndex(of: targetUrl)
        else { return }

        rootFolderUrls.remove(at: sourceIndex)
        let adjustedTargetIndex = rootFolderUrls.firstIndex(of: targetUrl) ?? targetIndex
        let insertionIndex = sourceIndex < targetIndex
            ? min(adjustedTargetIndex + 1, rootFolderUrls.count)
            : adjustedTargetIndex
        rootFolderUrls.insert(url, at: insertionIndex)
        persistRoots()
        syncConfigFolders()
        buildTree()
    }

    func refreshNotes() {
        guard let core else { return }
        let rootUrls = rootFolderUrls
        let cache = folderNodeCache
        let fetched = metaFetched
        Self.bootLog("refreshNotes begin roots=\(rootUrls.count)")
        Task.detached { [core, rootUrls, cache, fetched, weak self] in
            let refreshStart = Date()
            async let notesTask = core.listNotes()
            async let titleTask = core.folderTitle()
            let notes = await notesTask
            let folderTitle = await titleTask
            let (tree, newCache) = await Self.computeTree(core: core, rootFolderUrls: rootUrls, cache: cache)
            let visible = Self.visibleNotes(in: tree)
            let localMs = Int(Date().timeIntervalSince(refreshStart) * 1000)
            core.prefetchNotes(urls: notes.map(\.url))
            // Local load phase is done — now allow the network connection to
            // start. Idempotent: only the first call spawns the connect loop.
            core.connect()
            let richNotes = visible.filter { $0.kind == "rich" }.map {
                NoteInfo(url: $0.url, name: $0.name, kind: $0.kind)
            }
            let urlsNeedingMeta = visible.map(\.url).filter { !fetched.contains($0) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.notes = notes
                self.folderTitle = folderTitle
                self.folderTree = tree
                self.folderNodeCache = newCache
                self.storageLoaded = true
                if let selected = self.selectedNoteUrl, self.node(for: selected) == nil {
                    self.selectedNoteUrl = nil
                }
                self.saveLaunchSnapshot()
                Self.bootLog(
                    "sidebar published notes=\(notes.count) visible=\(visible.count) localMs=\(localMs)"
                )
                self.writeWidgetSnapshot()
            }
            let metaStart = Date()
            let (newPreviews, newThumbnails) = await Self.fetchMeta(
                core: core,
                urls: urlsNeedingMeta
            )
            let metaMs = Int(Date().timeIntervalSince(metaStart) * 1000)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.previews.merge(newPreviews) { _, new in new }
                self.thumbnails.merge(newThumbnails) { _, new in new }
                let liveUrls = Set(visible.map(\.url))
                self.previews = self.previews.filter { liveUrls.contains($0.key) }
                self.thumbnails = self.thumbnails.filter { liveUrls.contains($0.key) }
                self.metaFetched.formUnion(newPreviews.keys)
                self.metaFetched.formIntersection(liveUrls)
                self.contextMetas = self.contextMetas.filter { liveUrls.contains($0.key) }
                let fileNotes = visible.filter { $0.kind == "file" }.map {
                    NoteInfo(url: $0.url, name: $0.name, kind: $0.kind)
                }
                self.backfillSemanticIndex(for: richNotes)
                self.backfillFileSemanticIndex(for: fileNotes)
                self.backfillSpotlightIndex(for: richNotes)
                self.backfillAssetVision()
                self.saveLaunchSnapshot()
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

    func forceSync() {
        guard let core else { return }
        appendSyncEvent("Force sync: resyncing \(rootFolderUrls.count) root folder(s)")
        Task {
            for url in rootFolderUrls {
                let changes = await Task.detached { core.docChangeCount(url: url) }.value
                let entries = await core.folderEntriesOf(url: url).count
                appendSyncEvent("  \(url.suffix(12)): \(entries) entries, \(changes) changes locally")
                await Task.detached { try? core.resyncDoc(url: url) }.value
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

    func syncNow(budget: Duration) async {
        if core == nil { await start() }
        guard let core else { return }
        activeEditor?.core?.pushNow()
        core.connect()
        await drainSharedIntake()
        let urls = rootFolderUrls
        await Task.detached { for url in urls { try? core.resyncDoc(url: url) } }.value

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

    func releaseCore() {
        pollTask?.cancel()
        pollTask = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        activeEditor?.core?.pushNow()
        presence.leave()
        core?.shutdown()
        core = nil
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task.detached { [weak self] in
            var interval: Duration = .seconds(5)
            var elapsed = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
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
                elapsed += Int(interval.components.seconds)
                if elapsed >= 60 { interval = .seconds(30) }
            }
        }
    }

    private func startMaintenancePolling() {
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.folderTree.isEmpty { break }
                try? await Task.sleep(for: .seconds(2))
            }
            // Wait for note docs to finish loading into the Rust search index
            // before allowing smart notebook checks — prevents spurious boot
            // notifications caused by incomplete search results.
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in self?.startupSettled = true }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { break }
                await self.drainSharedIntake()
            }
        }
    }

    func writeWidgetSnapshot() {
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else { return }

        let folders = widgetFolders(from: folderTree)
        let defaultFolderUrl = folderUrl ?? rootFolderUrls.first ?? folders.first?.url
        let url = root.appendingPathComponent(Self.widgetSnapshotFileName)
        let oldData = try? Data(contentsOf: url)
        let oldSnapshot = oldData.flatMap { try? JSONDecoder().decode(LushWidgetSnapshot.self, from: $0) }
        let updatedAt = oldSnapshot?.defaultFolderUrl == defaultFolderUrl && oldSnapshot?.folders == folders
            ? oldSnapshot?.updatedAt ?? Date()
            : Date()
        let snapshot = LushWidgetSnapshot(
            updatedAt: updatedAt,
            defaultFolderUrl: defaultFolderUrl,
            folders: folders
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        guard oldData != data else { return }

        do {
            try data.write(to: url, options: .atomic)
            WidgetCenter.shared.reloadTimelines(ofKind: Self.folderContentWidgetKind)
        } catch {
            appendSyncEvent("Widget snapshot failed: \(error.localizedDescription)")
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
                            preview: previews[$0.url] ?? "",
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
        guard contextMetas[url] == nil, let core else { return }
        let json = (try? await core.noteSpansJson(url: url)) ?? "[]"
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
        contextMetas[url] = meta
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

    func docChanged(url: String) {
        pads.docChanged(url: url)
        folderNodeCache.removeValue(forKey: url)
        documentHistoryCache.removeValue(forKey: url)
        thumbnails.removeValue(forKey: url)
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
                if state.smart != self.smartNotebooks {
                    self.smartNotebooks = state.smart
                    SmartNotebookStore.save(state.smart)
                }
                if state.packages != self.packageListUrls {
                    self.applyPackageLists(state.packages)
                }
                if !state.folders.isEmpty, state.folders != self.rootFolderUrls {
                    self.rootFolderUrls = state.folders
                    self.persistRoots()
                    self.refreshNotes()
                }
            }
        }
        if node(for: url)?.isNote == true || notes.contains(where: { $0.url == url && $0.kind == "rich" }) {
            scheduleSemanticIndex(url: url)
            scheduleSpotlightIndex(url: url)
        }
        if startupSettled, smartNotebooks.contains(where: \.notifyOnChange), pendingSmartNotebookCheckTask == nil {
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
                self.refreshNotes()
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
                self.previews.merge(freshPreviews) { _, new in new }
                self.thumbnails.merge(freshThumbnails) { _, new in new }
                self.metaFetched.formUnion(freshPreviews.keys)
                self.saveLaunchSnapshot()
                self.writeWidgetSnapshot()
            }
            self.pendingRefreshTask = nil
        }
        }
    }

    private func isFolderInTree(_ url: String) -> Bool {
        func contains(_ nodes: [FolderNode]) -> Bool {
            for node in nodes {
                if node.url == url { return true }
                if let children = node.children, contains(children) { return true }
            }
            return false
        }
        return contains(folderTree)
    }

    @discardableResult
    func createNote(snap: ContextSnapshot? = nil) async -> String? {
        if let folderUrl {
            return await createNote(inFolder: folderUrl, snap: snap)
        }
        guard let core else { return nil }
        do {
            let url = try await Task.detached { [core, snap] () -> String in
                let url = try core.createNoteDoc(title: "")
                let initial: [SpanNode] = [.block(.creationBlock(snap: snap)), .block(.heading(level: 1))]
                _ = try? core.updateNoteSpans(url: url, spansJson: SpanNode.encodeList(initial), heads: nil)
                try? core.linkNoteToFolder(noteUrl: url, title: "")
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
        do {
            let url = try await Task.detached { [core, folderUrl, snap] () -> String in
                let url = try core.createNoteIn(folderUrl: folderUrl, title: "")
                let initial: [SpanNode] = [.block(.creationBlock(snap: snap)), .block(.heading(level: 1))]
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

    func createNoteForShortcut(inFolder folderUrl: String?) async -> String? {
        if core == nil {
            await start()
        }
        guard let core else { return nil }
        let target = folderUrl ?? effectiveInboxUrl ?? self.folderUrl
        guard let target else { return nil }
        do {
            let url = try await Task.detached {
                let url = try core.createNoteIn(folderUrl: target, title: "")
                let initial: [SpanNode] = [.block(.creationBlock(snap: nil)), .block(.heading(level: 1))]
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

    func createFileForShortcut(inFolder folderUrl: String?) async -> String? {
        if core == nil {
            await start()
        }
        guard let core else { return nil }
        let target = folderUrl ?? effectiveInboxUrl ?? self.folderUrl
        guard let target else { return nil }
        do {
            let url = try await Task.detached {
                try core.createScriptIn(folderUrl: target, name: "")
            }.value
            refreshNotes()
            selectedNoteUrl = url
            return url
        } catch {
            status = "Couldn't create file: \(error.localizedDescription)"
            return nil
        }
    }

    func addDocToFolder(url: String, folderUrl: String?) async {
        if core == nil {
            await start()
        }
        if let folderUrl {
            await selectFolder(folderUrl)
        }
        addDocToCurrentFolder(url: url)
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
        spotlightIndexTasks[url]?.cancel()
        spotlightIndexTasks[url] = nil
        spotlightBackfilled.remove(url)
        previewUpdateTasks[url]?.cancel()
        previewUpdateTasks[url] = nil
        noteWriteTasks[url]?.cancel()
        noteWriteTasks[url] = nil
        previews[url] = nil
        thumbnails[url] = nil
        contextMetas[url] = nil
        metaFetched.remove(url)
        folderNodeCache.removeValue(forKey: url)
        documentHistoryCache.removeValue(forKey: url)
        snapshotCache = snapshotCache.filter { $0.key.url != url }
        renderedSnapshotCache = renderedSnapshotCache.filter { $0.key.url != url }
        launchNoteSnapshots.removeValue(forKey: url)
        launchSnapshotOrder.removeAll { $0 == url }
        lastKnownCounts.removeValue(forKey: url)
        if pinnedUrls.contains(url) {
            pinnedUrls.removeAll { $0 == url }
            UserDefaults.standard.set(pinnedUrls, forKey: Self.pinnedKey)
        }
        childOrder.removeValue(forKey: url)
        for (folder, order) in childOrder where order.contains(url) {
            childOrder[folder] = order.filter { $0 != url }
        }
        if quickNoteUrl == url {
            quickNoteUrl = nil
            UserDefaults.standard.removeObject(forKey: Self.quickNoteKey)
        }
        focus.forgetDocument(url)
        CalendarLinks.set([], for: url)
        if selectedNoteUrl == url { selectedNoteUrl = nil }
        saveLaunchSnapshot()
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
        var ordered: [FolderNode] = order.compactMap { byUrl.removeValue(forKey: $0) }
        ordered += notes.filter { byUrl[$0.url] != nil }
        return folders + ordered
    }

    func reorderChild(_ url: String, before targetUrl: String) {
        guard url != targetUrl,
              let movingNode = node(for: url),
              let targetNode = node(for: targetUrl),
              movingNode.parentUrl == targetNode.parentUrl,
              let folderUrl = movingNode.parentUrl,
              let folder = node(for: folderUrl),
              let rawChildren = folder.children
        else { return }
        var urls = orderedChildren(rawChildren, in: folderUrl)
            .filter { $0.kind != "folder" }
            .map(\.url)
        urls.removeAll { $0 == url }
        guard let targetIndex = urls.firstIndex(of: targetUrl) else { return }
        urls.insert(url, at: targetIndex)
        childOrder[folderUrl] = urls
    }

    // Editor support -----------------------------------------------------

    func spansJSON(for url: String) async -> String {
        if core == nil {
            await start()
        }
        guard let core else { return "[]" }
        try? await core.openNote(url: url)
        return (try? await core.noteSpansJson(url: url)) ?? "[]"
    }

    func spansSnapshot(for url: String) async -> NoteSpansSnapshot {
        if core == nil, let cached = launchNoteSnapshots[url] {
            Self.bootLog("note snapshot served from launch cache")
            refreshCachedOpenNote(url)
            return cached
        }
        if core == nil {
            await start()
        }
        guard let core else { return NoteSpansSnapshot(spansJson: "[]", heads: []) }
        let start = Date()
        try? await core.openNote(url: url)
        let snapshot = (try? await core.noteSpansSnapshot(url: url))
            ?? NoteSpansSnapshot(spansJson: "[]", heads: [])
        cacheLaunchSnapshot(url, snapshot)
        saveLaunchSnapshot()
        Self.bootLog("note snapshot loaded from core ms=\(Int(Date().timeIntervalSince(start) * 1000))")
        return snapshot
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
        if !snapshot.heads.isEmpty {
            snapshotCache[HistorySnapshotKey(url: url, heads: snapshot.heads)] = snapshot
        }
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
        let attributed = RichText.attributed(from: spans, cache: AssetCache())
        if !snapshot.heads.isEmpty {
            renderedSnapshotCache[key] = attributed
        }
        return attributed
    }

    func renderedCurrentSnapshot(for url: String) async -> NSAttributedString {
        let snapshot = await spansSnapshot(for: url)
        let spans = await Task.detached { SpanNode.decodeList(snapshot.spansJson) }.value
        return RichText.attributed(from: spans, cache: AssetCache())
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
                let clone = try core.cloneDoc(url: host)
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
                    let heads = try core.mergeDoc(intoUrl: entry.originalUrl, fromUrl: entry.cloneUrl)
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
        async let previewTask = core.notePreview(url: url)
        async let titleTask = core.noteTitle(url: url)
        async let snapshotTask = core.noteSpansSnapshot(url: url)
        let (preview, title, snapshot) = await (previewTask, titleTask, try? snapshotTask)
        previews[url] = preview
        #if os(macOS)
        if url == selectedNoteUrl { updateDockTilePreview() }
        #endif
        cacheLaunchSnapshot(url, snapshot ?? NoteSpansSnapshot(spansJson: json, heads: newHeads ?? []))
        saveLaunchSnapshot()
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
        let liveUrls = Set(notes.map(\.url))
        let filter = SearchFilter(scope: scope, tags: [], whenFrom: nil, whenTo: nil)
        let exact = await Task.detached { core.searchNotes(query: query, filter: filter) }.value
            .filter { liveUrls.contains($0.url) }
        if Task.isCancelled { return [] }
        if query.contains("\"") { return exact }
        let seen = Set(exact.map(\.url))
        return await exact + semanticSearch.search(query, excluding: seen, in: scope)
            .filter { liveUrls.contains($0.url) }
    }

    /// Notes the index has never seen — everything else is kept current by
    /// docChanged and the edit paths, so a refresh must not re-embed the world.
    private func backfillSemanticIndex(for notes: [NoteInfo]) {
        Task { [weak self, semanticSearch] in
            let known = await semanticSearch.indexedUrls()
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
        let links = await Task.detached { [core, urls] () -> [String: [String]] in
            var links: [String: [String]] = [:]
            for url in urls {
                try? await core.openNote(url: url)
                guard let json = try? await core.noteSpansJson(url: url) else { continue }
                let ids = CalendarLinks.eventIds(in: SpanNode.decodeList(json))
                if !ids.isEmpty { links[url] = ids }
            }
            return links
        }.value
        CalendarLinks.replace(links, scanned: Set(urls))
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
        semanticIndexTasks[url] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await self?.indexFileSemantically(url: url, name: name)
        }
    }

    private func indexFileSemantically(url: String, name: String?) async {
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
        await semanticSearch.indexFile(url: url, name: resolvedName, text: text)
        semanticIndexTasks[url] = nil
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
        semanticIndexTasks[url] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await self?.indexSemantically(url: url, name: name)
        }
    }

    private func indexSemantically(url: String, name: String?) async {
        guard let core else { return }
        var resolvedName = name ?? node(for: url)?.displayName
        if resolvedName == nil { resolvedName = await core.noteTitle(url: url) }
        try? await core.openNote(url: url)
        let json = (try? await core.noteSpansJson(url: url)) ?? "[]"
        let eventIds = await Task.detached { CalendarLinks.eventIds(in: SpanNode.decodeList(json)) }.value
        CalendarLinks.set(eventIds, for: url)
        await semanticSearch.index(url: url, name: resolvedName ?? "", spansJson: json)
        semanticIndexTasks[url] = nil
    }

    private func scheduleSpotlightIndex(url: String, name: String? = nil) {
        spotlightIndexTasks[url]?.cancel()
        spotlightIndexTasks[url] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            await self?.indexForSpotlight(url: url, name: name)
        }
    }

    private func indexForSpotlight(url: String, name: String?) async {
        guard let core else { return }
        var resolvedName = name ?? node(for: url)?.displayName
        if resolvedName == nil { resolvedName = await core.noteTitle(url: url) }
        try? await core.openNote(url: url)
        let json = (try? await core.noteSpansJson(url: url)) ?? "[]"
        await spotlightIndex.index(url: url, title: resolvedName ?? "", spansJson: json)
        spotlightIndexTasks[url] = nil
    }

    private func schedulePreviewUpdate(url: String) {
        previewUpdateTasks[url]?.cancel()
        previewUpdateTasks[url] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self, let core = self.core else { return }
            let preview = await core.notePreview(url: url)
            guard !Task.isCancelled else { return }
            self.previews[url] = preview
            #if os(macOS)
            if url == self.selectedNoteUrl { self.updateDockTilePreview() }
            #endif
            self.previewUpdateTasks[url] = nil
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
            try? core.updateAssetVision(url: url, description: description, ocr: ocr)
        }.value
        scheduleFileSemanticIndex(url: url)
    }

    func updateAssetML(_ url: String, summary: String, caption: String, keywords: String) async {
        guard let core else { return }
        await Task.detached {
            try? core.updateAssetMl(url: url, summary: summary, caption: caption, keywords: keywords)
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
        defer { core.markVisionAttempted(url: url) }
        guard let data = await assetBytes(url),
              let result = await VisionAnalyzer.analyze(data)
        else { return nil }
        await updateAssetVision(url, description: result.description, ocr: result.ocr)
        return AssetVision(description: result.description, ocr: result.ocr)
    }

    /// Backfill vision for indexed assets that have none. Runs alongside the
    /// semantic backfill and stops when the core has nothing left to offer.
    private func backfillAssetVision() {
        guard visionBackfillTask == nil else { return }
        visionBackfillTask = Task { [weak self] in
            defer { self?.visionBackfillTask = nil }
            while !Task.isCancelled {
                guard let self, let core = self.core else { return }
                let urls = await Task.detached { core.assetsWithoutVision(limit: 8) }.value
                if urls.isEmpty { return }
                for url in urls {
                    guard !Task.isCancelled else { return }
                    await self.analyzeAssetVision(url)
                }
            }
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
        let (done, skipped, failed) = await Task.detached { [weak self] in
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
                    let url = try core.createNoteIn(folderUrl: sub, title: note.name)
                    let spans = await MainActor.run { AppleNotesImporter.spans(fromHTML: note.html) }
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
        quickNoteUrl = url
        UserDefaults.standard.set(url, forKey: Self.quickNoteKey)
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
        let core = target.core
        let url = target.url
        let written = await chainedNoteWrite(url) {
            try? await core.openNote(url: url)
            let json = (try? await core.noteSpansJson(url: url)) ?? "[]"
            var spans = SpanNode.decodeList(json)
            if !spans.isEmpty {
                spans.append(.text("\n", [:]))
            }
            spans.append(.text(trimmed, [:]))
            return await Task.detached { () -> [String]? in
                try? core.updateNoteSpans(url: url, spansJson: SpanNode.encodeList(spans), heads: nil)
            }.value
        }
        guard written != nil else {
            status = "Couldn't update Quick Note"
            return nil
        }
        notifyNoteObservers(url)
        refreshQuickNote(url, core: core)
        return url
    }

    func appendRecordingToQuickNote(data: Data, transcript: String?) async -> String? {
        guard let target = await quickNoteTarget() else { return nil }
        let core = target.core
        let url = target.url
        let timestamp = Int(Date().timeIntervalSince1970)
        let name = "recording-\(timestamp).m4a"
        do {
            let assetUrl = try await Task.detached {
                try core.createAsset(
                    name: name,
                    extension: "m4a",
                    mimeType: "audio/mp4",
                    data: data
                )
            }.value
            if let transcript, !transcript.isEmpty {
                await updateAssetVision(assetUrl, description: "voice recording", ocr: transcript)
                await generateAssetML(assetUrl, name: name)
            }
            let written = await chainedNoteWrite(url) {
                try? await core.openNote(url: url)
                let json = (try? await core.noteSpansJson(url: url)) ?? "[]"
                var spans = SpanNode.decodeList(json)
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
                return nil
            }
            notifyNoteObservers(url)
            refreshQuickNote(url, core: core)
            return url
        } catch {
            status = "Couldn't add recording to Quick Note: \(error.localizedDescription)"
            return nil
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
        do {
            let url = try await Task.detached {
                if let target {
                    return try core.createNoteIn(folderUrl: target, title: "Quick Note")
                }
                let noteUrl = try core.createNoteDoc(title: "Quick Note")
                try? core.linkNoteToFolder(noteUrl: noteUrl, title: "Quick Note")
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
            previews[url] = await core.notePreview(url: url)
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
    }

    func reorderPin(_ url: String, adjacentTo targetUrl: String) {
        guard url != targetUrl,
              let source = pinnedUrls.firstIndex(of: url),
              let target = pinnedUrls.firstIndex(of: targetUrl)
        else { return }
        pinnedUrls.remove(at: source)
        let adjusted = pinnedUrls.firstIndex(of: targetUrl) ?? target
        pinnedUrls.insert(url, at: source < target ? min(adjusted + 1, pinnedUrls.count) : adjusted)
        UserDefaults.standard.set(pinnedUrls, forKey: Self.pinnedKey)
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
            // older docs recorded milliseconds
            var seconds = TimeInterval(row.modified)
            if seconds > 4_000_000_000 { seconds /= 1000 }
            return RecentEntry(node: node, modified: Date(timeIntervalSince1970: seconds))
        }
        #if os(macOS)
        writeDockMenuSnapshot()
        #endif
    }

    #if os(macOS)
    private func writeDockMenuSnapshot() {
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.party.chee.patchwork.lush"
        ) else { return }
        let snapshot = DockMenuSnapshot(
            recents: recents.prefix(8).map {
                DockMenuRecent(
                    title: $0.node.displayName.isEmpty ? "Untitled" : $0.node.displayName,
                    url: $0.node.url,
                    modified: $0.modified.timeIntervalSince1970
                )
            }
        )
        let url = root.appendingPathComponent("DockMenuSnapshot.json")
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func updateDockTilePreview() {
        guard let url = selectedNoteUrl else {
            DockTilePreview.clear()
            return
        }
        let title = node(for: url)?.displayName ?? ""
        let body = previews[url] ?? ""
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
        previews[url] = await core.notePreview(url: url)
        scheduleSemanticIndex(url: url, name: name)
        refreshNotes()
    }

    // Incoming content (share / open-with) ------------------------------------

    var pendingIncoming: IncomingContent?
    var showingFileImporter = false

    func importAsNewNote(_ content: IncomingContent, textFilesAsNotes: Bool = importsTextFilesAsNotes) {
        guard let core else { return }
        do {
            var textSpans: [SpanNode] = []
            var importedUrls: [String] = []

            for payload in content.flattenedPayloads {
                switch payload {
                case .text(let text):
                    appendText(text, to: &textSpans)
                case .file(let url):
                    if textFilesAsNotes, Self.canImportAsNote(url) {
                        importedUrls.append(try importFileAsNote(url, core: core, folderUrl: nil))
                    } else {
                        importedUrls += try importFileEntries(from: url, core: core)
                    }
                case .batch:
                    break
                }
            }

            let textJson = SpanNode.encodeList(textSpans)
            if textJson != "[]" {
                let noteUrl = try core.createNote(title: content.textDisplayTitle)
                _ = try? core.updateNoteSpans(url: noteUrl, spansJson: textJson, heads: nil)
                importedUrls.insert(noteUrl, at: 0)
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
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedHandoff.appGroupIdentifier
        ) else { return }
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
            importToInbox(content)
        }
    }

    func importToInbox(_ content: IncomingContent, textFilesAsNotes: Bool = importsTextFilesAsNotes) {
        guard let core else { return }
        defer { content.cleanupHandoff() }
        let target = effectiveInboxUrl ?? folderUrl
        var textSpans: [SpanNode] = []
        var importedUrls: [String] = []
        var failures: [String] = []

        for payload in content.flattenedPayloads {
            switch payload {
            case .text(let text):
                appendText(text, to: &textSpans)
            case .file(let url):
                do {
                    if textFilesAsNotes, Self.canImportAsNote(url) {
                        importedUrls.append(try importFileAsNote(url, core: core, folderUrl: target))
                    } else {
                        importedUrls += try importFileEntries(from: url, core: core, folderUrl: target)
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
                let noteUrl: String
                if let target {
                    noteUrl = try core.createNoteIn(folderUrl: target, title: content.textDisplayTitle)
                } else {
                    noteUrl = try core.createNote(title: content.textDisplayTitle)
                }
                _ = try? core.updateNoteSpans(url: noteUrl, spansJson: textJson, heads: nil)
                importedUrls.insert(noteUrl, at: 0)
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
    }

    // File import ------------------------------------------------------------

    static let noteImportExtensions: Set<String> = ["md", "markdown", "mdown", "txt", "text", "rtf"]

    nonisolated static let importAsNotesKey = "importTextFilesAsNotes"

    nonisolated static var importsTextFilesAsNotes: Bool {
        UserDefaults.standard.object(forKey: importAsNotesKey) as? Bool ?? true
    }

    static func canImportAsNote(_ url: URL) -> Bool {
        noteImportExtensions.contains(url.pathExtension.lowercased())
    }

    @discardableResult
    func importFiles(_ urls: [URL], into folderUrl: String?, asNotes: Bool) -> [String] {
        guard let core else { return [] }
        let target = folderUrl ?? self.folderUrl
        var imported: [String] = []
        var failures: [String] = []
        for url in urls {
            do {
                if asNotes, Self.canImportAsNote(url) {
                    imported.append(try importFileAsNote(url, core: core, folderUrl: target))
                } else {
                    imported += try importFileEntries(from: url, core: core, folderUrl: target)
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

    private func importFileAsNote(_ url: URL, core: Core, folderUrl: String?) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let title = url.deletingPathExtension().lastPathComponent
        let spans = Self.noteSpans(fromFile: url)
        let noteUrl: String
        if let folderUrl {
            noteUrl = try core.createNoteIn(folderUrl: folderUrl, title: title)
        } else {
            noteUrl = try core.createNote(title: title)
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

    private func importFileEntries(from url: URL, core: Core, folderUrl: String? = nil) throws -> [String] {
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
                imported.append(try importSingleFileEntry(file, displayName: relativeDisplayName(for: file, under: url), core: core, folderUrl: folderUrl))
            }
            return imported
        }
        return [try importSingleFileEntry(url, displayName: url.lastPathComponent, core: core, folderUrl: folderUrl)]
    }

    private func importSingleFileEntry(
        _ url: URL,
        displayName: String,
        core: Core,
        folderUrl: String? = nil
    ) throws -> String {
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()
        let name = displayName.isEmpty ? url.lastPathComponent : displayName
        if let folderUrl {
            return try core.createAssetIn(
                folderUrl: folderUrl,
                name: name,
                extension: ext.isEmpty ? "bin" : ext,
                mimeType: mimeType(for: ext),
                data: data
            )
        }
        let assetUrl = try core.createAsset(
            name: name,
            extension: ext.isEmpty ? "bin" : ext,
            mimeType: mimeType(for: ext),
            data: data
        )
        try core.linkNoteToFolder(noteUrl: assetUrl, title: name)
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
}

extension NoteInfo: Identifiable, Codable {
    public var id: String { url }

    private enum CodingKeys: String, CodingKey {
        case url, name, kind
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            url: try container.decode(String.self, forKey: .url),
            name: try container.decode(String.self, forKey: .name),
            kind: try container.decode(String.self, forKey: .kind)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
    }
}

extension NoteSpansSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case spansJson, heads
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            spansJson: try container.decode(String.self, forKey: .spansJson),
            heads: try container.decode([String].self, forKey: .heads)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(spansJson, forKey: .spansJson)
        try container.encode(heads, forKey: .heads)
    }
}

private struct NotesLaunchSnapshot: Codable {
    let rootFolderUrls: [String]
    let folderUrl: String?
    let folderTitle: String
    let selectedNoteUrl: String?
    let notes: [NoteInfo]
    let folderTree: [FolderNode]
    let previews: [String: String]
    let thumbnails: [String: Data]
    let noteSnapshots: [String: NoteSpansSnapshot]
}

struct RecentEntry: Identifiable {
    let node: FolderNode
    let modified: Date
    var id: String { node.url }
}

#if os(macOS)
struct DockMenuSnapshot: Codable {
    let recents: [DockMenuRecent]
}

struct DockMenuRecent: Codable {
    let title: String
    let url: String
    let modified: TimeInterval
}
#endif

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

struct FolderNode: Identifiable, Hashable, Codable {
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
