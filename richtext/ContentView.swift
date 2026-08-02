import SwiftUI
#if os(iOS)
import PhotosUI
#endif

struct ContentView: View {
    @Environment(NotesModel.self) private var model
    @State private var editor = EditorController()
    @State private var recorder = AudioRecorder()
    #if os(iOS)
    @State private var showingSettings = false
    @State private var photoItem: PhotosPickerItem?
    #endif
    @State private var selectedItemUrl: String?
    @State private var searchText = ""
    @State private var searchHits: [SearchHit] = []
    @State private var renamingUrl: String?
    @State private var renameText = ""
    @FocusState private var renameFocus: String?
    @State private var expanded: Set<String> = []

    private static let expandedKey = "expandedFolders"
    private static let seededRootsKey = "seededRoots"

    private static let styles: [(key: String, label: String)] = [
        ("paragraph", "Body"),
        ("heading1", "Title"),
        ("heading2", "Heading"),
        ("heading3", "Subheading"),
        ("unordered-list-item", "Bulleted List"),
        ("ordered-list-item", "Numbered List"),
        ("blockquote", "Quote"),
        ("code-block", "Code"),
    ]

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .onChange(of: selectedItemUrl) {
            Task { await model.selectItem(selectedItemUrl) }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedItemUrl) {
            if searchText.isEmpty {
                nodeRows(model.folderTree)
            } else {
                ForEach(searchHits, id: \.url) { hit in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.name.isEmpty ? "Untitled" : hit.name)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(highlighted(hit.snippet))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .tag(hit.url)
                }
            }
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
                  let selected = selectedItemUrl,
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
                : "doc.text")
                .foregroundStyle(node.kind == "folder" ? Color.accentColor : .secondary)
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
                Text(displayName(node))
                    .lineLimit(1)
                    .simultaneousGesture(
                        TapGesture().onEnded { selectedItemUrl = node.url }
                    )
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded { beginRename(node) }
                    )
            }
        }
        .tag(node.url)
        .draggable(node.url)
        .modifier(FolderDropTarget(node: node, model: model))
        .contextMenu {
            Button("Rename") { beginRename(node) }
            Button(node.kind == "folder" ? "Copy Folder URL" : "Copy Note URL") {
                Clipboard.copy(node.url)
            }
            if node.parentUrl != nil {
                Button("Delete", role: .destructive) {
                    model.removeEntry(parentUrl: node.parentUrl, url: node.url)
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
            detailContent
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.createNote()
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                .disabled(model.folderUrl == nil)
            }
            #if os(iOS)
            ToolbarItem {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            #endif
        }
        #if os(iOS)
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
        #endif
    }

    @ViewBuilder
    private var detailContent: some View {
        if let url = model.selectedNoteUrl {
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
                RichTextEditor(noteUrl: url, model: model, controller: editor)
            }
                .id(url)
                .focusedSceneValue(\.editorController, editor)
                .toolbar {
                    ToolbarItem {
                        Menu {
                            Button {
                                editor.attachImageFromPanel()
                            } label: {
                                Label("Choose Photo…", systemImage: "photo.on.rectangle")
                            }
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
                                editor.insertHtmlBlock()
                            } label: {
                                Label("HTML Block", systemImage: "chevron.left.forwardslash.chevron.right")
                            }
                            Button {
                                editor.insertPatchworkDoc()
                            } label: {
                                Label("Patchwork Doc…", systemImage: "shippingbox")
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
                    ToolbarItem {
                        Picker("Style", selection: styleBinding) {
                            ForEach(Self.styles, id: \.key) { style in
                                Text(style.label).tag(style.key)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
                .sheet(item: Binding(
                    get: { editor.sheet },
                    set: { editor.sheet = $0 }
                )) { sheet in
                    EditorSheetView(sheet: sheet, controller: editor)
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
                #endif
        } else if !model.status.isEmpty {
            ContentUnavailableView {
                Label("Rich Text", systemImage: "doc.richtext")
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

    private func displayName(_ node: FolderNode) -> String {
        if node.name.isEmpty {
            return node.kind == "folder" ? "Untitled Folder" : "Untitled"
        }
        return node.name
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

    private func highlighted(_ snippet: String) -> AttributedString {
        var text = AttributedString(snippet)
        if let range = text.range(of: searchText, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].font = .caption.bold()
            text[range].foregroundColor = .primary
        }
        return text
    }

    private var styleBinding: Binding<String> {
        Binding(
            get: { editor.currentStyleKey },
            set: { editor.applyStyle($0) }
        )
    }
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
