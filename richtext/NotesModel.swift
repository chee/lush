import Foundation
import Observation

@Observable @MainActor
final class NotesModel {
    private(set) var core: Core?
    var notes: [NoteInfo] = []
    var folderUrl: String?
    var folderTitle: String = ""
    var connected = false
    var selectedNoteUrl: String?
    var status: String = "Starting…"
    var previews: [String: String] = [:]
    var rootFolderUrl: String? { rootFolderUrls.first }
    var rootFolderUrls: [String] = []
    var folderTree: [FolderNode] = []

    /// The open editor registers here to hear about remote changes to its note.
    var noteChanged: @MainActor (String) -> Void = { _ in }

    private static let folderDefaultsKey = "folderURL"
    private static let foldersDefaultsKey = "folderURLs"

    private func persistRoots() {
        UserDefaults.standard.set(rootFolderUrls, forKey: Self.foldersDefaultsKey)
    }

    func start() async {
        do {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            let dataDir = support.appendingPathComponent("RichtextCore", isDirectory: true)
            var saved = UserDefaults.standard.stringArray(forKey: Self.foldersDefaultsKey) ?? []
            if saved.isEmpty,
               let legacy = UserDefaults.standard.string(forKey: Self.folderDefaultsKey) {
                saved = [legacy]
            }
            let core = try await Task.detached {
                try Core(dataDir: dataDir.path, serverUrl: nil)
            }.value
            self.core = core
            core.setDelegate(delegate: DelegateBridge(model: self))
            connected = core.isConnected()
            status = saved.isEmpty ? "Creating folder…" : "Opening folder…"
            let first = saved.first
            let url = try await Task.detached {
                try core.ensureFolder(existingUrl: first)
            }.value
            if saved.isEmpty {
                saved = [url]
            }
            rootFolderUrls = saved
            persistRoots()
            folderUrl = url
            // remaining roots arrive in the background; the tree fills in as
            // their docs land
            core.prefetchNotes(urls: Array(saved.dropFirst()))
            refreshNotes()
            status = ""
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
        do {
            _ = try core.createSubfolder(title: "New Folder")
            refreshNotes()
        } catch {
            status = "Couldn't create folder: \(error.localizedDescription)"
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

    private func buildTree() {
        guard let core, let root = rootFolderUrl else {
            folderTree = []
            return
        }
        var visited = Set<String>()
        func folderNode(url: String, name: String, parent: String?) -> FolderNode {
            guard visited.insert(url).inserted else {
                return FolderNode(url: url, name: name, kind: "folder", parentUrl: parent, children: [])
            }
            let entries = core.folderEntriesOf(url: url)
            var children: [FolderNode] = entries
                .filter { $0.kind == "folder" }
                .map { folderNode(url: $0.url, name: $0.name, parent: url) }
            children += entries
                .filter { $0.kind == "rich" }
                .map {
                    FolderNode(url: $0.url, name: $0.name, kind: "rich", parentUrl: url, children: nil)
                }
            return FolderNode(url: url, name: name, kind: "folder", parentUrl: parent, children: children)
        }
        _ = root
        folderTree = rootFolderUrls.map { url in
            let name = core.noteTitle(url: url)
            return folderNode(url: url, name: name.isEmpty ? "Notes" : name, parent: nil)
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

    func refreshNotes() {
        guard let core else { return }
        notes = core.listNotes()
        folderTitle = core.folderTitle()
        core.prefetchNotes(urls: notes.map(\.url))
        for note in notes where note.kind == "rich" {
            previews[note.url] = core.notePreview(url: note.url)
        }
        if let selected = selectedNoteUrl, !notes.contains(where: { $0.url == selected }) {
            selectedNoteUrl = nil
        }
        buildTree()
    }

    func docChanged(url: String) {
        if url == folderUrl || rootFolderUrls.contains(url) {
            refreshNotes()
        } else if isFolderInTree(url) {
            buildTree()
        } else if notes.contains(where: { $0.url == url }), let core {
            previews[url] = core.notePreview(url: url)
        }
        noteChanged(url)
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

    func createNote() {
        guard let core else { return }
        do {
            let url = try core.createNote(title: "")
            refreshNotes()
            selectedNoteUrl = url
        } catch {
            status = "Couldn't create note: \(error.localizedDescription)"
        }
    }

    func deleteNote(_ url: String) {
        guard let core else { return }
        do {
            try core.deleteNote(url: url)
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

    // Editor support -----------------------------------------------------

    func spansJSON(for url: String) async -> String {
        guard let core else { return "[]" }
        return await Task.detached {
            try? core.openNote(url: url)
            return (try? core.noteSpansJson(url: url)) ?? "[]"
        }.value
    }

    func updateSpans(_ url: String, json: String) async {
        guard let core else { return }
        await Task.detached {
            do {
                try core.updateNoteSpans(url: url, spansJson: json)
            } catch {
                // keep typing; the next debounce will retry
            }
        }.value
    }

    func search(_ query: String) -> [SearchHit] {
        guard let core, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return core.searchNotes(query: query)
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

    func updateTitleIfNeeded(_ url: String, title: String) async {
        guard let core else { return }
        let name = title.isEmpty ? "Untitled" : title
        guard let entry = notes.first(where: { $0.url == url }), entry.name != name else {
            return
        }
        let parent = node(for: url)?.parentUrl ?? folderUrl
        await Task.detached {
            if let parent {
                try? core.renameEntry(folderUrl: parent, url: url, title: name)
            } else {
                try? core.renameNote(url: url, title: name)
            }
        }.value
        refreshNotes()
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
        }
    }
}

extension NoteInfo: Identifiable {
    public var id: String { url }
}

struct FolderNode: Identifiable, Hashable {
    let url: String
    let name: String
    let kind: String
    let parentUrl: String?
    var children: [FolderNode]?

    var id: String { url }
}
