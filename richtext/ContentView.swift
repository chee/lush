import SwiftUI
#if os(iOS)
import PhotosUI
#endif

enum NavRoute: Hashable {
    case folder(String)
    case note(String)
    case patchwork(String)
    case script(String)
    case recents
}

struct MoveTarget: Identifiable {
    let id = UUID()
    let urls: [String]
}

struct ContentView: View {
    @Environment(NotesModel.self) private var model
    @State private var router = AppRouter.shared
    #if os(macOS)
    @State private var selectedItemUrls: Set<String> = []
    @State private var searchText = ""
    @State private var searchHits: [SearchHit] = []
    @State private var renamingUrl: String?
    @State private var renameText = ""
    @FocusState private var renameFocus: String?
    @State private var expanded: Set<String> = []
    @State private var moveTarget: MoveTarget?

    private static let expandedKey = "expandedFolders"
    private static let seededRootsKey = "seededRoots"
    #else
    @State private var path: [NavRoute] = []
    #endif

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .onChange(of: selectedItemUrls) {
            guard selectedItemUrls.count == 1 else { return }
            let url = selectedItemUrls.first
            Task { await model.selectItem(url) }
        }
        .onOpenURL { url in
            if url.scheme == "richtext" {
                router.handle(url)
            } else if url.isFileURL {
                model.pendingIncoming = IncomingContent(payload: .file(url))
            }
        }
        .onChange(of: router.pending) { processPending() }
        .onChange(of: model.folderUrl) { processPending() }
        .sheet(item: Binding(
            get: { model.pendingIncoming },
            set: { model.pendingIncoming = $0 }
        )) { content in
            IncomingContentSheet(content: content)
                .environment(model)
        }
        #else
        NavigationStack(path: $path) {
            FolderScreen(folderUrl: nil) { path.append($0) }
                .navigationDestination(for: NavRoute.self) { route in
                    switch route {
                    case .folder(let url):
                        FolderScreen(folderUrl: url) { path.append($0) }
                    case .note(let url):
                        NoteDetail(noteUrl: url)
                            .onAppear { model.selectedNoteUrl = url }
                    case .patchwork(let url):
                        PatchworkDetail(docUrl: url)
                    case .script(let url):
                        ScriptEditorView(url: url)
                            .environment(model)
                    case .recents:
                        RecentsScreen()
                    }
                }
        }
        .onOpenURL { url in
            if url.scheme == "richtext" {
                router.handle(url)
            } else if url.isFileURL {
                model.pendingIncoming = IncomingContent(payload: .file(url))
            }
        }
        .onChange(of: router.pending) { processPending() }
        .onChange(of: model.folderUrl) { processPending() }
        .sheet(item: Binding(
            get: { model.pendingIncoming },
            set: { model.pendingIncoming = $0 }
        )) { content in
            IncomingContentSheet(content: content)
                .environment(model)
        }
        #endif
    }

    private func processPending() {
        guard let action = router.pending, model.folderUrl != nil else { return }
        router.pending = nil
        switch action {
        case .newNote:
            model.createNote()
            if let url = model.selectedNoteUrl {
                open(url)
            }
        case .quickNote:
            if let url = model.quickNoteUrl {
                open(url)
            } else {
                model.createNote()
                if let url = model.selectedNoteUrl {
                    open(url)
                }
            }
        case .note(let url):
            open(url)
        }
    }

    private func open(_ url: String) {
        #if os(macOS)
        model.selectedNoteUrl = url
        selectedItemUrls = [url]
        #else
        path = [.note(url)]
        #endif
    }

    #if os(macOS)

    private var sidebar: some View {
        List(selection: $selectedItemUrls) {
            if searchText.isEmpty {
                if !model.pinnedNodes.isEmpty {
                    Section("Pinned") {
                        ForEach(model.pinnedNodes) { node in
                            Label(node.displayName, systemImage: "pin.fill")
                                .lineLimit(1)
                                .tag(node.url)
                                .contextMenu {
                                    Button("Unpin") { model.togglePin(node.url) }
                                }
                        }
                    }
                }
                nodeRows(model.folderTree)
            } else {
                ForEach(searchHits, id: \.url) { hit in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.name.isEmpty ? "Untitled" : hit.name)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(highlighted(hit.snippet, query: searchText))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .tag(hit.url)
                    .contextMenu {
                        if let node = model.node(for: hit.url) {
                            Button(model.isPinned(node.url) ? "Unpin" : "Pin") {
                                model.togglePin(node.url)
                            }
                            Button(
                                model.quickNoteUrl == node.url
                                    ? "Unset Quick Note" : "Set as Quick Note"
                            ) {
                                model.setQuickNote(
                                    model.quickNoteUrl == node.url ? nil : node.url
                                )
                            }
                            if node.parentUrl != nil {
                                Button("Move…") { moveTarget = MoveTarget(urls: [node.url]) }
                            }
                            Button("Rename") { beginRename(node) }
                            Button("Copy Note URL") { Clipboard.copy(node.url) }
                            if node.parentUrl != nil {
                                Button("Delete", role: .destructive) {
                                    model.removeEntry(parentUrl: node.parentUrl, url: node.url)
                                }
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $moveTarget) { target in
            MoveSheet(urls: target.urls)
                .environment(model)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 230)
        .task {
            expanded = Set(
                UserDefaults.standard.stringArray(forKey: Self.expandedKey) ?? []
            )
        }
        .onChange(of: model.folderTree, initial: true) {
            seedRootExpansion()
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search notes")
        .toolbar {
            ToolbarItem {
                Button {
                    model.createFolder()
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .disabled(model.folderUrl == nil)
            }
        }
        .onChange(of: searchText) {
            searchHits = model.search(searchText)
        }
        .onChange(of: model.notes) {
            if !searchText.isEmpty {
                searchHits = model.search(searchText)
            }
        }
        .onKeyPress(.return) {
            guard renamingUrl == nil,
                  selectedItemUrls.count == 1,
                  let selected = selectedItemUrls.first,
                  let node = model.node(for: selected)
            else { return .ignored }
            beginRename(node)
            return .handled
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.connected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(model.connected ? "Synced" : "Offline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private func nodeRows(_ nodes: [FolderNode]) -> AnyView {
        AnyView(
            ForEach(nodes) { node in
                if node.kind == "folder" {
                    DisclosureGroup(isExpanded: expansionBinding(node.url)) {
                        nodeRows(node.children ?? [])
                    } label: {
                        row(for: node)
                    }
                } else {
                    row(for: node)
                }
            }
        )
    }

    private func expansionBinding(_ url: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(url) },
            set: { isOpen in
                if isOpen {
                    expanded.insert(url)
                } else {
                    expanded.remove(url)
                }
                UserDefaults.standard.set(Array(expanded), forKey: Self.expandedKey)
            }
        )
    }

    /// Expand each root folder the first time it appears; afterwards the
    /// user's fold state wins.
    private func seedRootExpansion() {
        var seeded = Set(
            UserDefaults.standard.stringArray(forKey: Self.seededRootsKey) ?? []
        )
        var changed = false
        for root in model.folderTree.map(\.url) where !seeded.contains(root) {
            expanded.insert(root)
            seeded.insert(root)
            changed = true
        }
        if changed {
            UserDefaults.standard.set(Array(seeded), forKey: Self.seededRootsKey)
            UserDefaults.standard.set(Array(expanded), forKey: Self.expandedKey)
        }
    }

    @ViewBuilder
    private func row(for node: FolderNode) -> some View {
        HStack(spacing: 6) {
            Image(systemName: node.kind == "folder"
                ? (node.parentUrl == nil ? "tray.full" : "folder")
                : node.kind == "lush:script" ? "scroll"
                : node.isNote ? "doc.text" : "shippingbox")
                .foregroundStyle(node.kind == "folder" ? Color.accentColor : .secondary)
                .allowsHitTesting(false)
            if renamingUrl == node.url {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.plain)
                    .focused($renameFocus, equals: node.url)
                    .onSubmit { commitRename(node) }
                    .onEscape {
                        renamingUrl = nil
                        renameFocus = nil
                    }
            } else {
                Text(node.displayName)
                    .lineLimit(1)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .tag(node.url)
        .draggable(node.url)
        .modifier(FolderDropTarget(node: node, model: model))
        .onTapGesture(count: 2) {
            guard selectedItemUrls.count == 1, selectedItemUrls.contains(node.url) else { return }
            beginRename(node)
        }
        .contextMenu {
            let targets = selectedItemUrls.contains(node.url)
                ? Array(selectedItemUrls)
                : [node.url]
            let many = targets.count > 1
            if (node.kind == "lush" || node.kind == "rich"), !many {
                Button(model.isPinned(node.url) ? "Unpin" : "Pin") {
                    model.togglePin(node.url)
                }
                Button(model.quickNoteUrl == node.url ? "Unset Quick Note" : "Set as Quick Note") {
                    model.setQuickNote(model.quickNoteUrl == node.url ? nil : node.url)
                }
            }
            if node.parentUrl != nil {
                Button(many ? "Move \(targets.count) Items…" : "Move…") {
                    moveTarget = MoveTarget(
                        urls: targets.filter { model.node(for: $0)?.parentUrl != nil }
                    )
                }
            }
            if !many {
                Button("Rename") { beginRename(node) }
                Button(node.kind == "folder" ? "Copy Folder URL" : "Copy Note URL") {
                    Clipboard.copy(node.url)
                }
            }
            if node.parentUrl != nil {
                Button(many ? "Delete \(targets.count) Items" : "Delete", role: .destructive) {
                    for url in targets {
                        if let target = model.node(for: url), target.parentUrl != nil {
                            model.removeEntry(parentUrl: target.parentUrl, url: url)
                        }
                    }
                }
            } else if model.rootFolderUrls.count > 1 {
                Button("Remove from Sidebar", role: .destructive) {
                    model.removeRootFolder(node.url)
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            if let url = model.selectedNoteUrl {
                if model.node(for: url)?.kind == "lush:script" {
                    ScriptEditorView(url: url)
                        .environment(model)
                        .id(url)
                } else if model.node(for: url)?.isNote != false {
                    NoteDetail(noteUrl: url)
                        .id(url)
                } else {
                    PatchworkDetail(docUrl: url)
                        .id(url)
                }
            } else if !model.status.isEmpty {
                ContentUnavailableView {
                    Label("Note", systemImage: "doc.richtext")
                } description: {
                    Text(model.status)
                }
            } else {
                ContentUnavailableView(
                    "No Note Selected",
                    systemImage: "doc.richtext",
                    description: Text("Select a note or create a new one.")
                )
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    Button {
                        model.createNote()
                    } label: {
                        Label("New Note", systemImage: "square.and.pencil")
                    }
                    Button {
                        model.createScript()
                    } label: {
                        Label("New Script", systemImage: "scroll")
                    }
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                } primaryAction: {
                    model.createNote()
                }
                .disabled(model.folderUrl == nil)
            }
        }
    }

    private func beginRename(_ node: FolderNode) {
        renameText = node.name
        renamingUrl = node.url
        renameFocus = node.url
    }

    private func commitRename(_ node: FolderNode) {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingUrl = nil
        renameFocus = nil
        guard !name.isEmpty, name != node.name else { return }
        model.renameEntry(parentUrl: node.parentUrl, url: node.url, to: name)
    }

    #endif
}

extension FolderNode {
    var displayName: String {
        if name.isEmpty {
            return kind == "folder" ? "Untitled Folder" : "Untitled"
        }
        return name
    }
}

func highlighted(_ snippet: String, query: String) -> AttributedString {
    var text = AttributedString(snippet)
    if let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
        text[range].font = .caption.bold()
        text[range].foregroundColor = .primary
    }
    return text
}

#if os(iOS)

/// Finder-style drill-down: one screen per folder, notes push the editor.
struct FolderScreen: View {
    let folderUrl: String?
    let push: (NavRoute) -> Void
    @Environment(NotesModel.self) private var model
    @State private var searchText = ""
    @State private var searchHits: [SearchHit] = []
    @State private var showingSettings = false
    @State private var renameTarget: FolderNode?
    @State private var renameText = ""
    @State private var moveTarget: MoveTarget?

    private var nodes: [FolderNode] {
        if let folderUrl {
            return model.node(for: folderUrl)?.children ?? []
        }
        return model.folderTree
    }

    private var title: String {
        guard let folderUrl else { return "Folders" }
        return model.node(for: folderUrl)?.displayName ?? "Folder"
    }

    var body: some View {
        List {
            if searchText.isEmpty, folderUrl == nil {
                Section {
                    NavigationLink(value: NavRoute.recents) {
                        Label("Recents", systemImage: "clock")
                    }
                    ForEach(model.pinnedNodes) { node in
                        NavigationLink(value: NavRoute.note(node.url)) {
                            Label(node.displayName, systemImage: "pin.fill")
                                .lineLimit(1)
                        }
                        .contextMenu { nodeMenu(node) }
                    }
                }
            }
            if searchText.isEmpty {
                OutlineGroup(nodes, children: \.children) { node in
                    NavigationLink(value: node.kind == "folder"
                        ? NavRoute.folder(node.url)
                        : node.kind == "lush:script"
                            ? NavRoute.script(node.url)
                            : node.isNote
                                ? NavRoute.note(node.url)
                                : NavRoute.patchwork(node.url)
                    ) {
                        Label(
                            node.displayName,
                            systemImage: node.kind == "folder" ? "folder"
                                : node.kind == "lush:script" ? "scroll"
                                : node.isNote ? "doc.text" : "shippingbox"
                        )
                        .lineLimit(1)
                    }
                    .contextMenu { nodeMenu(node) }
                }
            } else {
                ForEach(searchHits, id: \.url) { hit in
                    NavigationLink(value: NavRoute.note(hit.url)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.name.isEmpty ? "Untitled" : hit.name)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Text(highlighted(hit.snippet, query: searchText))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .contextMenu {
                        if let node = model.node(for: hit.url) {
                            nodeMenu(node)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .searchable(text: $searchText, prompt: "Search notes")
        .onChange(of: searchText) {
            searchHits = model.search(searchText)
        }
        .onAppear {
            if let folderUrl {
                Task { await model.selectFolder(folderUrl) }
            }
        }
        .toolbar {
            if folderUrl == nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            ToolbarItem {
                Button {
                    model.createFolder()
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .disabled(model.folderUrl == nil)
            }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Menu {
                    Button {
                        model.createNote()
                        if let url = model.selectedNoteUrl { push(.note(url)) }
                    } label: {
                        Label("New Note", systemImage: "square.and.pencil")
                    }
                    Button {
                        model.createScript()
                        if let url = model.selectedNoteUrl { push(.script(url)) }
                    } label: {
                        Label("New Script", systemImage: "scroll")
                    }
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                } primaryAction: {
                    model.createNote()
                    if let url = model.selectedNoteUrl { push(.note(url)) }
                }
                .disabled(model.folderUrl == nil)
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView()
                    .environment(model)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingSettings = false }
                        }
                    }
            }
        }
        .sheet(item: $moveTarget) { target in
            MoveSheet(urls: target.urls)
                .environment(model)
        }
        .alert(
            "Rename",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let node = renameTarget {
                    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty, name != node.name {
                        model.renameEntry(parentUrl: node.parentUrl, url: node.url, to: name)
                    }
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    @ViewBuilder
    private func nodeMenu(_ node: FolderNode) -> some View {
        if node.kind == "lush" || node.kind == "rich" {
            Button(model.isPinned(node.url) ? "Unpin" : "Pin") {
                model.togglePin(node.url)
            }
            Button(model.quickNoteUrl == node.url ? "Unset Quick Note" : "Set as Quick Note") {
                model.setQuickNote(model.quickNoteUrl == node.url ? nil : node.url)
            }
        }
        if node.parentUrl != nil {
            Button("Move…") { moveTarget = MoveTarget(urls: [node.url]) }
        }
        Button("Rename") {
            renameText = node.name
            renameTarget = node
        }
        Button(node.kind == "folder" ? "Copy Folder URL" : "Copy Note URL") {
            Clipboard.copy(node.url)
        }
        if node.parentUrl != nil {
            Button("Delete", role: .destructive) {
                model.removeEntry(parentUrl: node.parentUrl, url: node.url)
            }
        } else if model.rootFolderUrls.count > 1 {
            Button("Remove", role: .destructive) {
                model.removeRootFolder(node.url)
            }
        }
    }
}

struct RecentsScreen: View {
    @Environment(NotesModel.self) private var model
    @State private var moveTarget: MoveTarget?

    var body: some View {
        List(model.recentNotes(), id: \.node.url) { entry in
            NavigationLink(value: NavRoute.note(entry.node.url)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.node.displayName)
                        .lineLimit(1)
                    Text(entry.modified, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contextMenu {
                Button(model.isPinned(entry.node.url) ? "Unpin" : "Pin") {
                    model.togglePin(entry.node.url)
                }
                Button(
                    model.quickNoteUrl == entry.node.url
                        ? "Unset Quick Note" : "Set as Quick Note"
                ) {
                    model.setQuickNote(
                        model.quickNoteUrl == entry.node.url ? nil : entry.node.url
                    )
                }
                Button("Move…") { moveTarget = MoveTarget(urls: [entry.node.url]) }
                Button("Copy Note URL") { Clipboard.copy(entry.node.url) }
            }
        }
        .navigationTitle("Recents")
        .sheet(item: $moveTarget) { target in
            MoveSheet(urls: target.urls)
                .environment(model)
        }
    }
}

#endif

/// Pick a destination folder by name — the tap-friendly stand-in for
/// drag and drop.
struct MoveSheet: View {
    let urls: [String]
    @Environment(NotesModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var choices: [(url: String, path: String)] {
        let all = model.folderChoices(excluding: Set(urls))
        guard !search.isEmpty else { return all }
        return all.filter { $0.path.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List(choices, id: \.url) { choice in
                Button {
                    for url in urls {
                        model.moveItem(url, into: choice.url)
                    }
                    dismiss()
                } label: {
                    Label(choice.path, systemImage: "folder")
                        .foregroundStyle(.primary)
                }
            }
            .searchable(text: $search, prompt: "Search folders")
            .navigationTitle(urls.count > 1 ? "Move \(urls.count) Items To" : "Move To")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 380)
        #endif
    }
}

/// The note editor screen, shared between the macOS detail column and the
/// iOS pushed route.
struct NoteDetail: View {
    let noteUrl: String
    @Environment(NotesModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editor = EditorController()
    @State private var recorder = AudioRecorder()
    @State private var renameText = ""
    @State private var showingRename = false
    @State private var moveTarget: MoveTarget?
    #if os(iOS)
    @State private var photoItem: PhotosPickerItem?
    #endif

    private var currentNode: FolderNode? { model.node(for: noteUrl) }

    var body: some View {
        VStack(spacing: 0) {
            if editor.recorderVisible {
                RecorderBar(recorder: recorder) { data in
                    editor.recorderVisible = false
                    if let data {
                        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
                        editor.insertRecording(data: data, name: "Recording \(stamp).m4a")
                    }
                }
            }
            RichTextEditor(noteUrl: noteUrl, model: model, controller: editor)
        }
        .focusedSceneValue(\.editorController, editor)
        .dropDestination(for: String.self) { urls, _ in
            guard let url = urls.first(where: { $0.hasPrefix("automerge:") }) else { return false }
            editor.insertPatchworkEmbed(url: url, tool: nil)
            return true
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button {
                        editor.attachImageFromPanel()
                    } label: {
                        Label("Choose Photo…", systemImage: "photo.on.rectangle")
                    }
                    #if os(iOS)
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            editor.cameraPickerVisible = true
                        } label: {
                            Label("Take Photo", systemImage: "camera")
                        }
                    }
                    #endif
                    Button {
                        editor.recorderVisible.toggle()
                    } label: {
                        Label("Record Audio", systemImage: "waveform")
                    }
                    Button {
                        editor.attachFileFromPanel()
                    } label: {
                        Label("Attach File…", systemImage: "doc")
                    }
                    Divider()
                    Button {
                        editor.insertTable()
                    } label: {
                        Label("Table", systemImage: "tablecells")
                    }
                    Button {
                        editor.insertColumns()
                    } label: {
                        Label("Columns", systemImage: "rectangle.split.2x1")
                    }
                    Button {
                        editor.insertHtmlBlock()
                    } label: {
                        Label("HTML Block", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Button {
                        editor.insertPatchworkDoc()
                    } label: {
                        Label("Patchwork Doc…", systemImage: "shippingbox")
                    }
                    Divider()
                    Button {
                        Clipboard.copy(noteUrl)
                    } label: {
                        Label("Copy Note URL", systemImage: "link")
                    }
                } label: {
                    Label("Attach", systemImage: "paperclip")
                }
            }
            ToolbarItem {
                Menu {
                    ForEach(Highlight.names, id: \.self) { name in
                        Button {
                            editor.applyHighlight(name)
                        } label: {
                            if editor.highlightActive == name {
                                Label(name.capitalized, systemImage: "checkmark")
                            } else {
                                Text(name.capitalized)
                            }
                        }
                    }
                    Divider()
                    Button("None") { editor.applyHighlight(nil) }
                } label: {
                    Label("Highlight", systemImage: "highlighter")
                }
            }
            #if os(macOS)
            ToolbarItem {
                Picker("Style", selection: styleBinding) {
                    ForEach(EditorController.styles, id: \.key) { style in
                        Text(style.label).tag(style.key)
                    }
                }
                .pickerStyle(.menu)
            }
            #endif
            ToolbarItem {
                Menu {
                    if let node = currentNode {
                        if node.kind == "lush" || node.kind == "rich" {
                            Button(model.isPinned(noteUrl) ? "Unpin" : "Pin") {
                                model.togglePin(noteUrl)
                            }
                            Button(model.quickNoteUrl == noteUrl ? "Unset Quick Note" : "Set as Quick Note") {
                                model.setQuickNote(model.quickNoteUrl == noteUrl ? nil : noteUrl)
                            }
                            Divider()
                        }
                        if node.parentUrl != nil {
                            Button("Move…") { moveTarget = MoveTarget(urls: [noteUrl]) }
                        }
                        Button("Rename") {
                            renameText = node.name
                            showingRename = true
                        }
                        Button("Copy Note URL") { Clipboard.copy(noteUrl) }
                        if node.parentUrl != nil {
                            Divider()
                            Button("Delete", role: .destructive) {
                                model.removeEntry(parentUrl: node.parentUrl, url: noteUrl)
                                #if os(macOS)
                                model.selectedNoteUrl = nil
                                #else
                                dismiss()
                                #endif
                            }
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .disabled(currentNode == nil)
            }
        }
        .sheet(item: Binding(
            get: { editor.sheet },
            set: { editor.sheet = $0 }
        )) { sheet in
            EditorSheetView(sheet: sheet, controller: editor)
        }
        .alert("Rename", isPresented: $showingRename) {
            TextField("Name", text: $renameText)
            Button("Save") {
                guard let node = currentNode else { return }
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, name != node.name {
                    model.renameEntry(parentUrl: node.parentUrl, url: noteUrl, to: name)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $moveTarget) { target in
            MoveSheet(urls: target.urls).environment(model)
        }
        #if os(iOS)
        .photosPicker(
            isPresented: Binding(
                get: { editor.photoPickerVisible },
                set: { editor.photoPickerVisible = $0 }
            ),
            selection: $photoItem,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: photoItem) {
            guard let item = photoItem else { return }
            photoItem = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    return
                }
                let ext = item.supportedContentTypes.first?
                    .preferredFilenameExtension ?? "png"
                let stamp = Int(Date().timeIntervalSince1970)
                editor.insertData(data, name: "photo-\(stamp).\(ext)")
            }
        }
        .fileImporter(
            isPresented: Binding(
                get: { editor.filePickerVisible },
                set: { editor.filePickerVisible = $0 }
            ),
            allowedContentTypes: [.item]
        ) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            if let data = try? Data(contentsOf: url) {
                editor.insertData(data, name: url.lastPathComponent)
            }
        }
        .sheet(isPresented: Binding(
            get: { editor.cameraPickerVisible },
            set: { editor.cameraPickerVisible = $0 }
        )) {
            CameraPicker { image in
                guard let data = image.jpegData(compressionQuality: 0.85) else { return }
                let stamp = Int(Date().timeIntervalSince1970)
                editor.insertData(data, name: "photo-\(stamp).jpg")
            }
        }
        #endif
    }

    #if os(macOS)
    private var styleBinding: Binding<String> {
        Binding(
            get: { editor.currentStyleKey },
            set: { editor.applyStyle($0) }
        )
    }
    #endif
}

private struct FolderDropTarget: ViewModifier {
    let node: FolderNode
    let model: NotesModel

    func body(content: Content) -> some View {
        if node.kind == "folder" {
            content.dropDestination(for: String.self) { items, _ in
                guard let moved = items.first else { return false }
                model.moveItem(moved, into: node.url)
                return true
            }
        } else {
            content
        }
    }
}

struct PatchworkDetail: View {
    let docUrl: String
    @Environment(NotesModel.self) private var model

    var body: some View {
        Group {
            if PatchworkWeb.available {
                PatchworkWebView(docUrl: docUrl, toolId: nil)
            } else {
                ContentUnavailableView(
                    "Patchwork Unavailable",
                    systemImage: "shippingbox",
                    description: Text("Add PatchworkWeb.bundle to render this document.")
                )
            }
        }
        .navigationTitle(model.node(for: docUrl)?.displayName ?? "")
    }
}

struct IncomingContentSheet: View {
    let content: IncomingContent
    @Environment(NotesModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var displayTitle: String {
        switch content.payload {
        case .text(let t): return String(t.prefix(50)).components(separatedBy: .newlines).first ?? "Import"
        case .file(let url): return url.lastPathComponent
        }
    }

    private var allNotes: [FolderNode] {
        var out: [FolderNode] = []
        func walk(_ nodes: [FolderNode]) {
            for node in nodes {
                if node.isNote { out.append(node) }
                if let ch = node.children { walk(ch) }
            }
        }
        walk(model.folderTree)
        return out
    }

    private var filtered: [FolderNode] {
        search.isEmpty ? allNotes
            : allNotes.filter { $0.displayName.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        model.importAsNewNote(content)
                        dismiss()
                    } label: {
                        Label("New Note", systemImage: "square.and.pencil")
                            .foregroundStyle(.primary)
                    }
                }
                if !allNotes.isEmpty {
                    Section("Open in existing note") {
                        ForEach(filtered) { note in
                            Button {
                                if case .text(let text) = content.payload {
                                    Clipboard.copy(text)
                                }
                                model.selectedNoteUrl = note.url
                                dismiss()
                            } label: {
                                Text(note.displayName.isEmpty ? "Untitled" : note.displayName)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search notes")
            .navigationTitle(displayTitle.isEmpty ? "Import" : displayTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 400)
        #endif
    }
}

#if os(iOS)
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
#endif
