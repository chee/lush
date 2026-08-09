import AppKit
import UniformTypeIdentifiers
import WidgetKit

/// The helper's whole job: hold a core open, keep it connected, and keep the
/// out-of-process surfaces (shared intake, widget snapshot) fed while Lush
/// itself isn't running.
@MainActor
final class HelperSync {
    static let shared = HelperSync()

    private(set) var core: Core?
    private(set) var connected = false
    private(set) var lastEvent = ""
    private var accountConfigUrl: String?
    private var inboxUrl: String?
    private var rootUrls: [String] = []
    private var delegateBridge: DelegateBridge?
    private var pollTask: Task<Void, Never>?

    var onStateChange: (() -> Void)?

    func start() async {
        guard core == nil else { return }
        let dataDir = LushShared.coreDataDirectory()
        let core: Core
        do {
            core = try await Task.detached { try Core(dataDir: dataDir.path, serverUrl: nil) }.value
        } catch {
            note("core failed to open: \(error.localizedDescription)")
            return
        }
        self.core = core
        let bridge = DelegateBridge(sync: self)
        delegateBridge = bridge
        core.setDelegate(delegate: bridge)
        connected = core.isConnected()

        rootUrls = LushShared.rootFolderUrls
        if let first = rootUrls.first {
            try? core.startFolderUrl(url: first)
            core.prefetchNotes(urls: Array(rootUrls.dropFirst()))
        }
        core.connect()

        if let account = LushShared.accountUrl {
            await logIn(account)
        }
        note("syncing \(rootUrls.count) root folder(s)")
        await drainSharedIntake()
        await writeWidgetSnapshot()
        startPolling()
        onStateChange?()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        core?.shutdown()
        core = nil
        delegateBridge = nil
        connected = false
        onStateChange?()
    }

    func syncNow() {
        guard let core else { return }
        let urls = rootUrls
        Task.detached {
            for url in urls { try? core.resyncDoc(url: url) }
        }
        Task {
            await drainSharedIntake()
            await writeWidgetSnapshot()
        }
    }

    private func logIn(_ url: String) async {
        guard let core else { return }
        do {
            let state = try await Task.detached { try core.loginAccount(accountUrl: url) }.value
            accountConfigUrl = state.configUrl
            inboxUrl = state.inbox
            if !state.folders.isEmpty, state.folders != rootUrls {
                rootUrls = state.folders
                LushShared.rootFolderUrls = state.folders
                if let first = state.folders.first { try? core.startFolderUrl(url: first) }
                core.prefetchNotes(urls: Array(state.folders.dropFirst()))
            }
        } catch {
            note("login failed: \(error.localizedDescription)")
        }
    }

    fileprivate func note(_ message: String) {
        lastEvent = message
        NSLog("lush helper: \(message)")
        onStateChange?()
    }

    fileprivate func setConnected(_ value: Bool) {
        connected = value
        onStateChange?()
    }

    /// Documents arrive by sync without any local write, so nothing tells us to
    /// refresh the widget — poll the roots for a changed entry count.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var counts: [String: Int] = [:]
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, let core = self.core, !Task.isCancelled else { break }
                var changed = false
                for url in self.rootUrls {
                    let count = await core.folderEntriesOf(url: url).count
                    if counts[url] != count {
                        counts[url] = count
                        changed = true
                    }
                }
                await self.drainSharedIntake()
                if changed { await self.writeWidgetSnapshot() }
            }
        }
    }
}

// MARK: - Shared intake

extension HelperSync {
    /// Share extension and Finder action drop payloads in the group container.
    /// Whichever of the two processes is up drains them.
    func drainSharedIntake() async {
        guard let core else { return }
        guard let root = LushShared.container else { return }
        let intake = root.appendingPathComponent("SharedIntake", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: intake,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        guard !entries.isEmpty else { return }
        guard let folder = inboxUrl ?? rootUrls.first else { return }

        for entry in entries {
            guard FileManager.default.fileExists(
                atPath: entry.appendingPathComponent("payload.json").path
            ) else { continue }
            guard let content = IncomingContent.sharedHandoff(id: entry.lastPathComponent) else {
                try? FileManager.default.removeItem(at: entry)
                continue
            }
            importToInbox(content, core: core, folderUrl: folder)
        }
        await writeWidgetSnapshot()
    }

    private func importToInbox(_ content: IncomingContent, core: Core, folderUrl: String) {
        defer { content.cleanupHandoff() }
        var texts: [String] = []
        for payload in content.flattenedPayloads {
            switch payload {
            case .text(let text):
                texts.append(text)
            case .file(let url):
                importAsset(url, core: core, folderUrl: folderUrl)
            case .batch:
                break
            }
        }
        guard !texts.isEmpty else { return }
        do {
            let noteUrl = try core.createNoteIn(
                folderUrl: folderUrl,
                title: content.textDisplayTitle
            )
            _ = try? core.updateNoteSpans(
                url: noteUrl,
                spansJson: Self.spansJSON(for: texts.joined(separator: "\n\n")),
                heads: nil
            )
            note("captured “\(content.textDisplayTitle)”")
        } catch {
            note("intake failed: \(error.localizedDescription)")
        }
    }

    private func importAsset(_ url: URL, core: Core, folderUrl: String) {
        guard let data = try? Data(contentsOf: url) else { return }
        let ext = url.pathExtension
        do {
            _ = try core.createAssetIn(
                folderUrl: folderUrl,
                name: url.deletingPathExtension().lastPathComponent,
                extension: ext,
                mimeType: Self.mimeType(forExtension: ext),
                data: data
            )
            note("captured \(url.lastPathComponent)")
        } catch {
            note("intake failed: \(error.localizedDescription)")
        }
    }

    private static func spansJSON(for text: String) -> String {
        let spans: [[String: String]] = [["type": "text", "value": text]]
        guard let data = try? JSONSerialization.data(withJSONObject: spans) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func mimeType(forExtension ext: String) -> String {
        UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}

// MARK: - Widget snapshot

extension HelperSync {
    func writeWidgetSnapshot() async {
        guard let core, let root = LushShared.container else { return }
        var folders: [LushWidgetFolderSnapshot] = []

        func walk(url: String, title: String, prefix: String) async {
            let path = prefix.isEmpty ? title : "\(prefix) / \(title)"
            let entries = await core.folderEntriesOf(url: url)
            let items = entries.filter { $0.kind != "folder" }
            var snapshots: [LushWidgetItemSnapshot] = []
            for item in items.prefix(6) {
                snapshots.append(LushWidgetItemSnapshot(
                    url: item.url,
                    title: item.name.isEmpty ? "Untitled" : item.name,
                    preview: await core.notePreview(url: item.url),
                    kind: item.kind
                ))
            }
            folders.append(LushWidgetFolderSnapshot(
                url: url,
                title: title,
                path: path,
                totalItemCount: items.count,
                items: snapshots
            ))
            for child in entries where child.kind == "folder" && !rootUrls.contains(child.url) {
                await walk(url: child.url, title: child.name, prefix: path)
            }
        }

        for url in rootUrls {
            await walk(url: url, title: await core.noteTitle(url: url), prefix: "")
        }

        let snapshotUrl = root.appendingPathComponent(LushShared.widgetSnapshotFileName)
        let old = try? Data(contentsOf: snapshotUrl)
        let previous = old.flatMap { try? JSONDecoder().decode(LushWidgetSnapshot.self, from: $0) }
        let defaultFolderUrl = previous?.defaultFolderUrl ?? rootUrls.first
        let unchanged = previous?.folders == folders && previous?.defaultFolderUrl == defaultFolderUrl
        let snapshot = LushWidgetSnapshot(
            updatedAt: unchanged ? (previous?.updatedAt ?? Date()) : Date(),
            defaultFolderUrl: defaultFolderUrl,
            folders: folders
        )
        guard let data = try? JSONEncoder().encode(snapshot), data != old else { return }
        do {
            try data.write(to: snapshotUrl, options: .atomic)
            WidgetCenter.shared.reloadTimelines(ofKind: LushShared.folderContentWidgetKind)
        } catch {
            note("widget snapshot failed: \(error.localizedDescription)")
        }
    }
}

private final class DelegateBridge: CoreDelegate {
    private let sync: HelperSync

    init(sync: HelperSync) {
        self.sync = sync
    }

    func onDocChanged(url: String) {}

    func onConnectionChanged(connected: Bool) {
        Task { @MainActor in sync.setConnected(connected) }
    }

    func onSyncEvent(message: String) {
        Task { @MainActor in sync.note(message) }
    }

    func onEphemeralMessage(url: String, payload: Data) {}

    func onPeersChanged() {}
}
