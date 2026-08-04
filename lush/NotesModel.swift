import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

@Observable @MainActor
final class NotesModel {
    private(set) var core: Core?
    var notes: [NoteInfo] = []
    var folderUrl: String?
    var folderTitle: String = ""
    var connected = false
    var selectedNoteUrl: String? {
        didSet { UserDefaults.standard.set(selectedNoteUrl, forKey: Self.lastOpenNoteKey) }
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
    private var semanticIndexTasks: [String: Task<Void, Never>] = [:]
    private var previewUpdateTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var noteWriteTasks: [String: Task<[String]?, Never>] = [:]
    @ObservationIgnored private var noteObservers: [UUID: @MainActor (String) -> Void] = [:]
    @ObservationIgnored private var delegateBridge: DelegateBridge?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    private(set) var thumbnails: [String: Data] = [:]
    @ObservationIgnored private var pendingRefreshTask: Task<Void, Never>?
    private var lastKnownCounts: [String: Int] = [:]
    @ObservationIgnored private var folderNodeCache: [String: (heads: [String], node: FolderNode)] = [:]

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

    private func persistRoots() {
        UserDefaults.standard.set(rootFolderUrls, forKey: Self.foldersDefaultsKey)
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
            self.core = core
            let delegateBridge = DelegateBridge(model: self)
            self.delegateBridge = delegateBridge
            core.setDelegate(delegate: delegateBridge)
            connected = core.isConnected()

            if let first = saved.first {
                // Returning user: set folder immediately and return to the UI.
                // startFolderUrl sets self.folder in Rust and loads the doc
                // from redb in the background; docChanged fires when ready.
                try core.startFolderUrl(url: first)
                rootFolderUrls = saved
                persistRoots()
                folderUrl = first
                status = ""
                core.prefetchNotes(urls: Array(saved.dropFirst()))
                refreshNotes()
                startPolling()
                if let last = UserDefaults.standard.string(forKey: Self.lastOpenNoteKey) {
                    selectedNoteUrl = last
                }
                appendSyncEvent("Started: \(saved.count) root folder(s)")
            } else {
                // Fresh install: create the folder doc (one-time wait, acceptable).
                status = "Creating folder…"
                let url = try await Task.detached {
                    try core.ensureFolder(existingUrl: nil)
                }.value
                saved = [url]
                rootFolderUrls = saved
                persistRoots()
                folderUrl = url
                status = ""
                refreshNotes()
                startPolling()
                appendSyncEvent("Started: new folder created")
            }
        } catch {
            status = "Failed to start: \(error.localizedDescription)"
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

    func removeEntry(parentUrl: String?, url: String) {
        guard let core, let parent = parentUrl ?? folderUrl else { return }
        try? core.removeEntry(folderUrl: parent, url: url)
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
    ) -> (tree: [FolderNode], newCache: [String: (heads: [String], node: FolderNode)]) {
        let rootUrls = Set(rootFolderUrls)
        var visited = Set<String>()
        var newCache = cache
        func folderNode(url: String, name: String, parent: String?) -> FolderNode {
            guard visited.insert(url).inserted else {
                return FolderNode(url: url, name: name, kind: "folder", parentUrl: parent, children: [])
            }
            let currentHeads = core.docHeads(url: url)
            if let cached = newCache[url], cached.heads == currentHeads {
                var hit = cached.node
                hit = FolderNode(url: hit.url, name: hit.name, kind: hit.kind, parentUrl: parent, children: hit.children)
                return hit
            }
            let entries = core.folderEntriesOf(url: url)
            var children: [FolderNode] = entries
                .filter { $0.kind == "folder" && !rootUrls.contains($0.url) }
                .map { folderNode(url: $0.url, name: $0.name, parent: url) }
            children += entries
                .filter { $0.kind != "folder" }
                .map { FolderNode(url: $0.url, name: $0.name, kind: $0.kind, parentUrl: url, children: nil) }
            let node = FolderNode(url: url, name: name, kind: "folder", parentUrl: parent, children: children)
            newCache[url] = (heads: currentHeads, node: node)
            return node
        }
        let tree = rootFolderUrls.map { url in
            let name = core.noteTitle(url: url)
            return folderNode(url: url, name: name.isEmpty ? "Notes" : name, parent: nil)
        }
        return (tree, newCache)
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
            let (tree, newCache) = Self.computeTree(core: core, rootFolderUrls: rootUrls, cache: cache)
            guard let self else { return }
            await MainActor.run {
                self.folderTree = tree
                self.folderNodeCache = newCache
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
            if let parent = node.parentUrl, parent != folderUrl {
                await selectFolder(parent)
                selectedNoteUrl = url
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
        buildTree()
    }

    func refreshNotes() {
        guard let core else { return }
        let rootUrls = rootFolderUrls
        let cache = folderNodeCache
        Task.detached { [core, rootUrls, cache, weak self] in
            let notes = core.listNotes()
            let folderTitle = core.folderTitle()
            let (tree, newCache) = Self.computeTree(core: core, rootFolderUrls: rootUrls, cache: cache)
            let visible = Self.visibleNotes(in: tree)
            core.prefetchNotes(urls: notes.map(\.url))
            let (newPreviews, newThumbnails) = await withTaskGroup(
                of: (String, String, Data?).self,
                returning: ([String: String], [String: Data]).self
            ) { group in
                for note in visible {
                    group.addTask { [core] in
                        let preview = core.notePreview(url: note.url)
                        let thumbnail = core.noteThumbnailBytes(url: note.url).map { Data($0) }
                        return (note.url, preview, thumbnail)
                    }
                }
                var previews: [String: String] = [:]
                var thumbnails: [String: Data] = [:]
                for await (url, preview, thumbnail) in group {
                    previews[url] = preview
                    if let thumb = thumbnail { thumbnails[url] = thumb }
                }
                return (previews, thumbnails)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.notes = notes
                self.folderTitle = folderTitle
                self.folderTree = tree
                self.folderNodeCache = newCache
                self.previews.merge(newPreviews) { _, new in new }
                self.thumbnails.merge(newThumbnails) { _, new in new }
                if let selected = self.selectedNoteUrl, self.node(for: selected) == nil {
                    self.selectedNoteUrl = nil
                }
                let liveUrls = Set(visible.map(\.url))
                self.contextMetas = self.contextMetas.filter { liveUrls.contains($0.key) }
                self.backfillSemanticIndex(for: visible.filter { $0.kind == "rich" }.map {
                    NoteInfo(url: $0.url, name: $0.name, kind: $0.kind)
                })
            }
        }
    }

    func forceSync() {
        guard let core else { return }
        appendSyncEvent("Force sync: resyncing \(rootFolderUrls.count) root folder(s)")
        for url in rootFolderUrls {
            let changes = core.docChangeCount(url: url)
            appendSyncEvent("  \(url.suffix(12)): \(core.folderEntriesOf(url: url).count) entries, \(changes) changes locally")
            try? core.resyncDoc(url: url)
        }
        Task {
            try? await Task.sleep(for: .seconds(5))
            refreshNotes()
            for url in rootFolderUrls {
                let changes = core.docChangeCount(url: url)
                appendSyncEvent("  post-sync \(url.suffix(12)): \(core.folderEntriesOf(url: url).count) entries, \(changes) changes")
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
                    newCounts[url] = core.folderEntriesOf(url: url).count
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
        let json = await Task.detached { [core] in
            try? core.openNote(url: url)
            return (try? core.noteSpansJson(url: url)) ?? "[]"
        }.value
        let spans = SpanNode.decodeList(json)
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

    private var pendingRefreshUrls: Set<String> = []

    func docChanged(url: String) {
        folderNodeCache.removeValue(forKey: url)
        thumbnails.removeValue(forKey: url)
        notifyNoteObservers(url)
        if node(for: url)?.isNote == true || notes.contains(where: { $0.url == url && $0.kind == "rich" }) {
            scheduleSemanticIndex(url: url)
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
                for u in urls {
                    if self.notes.contains(where: { $0.url == u }), let core = self.core {
                        self.previews[u] = core.notePreview(url: u)
                    }
                }
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

    func addDocToCurrentFolder(url: String) {
        guard let core else { return }
        Task.detached { [core, weak self, url] in
            try? core.linkNoteToFolder(noteUrl: url, title: "")
            await MainActor.run { [weak self] in
                self?.selectedNoteUrl = url
                self?.refreshNotes()
            }
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

    func deleteNote(_ url: String) {
        guard let core else { return }
        do {
            try core.deleteNote(url: url)
            semanticIndexTasks[url]?.cancel()
            semanticIndexTasks[url] = nil
            Task { [semanticSearch] in await semanticSearch.remove(url: url) }
            refreshNotes()
        } catch {
            status = "Couldn't delete note: \(error.localizedDescription)"
        }
    }

    func copyFolderUrl() {
        guard let folderUrl else { return }
        Clipboard.copy(folderUrl)
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
        return await Task.detached {
            try? core.openNote(url: url)
            return (try? core.noteSpansJson(url: url)) ?? "[]"
        }.value
    }

    func spansSnapshot(for url: String) async -> NoteSpansSnapshot {
        if core == nil {
            await start()
        }
        guard let core else { return NoteSpansSnapshot(spansJson: "[]", heads: []) }
        return await Task.detached {
            try? core.openNote(url: url)
            return (try? core.noteSpansSnapshot(url: url)) ?? NoteSpansSnapshot(spansJson: "[]", heads: [])
        }.value
    }

    private func latestNoteHeads(for url: String) async -> [String]? {
        guard let core else { return nil }
        return await Task.detached {
            try? core.noteSpansSnapshot(url: url).heads
        }.value
    }

    func updateSpans(_ url: String, json: String) async {
        guard let core else { return }
        let (preview, title) = await Task.detached {
            do { try core.updateNoteSpans(url: url, spansJson: json) } catch {}
            return (core.notePreview(url: url), core.noteTitle(url: url))
        }.value
        previews[url] = preview
        scheduleSemanticIndex(url: url, name: title)
    }

    func updateDocument(
        _ url: String,
        json: String,
        title: String,
        origin: UUID? = nil
    ) async {
        let previous = noteWriteTasks[url]
        let task = Task { [weak self] () -> [String]? in
            _ = await previous?.value
            await self?.updateSpans(url, json: json)
            await self?.updateTitleIfNeeded(url, title: title)
            self?.notifyNoteObservers(url, excluding: origin)
            return await self?.latestNoteHeads(for: url)
        }
        noteWriteTasks[url] = task
        _ = await task.value
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
        let resolvedName = name ?? node(for: url)?.displayName ?? core.noteTitle(url: url)
        let json = await Task.detached {
            try? core.openNote(url: url)
            return (try? core.noteSpansJson(url: url)) ?? "[]"
        }.value
        await semanticSearch.index(url: url, name: resolvedName, spansJson: json)
        semanticIndexTasks[url] = nil
    }

    private func schedulePreviewUpdate(url: String) {
        previewUpdateTasks[url]?.cancel()
        previewUpdateTasks[url] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, let core = self.core else { return }
                self.previews[url] = core.notePreview(url: url)
                self.previewUpdateTasks[url] = nil
            }
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
        return await Task.detached {
            try? core.assetBytes(url: url)
        }.value
    }

    func updateAssetVision(_ url: String, description: String, ocr: String) async {
        guard let core else { return }
        await Task.detached {
            try? core.updateAssetVision(url: url, description: description, ocr: ocr)
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
            importFolder = try core.folderEntriesOf(url: target)
                .first { $0.kind == "folder" && $0.name == "Apple Notes" }?
                .url
                ?? core.createSubfolderIn(folderUrl: target, title: "Apple Notes")
        } catch {
            importStatus = "Import failed: \(error.localizedDescription)"
            return
        }
        let (done, skipped, failed) = await Task.detached { [weak self] in
            var subfolders: [String: String] = [:]
            for entry in core.folderEntriesOf(url: importFolder) where entry.kind == "folder" {
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
                        existing[sub] = Set(core.folderEntriesOf(url: sub).map(\.name))
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

    func noteModified(_ url: String) -> Date {
        guard let core else { return Date(timeIntervalSince1970: 0) }
        var seconds = TimeInterval(core.noteModified(url: url))
        if seconds > 4_000_000_000 {
            seconds /= 1000
        }
        return Date(timeIntervalSince1970: seconds)
    }

    func recentNotes(limit: Int = 100) -> [(node: FolderNode, modified: Date)] {
        var all: [FolderNode] = []
        func walk(_ nodes: [FolderNode]) {
            for node in nodes {
                if node.kind == "lush" || node.kind == "rich" {
                    all.append(node)
                }
                if let children = node.children {
                    walk(children)
                }
            }
        }
        walk(folderTree)
        return Array(
            all.map { ($0, noteModified($0.url)) }
                .sorted { $0.1 > $1.1 }
                .prefix(limit)
        )
    }

    func updateTitleIfNeeded(_ url: String, title: String) async {
        guard let core else { return }
        let name = title.isEmpty ? "Untitled" : title
        let node = node(for: url)
        guard node?.displayName != name else {
            return
        }
        let parent = node?.parentUrl ?? folderUrl
        let preview = await Task.detached {
            if let parent {
                try? core.renameEntry(folderUrl: parent, url: url, title: name)
            } else {
                try? core.renameNote(url: url, title: name)
            }
            return core.notePreview(url: url)
        }.value
        previews[url] = preview
        scheduleSemanticIndex(url: url, name: name)
        refreshNotes()
    }

    // Incoming content (share / open-with) ------------------------------------

    var pendingIncoming: IncomingContent?

    func importAsNewNote(_ content: IncomingContent) {
        guard let core else { return }
        do {
            let title: String
            let spansJson: String
            switch content.payload {
            case .text(let text):
                title = String(text.prefix(60)).components(separatedBy: .newlines).first ?? ""
                let spans = [SpanNode.text(text, [:])]
                spansJson = SpanNode.encodeList(spans)
            case .file(let url):
                title = url.deletingPathExtension().lastPathComponent
                spansJson = "[]"
            }
            let noteUrl = try core.createNote(title: title)
            if !spansJson.isEmpty && spansJson != "[]" {
                try? core.updateNoteSpans(url: noteUrl, spansJson: spansJson)
            }
            if case .file(let url) = content.payload,
               let data = try? Data(contentsOf: url) {
                let ext = url.pathExtension.lowercased()
                let mime = mimeType(for: ext)
                _ = try? core.createAsset(
                    name: url.lastPathComponent,
                    extension: ext.isEmpty ? "bin" : ext,
                    mimeType: mime,
                    data: data
                )
            }
            refreshNotes()
            selectedNoteUrl = noteUrl
        } catch {
            status = "Couldn't import: \(error.localizedDescription)"
        }
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
}

extension NoteInfo: Identifiable {
    public var id: String { url }
}

struct NoteContextMeta {
    var created: Date?
    var location: String?
    var weather: String?
    var nowPlaying: String?
}

struct FolderNode: Identifiable, Hashable {
    let url: String
    let name: String
    let kind: String
    let parentUrl: String?
    var children: [FolderNode]?

    var id: String { url }
    var isNote: Bool { kind == "lush" || kind == "rich" }
}

struct IncomingContent: Identifiable {
    let id = UUID()
    enum Payload {
        case text(String)
        case file(URL)
    }
    let payload: Payload
}
