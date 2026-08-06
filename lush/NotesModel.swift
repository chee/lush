import Foundation
import Observation
import WidgetKit
#if os(macOS)
import AppKit
#endif

@Observable @MainActor
final class NotesModel {
    static let shared = NotesModel()

    private(set) var core: Core?
    var notes: [NoteInfo] = []
    /// The sidebar search query, mirrored here so the editor can tint the
    /// matches inside an opened note.
    var searchQuery = ""
    /// The frontmost note's editor, for inspector tabs that talk to it.
    weak var activeEditor: EditorController?
    let presence = PresenceManager()
    /// The logged-in account's contact doc url — the presence identity key.
    private(set) var presenceContactUrl: String?

    func ephemeralMessageReceived(url: String, payload: Data) {
        presence.receive(url: url, payload: payload)
    }
    var folderUrl: String?
    var folderTitle: String = ""
    var connected = false
    var selectedNoteUrl: String? {
        didSet {
            UserDefaults.standard.set(selectedNoteUrl, forKey: Self.lastOpenNoteKey)
            saveLaunchSnapshot()
        }
    }
    var pendingFocusUrl: String?
    var status: String = "Starting…"
    var previews: [String: String] = [:]
    private(set) var contextMetas: [String: NoteContextMeta] = [:]
    var rootFolderUrl: String? { rootFolderUrls.first }
    var rootFolderUrls: [String] = []
    var folderTree: [FolderNode] = []
    private(set) var syncLog: [String] = []

    func appendSyncEvent(_ message: String) {
        let ts = Date().formatted(.dateTime.hour().minute().second())
        let entry = "[\(ts)] \(message)"
        if syncLog.count >= 100 { syncLog.removeFirst() }
        syncLog.append(entry)
    }
    private let semanticSearch = SemanticSearchIndex()
    private let spotlightIndex = SpotlightIndex()
    private var semanticIndexTasks: [String: Task<Void, Never>] = [:]
    private var previewUpdateTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var noteWriteTasks: [String: Task<[String]?, Never>] = [:]
    @ObservationIgnored private var noteObservers: [UUID: @MainActor (String) -> Void] = [:]
    @ObservationIgnored private var delegateBridge: DelegateBridge?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var documentHistoryCache: [String: DocumentHistorySummary] = [:]
    @ObservationIgnored private var snapshotCache: [HistorySnapshotKey: NoteSpansSnapshot] = [:]
    @ObservationIgnored private var renderedSnapshotCache: [HistorySnapshotKey: NSAttributedString] = [:]
    private(set) var thumbnails: [String: Data] = [:]
    @ObservationIgnored private var pendingRefreshTask: Task<Void, Never>?
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
    @ObservationIgnored private var visionBackfillTask: Task<Void, Never>?

    init() {
        Self.bootLog("model init")
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

    private static let folderDefaultsKey = "folderURL"
    private static let foldersDefaultsKey = "folderURLs"
    private static let lastOpenNoteKey = "lastOpenNoteUrl"
    private static let accountUrlKey = "patchworkAccountUrl"
    private static let appGroupIdentifier = "group.party.chee.patchwork.lush"
    private static let widgetSnapshotFileName = "LushWidgetSnapshot.json"
    private static let folderContentWidgetKind = "FolderContentWidget"

    private(set) var accountUrl: String? = UserDefaults.standard.string(forKey: accountUrlKey)
    private(set) var accountConfigUrl: String?
    private(set) var inboxUrl: String?
    private(set) var contactName: String?
    private(set) var contactAvatarData: Data?

    var loggedIn: Bool { accountUrl != nil }

    static func normalizedAccountUrl(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("automerge:") { return trimmed }
        if trimmed.hasPrefix("account:") {
            return "automerge:" + String(trimmed.dropFirst("account:".count))
        }
        return nil
    }

    func logIn(accountUrl url: String) async -> Bool {
        guard let core else { return false }
        guard let normalized = Self.normalizedAccountUrl(url) else {
            status = "Login failed: expected an automerge: or account: URL"
            return false
        }
        status = "Logging in…"
        do {
            let state = try await Task.detached {
                try core.loginAccount(accountUrl: normalized)
            }.value
            accountUrl = state.accountUrl
            UserDefaults.standard.set(state.accountUrl, forKey: Self.accountUrlKey)
            await applyAccount(state)
            status = ""
            appendSyncEvent("Logged in: \(state.accountUrl)")
            return true
        } catch {
            status = "Login failed: \(error.localizedDescription)"
            return false
        }
    }

    func logOut() {
        accountUrl = nil
        accountConfigUrl = nil
        inboxUrl = nil
        contactName = nil
        contactAvatarData = nil
        UserDefaults.standard.removeObject(forKey: Self.accountUrlKey)
        appendSyncEvent("Logged out")
    }

    private func applyAccount(_ state: AccountState) async {
        accountConfigUrl = state.configUrl
        inboxUrl = state.inbox
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

    func setInbox(_ url: String) {
        inboxUrl = url
        guard let core, let configUrl = accountConfigUrl else { return }
        Task.detached { try? core.setConfigInbox(configUrl: configUrl, url: url) }
    }

    /// Widget/shortcut note creation lands in the configured inbox folder.
    func createNoteInInbox(snap: ContextSnapshot? = nil) {
        if let inboxUrl {
            createNote(inFolder: inboxUrl)
        } else {
            createNote(snap: snap)
        }
    }

    private func persistRoots() {
        UserDefaults.standard.set(rootFolderUrls, forKey: Self.foldersDefaultsKey)
    }

    private static func bootLog(_ message: String) {
        let ms = Int(Date().timeIntervalSince(bootStart) * 1000)
        NSLog("lush boot +%dms %@", ms, message)
    }

    private static func loadLaunchSnapshot() -> NotesLaunchSnapshot? {
        guard let data = try? Data(contentsOf: launchSnapshotURL) else { return nil }
        return try? JSONDecoder().decode(NotesLaunchSnapshot.self, from: data)
    }

    private func saveLaunchSnapshot() {
        let snapshot = NotesLaunchSnapshot(
            rootFolderUrls: rootFolderUrls,
            folderUrl: folderUrl,
            folderTitle: folderTitle,
            selectedNoteUrl: selectedNoteUrl,
            notes: notes,
            folderTree: folderTree,
            previews: previews,
            thumbnails: thumbnails,
            noteSnapshots: launchNoteSnapshots
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let url = Self.launchSnapshotURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: [.atomic])
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
            self.launchNoteSnapshots[url] = snapshot
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
        do {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            let dataDir = support.appendingPathComponent("LushCore", isDirectory: true)
            var saved = UserDefaults.standard.stringArray(forKey: Self.foldersDefaultsKey) ?? []
            if saved.isEmpty,
               let legacy = UserDefaults.standard.string(forKey: Self.folderDefaultsKey) {
                saved = [legacy]
            }
            let core = try await Task.detached {
                try Core(dataDir: dataDir.path, serverUrl: nil)
            }.value
            Self.bootLog("Core constructed")
            self.core = core
            PatchworkWeb.coreServerPort = core.localServerPort()
            NativeWebStorage.shared.core = core
            Task { [semanticSearch] in await semanticSearch.attach(core) }
            let delegateBridge = DelegateBridge(model: self)
            self.delegateBridge = delegateBridge
            core.setDelegate(delegate: delegateBridge)
            presence.model = self
            connected = core.isConnected()
            Self.bootLog("Core bridged")

            // The last-open doc needs only its url, not the folder tree —
            // open it before any folder work so the editor loads immediately.
            if saved.first != nil,
               let last = UserDefaults.standard.string(forKey: Self.lastOpenNoteKey) {
                selectedNoteUrl = last
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
        do {
            try core.removeEntry(folderUrl: parent, url: url)
        } catch {
            print("removeEntry failed: parent=\(parent) url=\(url) error=\(error)")
        }
        refreshNotes()
    }

    func renameEntry(parentUrl: String?, url: String, to name: String) {
        guard let core, let parent = parentUrl ?? folderUrl else { return }
        try? core.renameEntry(folderUrl: parent, url: url, title: name)
        refreshNotes()
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
                #if os(macOS)
                self.writeWidgetSnapshot()
                #endif
            }
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
        return find(folderTree)
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
                if let selected = self.selectedNoteUrl, self.node(for: selected) == nil {
                    self.selectedNoteUrl = nil
                }
                self.saveLaunchSnapshot()
                Self.bootLog(
                    "sidebar published notes=\(notes.count) visible=\(visible.count) localMs=\(localMs)"
                )
                #if os(macOS)
                self.writeWidgetSnapshot()
                #endif
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
                self.metaFetched.formUnion(newPreviews.keys)
                self.metaFetched.formIntersection(liveUrls)
                self.contextMetas = self.contextMetas.filter { liveUrls.contains($0.key) }
                self.backfillSemanticIndex(for: richNotes)
                self.backfillSpotlightIndex(for: richNotes)
                self.backfillAssetVision()
                self.saveLaunchSnapshot()
                Self.bootLog(
                    "metadata published previews=\(newPreviews.count) thumbnails=\(newThumbnails.count) metaMs=\(metaMs)"
                )
                #if os(macOS)
                self.writeWidgetSnapshot()
                #endif
            }
        }
    }

    func forceSync() {
        guard let core else { return }
        appendSyncEvent("Force sync: resyncing \(rootFolderUrls.count) root folder(s)")
        Task {
            for url in rootFolderUrls {
                let changes = core.docChangeCount(url: url)
                let entries = await core.folderEntriesOf(url: url).count
                appendSyncEvent("  \(url.suffix(12)): \(entries) entries, \(changes) changes locally")
                try? core.resyncDoc(url: url)
            }
            try? await Task.sleep(for: .seconds(5))
            refreshNotes()
            for url in rootFolderUrls {
                let changes = core.docChangeCount(url: url)
                let entries = await core.folderEntriesOf(url: url).count
                appendSyncEvent("  post-sync \(url.suffix(12)): \(entries) entries, \(changes) changes")
            }
        }
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

    private func writeWidgetSnapshot() {
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

    func clearStorage() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dataDir = support.appendingPathComponent("LushCore", isDirectory: true)
        do {
            try FileManager.default.removeItem(at: dataDir)
            appendSyncEvent("Cleared local storage — quitting")
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
        } catch {}
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
            meta.nowPlaying = b.attrs["now_playing"]?.stringValue
            break
        }
        contextMetas[url] = meta
    }

    func documentHistorySummary(url: String) async -> DocumentHistorySummary {
        guard let core else {
            return DocumentHistorySummary(changeCount: 0, heads: [], modified: nil, entries: [])
        }
        let currentHeads = await core.docHeads(url: url)
        if let cached = documentHistoryCache[url], cached.heads == currentHeads {
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
            entries: historyEntries
        )
        documentHistoryCache[url] = summary
        return summary
    }

    private var pendingRefreshUrls: Set<String> = []

    func docChanged(url: String) {
        folderNodeCache.removeValue(forKey: url)
        documentHistoryCache.removeValue(forKey: url)
        thumbnails.removeValue(forKey: url)
        metaFetched.remove(url)
        notifyNoteObservers(url)
        if url == accountConfigUrl, let core, let configUrl = accountConfigUrl {
            Task { @MainActor [weak self] in
                let state = await Task.detached { core.configState(configUrl: configUrl) }.value
                guard let self, let state else { return }
                self.inboxUrl = state.inbox
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
        pendingRefreshUrls.insert(url)
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
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
                    #if os(macOS)
                self.writeWidgetSnapshot()
                #endif
                    return
                }
                let (freshPreviews, freshThumbnails) = await Self.fetchMeta(core: core, urls: Array(stale))
                self.previews.merge(freshPreviews) { _, new in new }
                self.thumbnails.merge(freshThumbnails) { _, new in new }
                self.metaFetched.formUnion(freshPreviews.keys)
                self.saveLaunchSnapshot()
                #if os(macOS)
                self.writeWidgetSnapshot()
                #endif
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

    func createNote(snap: ContextSnapshot? = nil) {
        guard let core else { return }
        Task.detached { [core, weak self, snap] in
            do {
                let url = try core.createNoteDoc(title: "")
                let initial: [SpanNode] = [.block(.creationBlock(snap: snap)), .block(.heading(level: 1))]
                try? core.updateNoteSpans(url: url, spansJson: SpanNode.encodeList(initial))
                try? core.linkNoteToFolder(noteUrl: url, title: "")
                await MainActor.run { [weak self] in
                    self?.pendingFocusUrl = url
                    self?.selectedNoteUrl = url
                    self?.refreshNotes()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.status = "Couldn't create note: \(error.localizedDescription)"
                }
            }
        }
    }

    func createNote(inFolder folderUrl: String) {
        guard let core else { return }
        Task.detached { [core, weak self, folderUrl] in
            do {
                let url = try core.createNoteIn(folderUrl: folderUrl, title: "")
                let initial: [SpanNode] = [.block(.creationBlock(snap: nil)), .block(.heading(level: 1))]
                try? core.updateNoteSpans(url: url, spansJson: SpanNode.encodeList(initial))
                await MainActor.run { [weak self] in
                    self?.pendingFocusUrl = url
                    self?.selectedNoteUrl = url
                    self?.refreshNotes()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.status = "Couldn't create note: \(error.localizedDescription)"
                }
            }
        }
    }

    func createNoteForShortcut(inFolder folderUrl: String?) async -> String? {
        if core == nil {
            await start()
        }
        guard let core else { return nil }
        let target = folderUrl ?? inboxUrl ?? self.folderUrl
        guard let target else { return nil }
        do {
            let url = try await Task.detached {
                let url = try core.createNoteIn(folderUrl: target, title: "")
                let initial: [SpanNode] = [.block(.creationBlock(snap: nil)), .block(.heading(level: 1))]
                try? core.updateNoteSpans(url: url, spansJson: SpanNode.encodeList(initial))
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
        guard let core, let folderUrl else { return }
        do {
            let url = try core.createScriptIn(folderUrl: folderUrl, name: "")
            refreshNotes()
            selectedNoteUrl = url
        } catch {
            status = "Couldn't create script: \(error.localizedDescription)"
        }
    }

    func createFileForShortcut(inFolder folderUrl: String?) async -> String? {
        if core == nil {
            await start()
        }
        guard let core else { return nil }
        let target = folderUrl ?? inboxUrl ?? self.folderUrl
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
        do {
            try core.deleteNote(url: url)
            semanticIndexTasks[url]?.cancel()
            semanticIndexTasks[url] = nil
            Task { [semanticSearch] in await semanticSearch.remove(url: url) }
            Task { [spotlightIndex] in await spotlightIndex.remove(url: url) }
            refreshNotes()
        } catch {
            status = "Couldn't delete note: \(error.localizedDescription)"
        }
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
        do {
            try core.moveEntry(fromFolder: from, toFolder: destination, url: url)
            refreshNotes()
        } catch {
            status = "Couldn't move: \(error.localizedDescription)"
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
        launchNoteSnapshots[url] = snapshot
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

    private func latestNoteHeads(for url: String) async -> [String]? {
        guard let core else { return nil }
        return try? await core.noteSpansSnapshot(url: url).heads
    }

    func updateSpans(_ url: String, json: String) async {
        guard let core else { return }
        await Task.detached {
            do { try core.updateNoteSpans(url: url, spansJson: json) } catch {}
        }.value
        async let previewTask = core.notePreview(url: url)
        async let titleTask = core.noteTitle(url: url)
        async let snapshotTask = core.noteSpansSnapshot(url: url)
        let (preview, title, snapshot) = await (previewTask, titleTask, try? snapshotTask)
        previews[url] = preview
        launchNoteSnapshots[url] = snapshot ?? NoteSpansSnapshot(spansJson: json, heads: [])
        saveLaunchSnapshot()
        scheduleSemanticIndex(url: url, name: title)
    }

    @discardableResult
    func updateDocument(
        _ url: String,
        json: String,
        title: String,
        origin: UUID? = nil
    ) async -> [String]? {
        let previous = noteWriteTasks[url]
        let task = Task { [weak self] () -> [String]? in
            _ = await previous?.value
            await self?.updateSpans(url, json: json)
            await self?.updateTitleIfNeeded(url, title: title)
            self?.notifyNoteObservers(url, excluding: origin)
            return await self?.latestNoteHeads(for: url)
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

    func search(_ query: String) async -> [SearchHit] {
        guard let core, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let exact = await Task.detached { core.searchNotes(query: query) }.value
        let seen = Set(exact.map(\.url))
        return await exact + semanticSearch.search(query, excluding: seen)
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
        }
    }

    private func backfillSpotlightIndex(for notes: [NoteInfo]) {
        for note in notes {
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
        await semanticSearch.index(url: url, name: resolvedName ?? "", spansJson: json)
        semanticIndexTasks[url] = nil
    }

    private func scheduleSpotlightIndex(url: String, name: String? = nil) {
        Task { [weak self] in
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
    }

    private func schedulePreviewUpdate(url: String) {
        previewUpdateTasks[url]?.cancel()
        previewUpdateTasks[url] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self, let core = self.core else { return }
            let preview = await core.notePreview(url: url)
            guard !Task.isCancelled else { return }
            self.previews[url] = preview
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
    }

    func updateAssetML(_ url: String, summary: String, caption: String, keywords: String) async {
        guard let core else { return }
        await Task.detached {
            try? core.updateAssetMl(url: url, summary: summary, caption: caption, keywords: keywords)
        }.value
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
    func generateAssetML(_ url: String, name fallbackName: String? = nil) async -> AssetMl? {
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
        guard let result = try? await MLAnalyzer.analyze(evidence, operation: operation) else {
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
            importFolder = try await core.folderEntriesOf(url: target)
                .first { $0.kind == "folder" && $0.name == "Apple Notes" }?
                .url
                ?? core.createSubfolderIn(folderUrl: target, title: "Apple Notes")
        } catch {
            importStatus = "Import failed: \(error.localizedDescription)"
            return
        }
        let (done, skipped, failed) = await Task.detached { [weak self] in
            var subfolders: [String: String] = [:]
            for entry in await core.folderEntriesOf(url: importFolder) where entry.kind == "folder" {
                subfolders[entry.name] = entry.url
            }
            var existing: [String: Set<String>] = [:]
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
                    if existing[sub] == nil {
                        existing[sub] = Set(await core.folderEntriesOf(url: sub).map(\.name))
                    }
                    if existing[sub]?.contains(note.name) == true {
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
                    existing[sub]?.insert(note.name)
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
    #endif

    // Quick note ------------------------------------------------------------

    private static let quickNoteKey = "quickNoteUrl"
    var quickNoteUrl: String? = UserDefaults.standard.string(forKey: quickNoteKey)

    func setQuickNote(_ url: String?) {
        quickNoteUrl = url
        UserDefaults.standard.set(url, forKey: Self.quickNoteKey)
    }

    func appendToQuickNote(_ snippet: String) async -> String? {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return quickNoteUrl }
        guard let target = await quickNoteTarget() else { return nil }
        let core = target.core
        let url = target.url
        do {
            try? await core.openNote(url: url)
            let json = (try? await core.noteSpansJson(url: url)) ?? "[]"
            var spans = SpanNode.decodeList(json)
            if !spans.isEmpty {
                spans.append(.text("\n", [:]))
            }
            spans.append(.text(trimmed, [:]))
            try await Task.detached {
                try core.updateNoteSpans(url: url, spansJson: SpanNode.encodeList(spans))
            }.value
            refreshQuickNote(url, core: core)
            return url
        } catch {
            status = "Couldn't update Quick Note: \(error.localizedDescription)"
            return nil
        }
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
            try await Task.detached {
                try core.updateNoteSpans(url: url, spansJson: SpanNode.encodeList(spans))
            }.value
            refreshQuickNote(url, core: core)
            return url
        } catch {
            status = "Couldn't add recording to Quick Note: \(error.localizedDescription)"
            return nil
        }
    }

    private func quickNoteTarget() async -> (core: Core, url: String)? {
        if core == nil {
            await start()
        }
        guard let core else { return nil }
        if let quickNoteUrl {
            return (core, quickNoteUrl)
        }
        let target = inboxUrl ?? folderUrl
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

    func importAsNewNote(_ content: IncomingContent) {
        guard let core else { return }
        do {
            var textSpans: [SpanNode] = []
            var importedUrls: [String] = []

            for payload in content.flattenedPayloads {
                switch payload {
                case .text(let text):
                    appendText(text, to: &textSpans)
                case .file(let url):
                    importedUrls += try importFileEntries(from: url, core: core)
                case .batch:
                    break
                }
            }

            let textJson = SpanNode.encodeList(textSpans)
            if textJson != "[]" {
                let noteUrl = try core.createNote(title: content.textDisplayTitle)
                try? core.updateNoteSpans(url: noteUrl, spansJson: textJson)
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

    func importToInbox(_ content: IncomingContent) {
        guard let core else { return }
        let target = inboxUrl ?? folderUrl
        do {
            var textSpans: [SpanNode] = []
            var importedUrls: [String] = []

            for payload in content.flattenedPayloads {
                switch payload {
                case .text(let text):
                    appendText(text, to: &textSpans)
                case .file(let url):
                    importedUrls += try importFileEntries(from: url, core: core, folderUrl: target)
                case .batch:
                    break
                }
            }

            let textJson = SpanNode.encodeList(textSpans)
            if textJson != "[]" {
                let noteUrl: String
                if let target {
                    noteUrl = try core.createNoteIn(folderUrl: target, title: content.textDisplayTitle)
                } else {
                    noteUrl = try core.createNote(title: content.textDisplayTitle)
                }
                try? core.updateNoteSpans(url: noteUrl, spansJson: textJson)
                importedUrls.insert(noteUrl, at: 0)
            }

            refreshNotes()
            if let first = importedUrls.first {
                selectedNoteUrl = first
            }
            content.cleanupHandoff()
        } catch {
            status = "Couldn't import: \(error.localizedDescription)"
        }
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

private struct LushWidgetSnapshot: Codable, Equatable {
    let updatedAt: Date
    let defaultFolderUrl: String?
    let folders: [LushWidgetFolderSnapshot]
}

private struct LushWidgetFolderSnapshot: Codable, Equatable {
    let url: String
    let title: String
    let path: String
    let totalItemCount: Int
    let items: [LushWidgetItemSnapshot]
}

private struct LushWidgetItemSnapshot: Codable, Equatable {
    let url: String
    let title: String
    let preview: String
    let kind: String
}

struct IncomingContent: Identifiable {
    let id = UUID()
    enum Payload {
        case text(String)
        case file(URL)
        case batch([Payload])
    }
    let payload: Payload
    let handoffDirectory: URL?

    init(payload: Payload, handoffDirectory: URL? = nil) {
        self.payload = payload
        self.handoffDirectory = handoffDirectory
    }

    var flattenedPayloads: [Payload] {
        switch payload {
        case .text, .file:
            return [payload]
        case .batch(let payloads):
            return payloads.flatMap { IncomingContent(payload: $0).flattenedPayloads }
        }
    }

    var displayTitle: String {
        switch payload {
        case .text(let text):
            let title = String(text.prefix(60)).components(separatedBy: .newlines).first ?? ""
            return title.isEmpty ? "Shared Text" : title
        case .file(let url):
            return url.lastPathComponent.isEmpty ? "Shared File" : url.lastPathComponent
        case .batch(let payloads):
            if payloads.count == 1 {
                return IncomingContent(payload: payloads[0]).displayTitle
            }
            return "\(payloads.count) Shared Items"
        }
    }

    var textDisplayTitle: String {
        for payload in flattenedPayloads {
            if case .text(let text) = payload {
                let title = String(text.prefix(60)).components(separatedBy: .newlines).first ?? ""
                if !title.isEmpty { return title }
            }
        }
        return "Shared Text"
    }

    func cleanupHandoff() {
        guard let handoffDirectory else { return }
        try? FileManager.default.removeItem(at: handoffDirectory)
    }

    static func sharedHandoff(id: String) -> IncomingContent? {
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedHandoff.appGroupIdentifier
        ) else { return nil }
        let directory = root
            .appendingPathComponent("SharedIntake", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        let payloadUrl = directory.appendingPathComponent("payload.json")
        guard let data = try? Data(contentsOf: payloadUrl),
              let handoff = try? JSONDecoder().decode(SharedHandoff.self, from: data) else {
            return nil
        }
        let payloads = handoff.items.compactMap { item -> Payload? in
            switch item {
            case .text(let text):
                return .text(text)
            case .file(let relativePath, _):
                return .file(directory.appendingPathComponent(relativePath))
            }
        }
        guard !payloads.isEmpty else { return nil }
        return IncomingContent(payload: .batch(payloads), handoffDirectory: directory)
    }
}

private struct SharedHandoff: Codable {
    static let appGroupIdentifier = "group.party.chee.patchwork.lush"

    let createdAt: Date
    let items: [SharedHandoffItem]
}

private enum SharedHandoffItem: Codable {
    case text(String)
    case file(relativePath: String, suggestedName: String)

    private enum CodingKeys: String, CodingKey {
        case kind, text, relativePath, suggestedName
    }

    private enum Kind: String, Codable {
        case text, file
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .file:
            self = .file(
                relativePath: try container.decode(String.self, forKey: .relativePath),
                suggestedName: try container.decode(String.self, forKey: .suggestedName)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(text, forKey: .text)
        case .file(let relativePath, let suggestedName):
            try container.encode(Kind.file, forKey: .kind)
            try container.encode(relativePath, forKey: .relativePath)
            try container.encode(suggestedName, forKey: .suggestedName)
        }
    }
}
