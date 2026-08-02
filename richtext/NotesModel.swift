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
                .filter { $0.kind != "folder" }
                .map {
                    FolderNode(url: $0.url, name: $0.name, kind: $0.kind, parentUrl: url, children: nil)
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
        for note in notes where note.kind == "lush" || note.kind == "rich" {
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

    #if os(macOS)
    var importStatus: String = ""

    func importAppleNotes() async {
        guard let core, let target = folderUrl else { return }
        importStatus = "Reading Apple Notes… (this can take a while)"
        await Task.yield()
        let notes: [AppleNotesImporter.ImportedNote]
        do {
            notes = try AppleNotesImporter.fetchNotes()
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
        var subfolders: [String: String] = [:]
        for entry in core.folderEntriesOf(url: importFolder) where entry.kind == "folder" {
            subfolders[entry.name] = entry.url
        }
        var existing: [String: Set<String>] = [:]
        var done = 0
        var skipped = 0
        var failed = 0
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
                let spans = AppleNotesImporter.spans(fromHTML: note.html)
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
                importStatus = "Imported \(done), skipped \(skipped)…"
                await Task.yield()
            }
        }
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
