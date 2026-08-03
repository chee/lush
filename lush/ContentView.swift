import SwiftUI
import UniformTypeIdentifiers
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
    @Environment(ContextTracker.self) private var contextTracker
    @State private var router = AppRouter.shared
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @State private var selectedItemUrls: Set<String> = []
    @State private var searchText = ""
    @State private var searchHits: [SearchHit] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var renamingUrl: String?
    @State private var renameText = ""
    @FocusState private var renameFocus: String?
    @FocusState private var sidebarFocused: Bool
    @State private var expanded: Set<String> = []
    @State private var moveTarget: MoveTarget?
    @State private var pinnedExpanded = true
    @State private var showingNewPatchwork = false

    private static let expandedKey = "expandedFolders"
    private static let seededRootsKey = "seededRoots"
    private static let pinnedExpandedKey = "pinnedExpanded"
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
            sidebarFocused = true
            guard selectedItemUrls.count == 1, let tag = selectedItemUrls.first else { return }
            let url = tag.hasPrefix("pinned:") ? String(tag.dropFirst(7)) : tag
            if let node = model.node(for: url), node.kind == "folder" {
                Task { await model.selectFolder(url) }
            }
        }
        .onOpenURL { url in
            if url.scheme == "lush" {
                router.handle(url)
            } else if url.isFileURL {
                model.pendingIncoming = IncomingContent(payload: .file(url))
            }
        }
        .onChange(of: router.pending) { processPending() }
        .onChange(of: model.folderUrl) { processPending() }
        .onChange(of: model.selectedNoteUrl) { _, url in
            guard let url else { return }
            if !selectedItemUrls.contains(url) { selectedItemUrls = [url] }
        }
        .sheet(item: Binding(
            get: { model.pendingIncoming },
            set: { model.pendingIncoming = $0 }
        )) { content in
            IncomingContentSheet(content: content)
                .environment(model)
        }
        .sheet(isPresented: $showingNewPatchwork) {
            NewPatchworkDocSheet { url, _ in
                model.selectedNoteUrl = url
                selectedItemUrls = [url]
            }
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
                        RecentsScreen(push: { path.append($0) })
                    }
                }
        }
        .onOpenURL { url in
            if url.scheme == "lush" {
                router.handle(url)
            } else if url.isFileURL {
                model.pendingIncoming = IncomingContent(payload: .file(url))
            }
        }
        .onChange(of: router.pending) { processPending() }
        .onChange(of: model.folderUrl) { processPending() }
        .onChange(of: model.selectedNoteUrl) { _, url in
            guard let url, path.isEmpty else { return }
            path = [.note(url)]
        }
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
            model.createNote(snap: contextTracker.snapshot)
            if let url = model.selectedNoteUrl {
                open(url)
            }
        case .quickNote:
            if let url = model.quickNoteUrl {
                model.pendingFocusUrl = url
                open(url)
            } else {
                model.createNote(snap: contextTracker.snapshot)
                if let url = model.selectedNoteUrl {
                    open(url)
                }
            }
        case .note(let url):
            model.pendingFocusUrl = url
            open(url)
        case .search(let query):
            #if os(macOS)
            searchText = query
            searchTask?.cancel()
            searchTask = Task { searchHits = await model.search(query) }
            #endif
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
                    pinnedRootRow
                        .listRowInsets(sidebarRowInsets(depth: 0))
                    if pinnedExpanded {
                        ForEach(model.pinnedNodes) { node in
                            NoteRowView(node: node, showFolder: true)
                                .contentShape(Rectangle())
                                .padding(.leading, 12)
                                .onTapGesture {
                                    selectedItemUrls = ["pinned:\(node.url)"]
                                    Task { await model.selectItem(node.url) }
                                }
                                .tag("pinned:\(node.url)")
                                .onDrag { NSItemProvider(object: node.url as NSString) }
                                .listRowInsets(sidebarRowInsets(depth: 1))
                                .listRowBackground(selectionBackground("pinned:\(node.url)", greyWhen: node.url))
                                .contextMenu {
                                    singleNoteContextMenu(for: node, showInFolder: true)
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
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await model.selectItem(hit.url) } }
                    .tag(hit.url)
                    .onDrag { NSItemProvider(object: hit.url as NSString) }
                    .listRowInsets(sidebarRowInsets(depth: 0))
                    .contextMenu {
                        if let node = model.node(for: hit.url) {
                            singleNoteContextMenu(for: node, showInFolder: true)
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
            if UserDefaults.standard.object(forKey: Self.pinnedExpandedKey) != nil {
                pinnedExpanded = UserDefaults.standard.bool(forKey: Self.pinnedExpandedKey)
            }
        }
        .onChange(of: model.folderTree, initial: true) {
            seedRootExpansion()
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search notes")
        .toolbar {
            ToolbarItem {
                ControlGroup {
                    Button {
                        model.createNote(snap: contextTracker.snapshot)
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    Menu {
                        Button("Note") { model.createNote(snap: contextTracker.snapshot) }
                        if PatchworkWeb.available {
                            Button("Patchwork Doc…") { showingNewPatchwork = true }
                        }
                    } label: {
                        Image(systemName: "chevron.down.compact")
                    }
                }
                .disabled(model.folderUrl == nil)
            }
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
            searchTask?.cancel()
            searchTask = Task { searchHits = await model.search(searchText) }
        }
        .onChange(of: model.notes) {
            if !searchText.isEmpty {
                searchTask?.cancel()
                searchTask = Task { searchHits = await model.search(searchText) }
            }
        }
        .onChange(of: model.folderTree) {
            if !searchText.isEmpty {
                searchTask?.cancel()
                searchTask = Task { searchHits = await model.search(searchText) }
            }
        }
        .onKeyPress(.return) {
            guard renamingUrl == nil,
                  selectedItemUrls.count == 1,
                  let tag = selectedItemUrls.first
            else { return .ignored }
            let selected = tag.hasPrefix("pinned:") ? String(tag.dropFirst(7)) : tag
            if let node = model.node(for: selected), node.kind == "folder" {
                setExpanded(!expanded.contains(selected), for: selected)
            } else {
                Task { await model.selectItem(selected) }
            }
            return .handled
        }
        .onKeyPress(.space) {
            guard selectedItemUrls.count == 1, let tag = selectedItemUrls.first else { return .ignored }
            let selected = tag.hasPrefix("pinned:") ? String(tag.dropFirst(7)) : tag
            guard let node = model.node(for: selected), node.kind == "folder" else { return .ignored }
            setExpanded(!expanded.contains(selected), for: selected)
            return .handled
        }
        .onKeyPress(.delete) {
            guard renamingUrl == nil, !selectedItemUrls.isEmpty else { return .ignored }
            for tag in selectedItemUrls {
                let url = tag.hasPrefix("pinned:") ? String(tag.dropFirst(7)) : tag
                if let node = model.node(for: url), node.parentUrl != nil {
                    model.removeEntry(parentUrl: node.parentUrl, url: url)
                }
            }
            return .handled
        }
        .focused($sidebarFocused)
        .tint(Color(red: 1.0, green: 0.412, blue: 0.647))
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.connected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(model.connected ? "Connected to Sync Server" : "Offline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private func nodeRows(_ nodes: [FolderNode], depth: Int = 0) -> AnyView {
        AnyView(
            ForEach(nodes) { node in
                if node.kind == "folder" {
                    folderRow(for: node, depth: depth)
                        .tag(node.url)
                        .listRowInsets(sidebarRowInsets(depth: depth))
                    if expanded.contains(node.url) {
                        nodeRows(node.children ?? [], depth: depth + 1)
                    }
                } else {
                    noteRow(for: node, depth: depth)
                        .listRowInsets(sidebarRowInsets(depth: depth))
                        .listRowBackground(
                            selectionBackground(node.url, greyWhen: model.isPinned(node.url) ? "pinned:\(node.url)" : nil)
                        )
                }
            }
        )
    }

    private func sidebarRowInsets(depth: Int) -> EdgeInsets {
        EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 8)
    }

    private var pinnedRootRow: some View {
        HStack(spacing: 8) {
            Label("Pinned", systemImage: "pin.fill")
                .font(.title3.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                pinnedExpansionBinding.wrappedValue.toggle()
            } label: {
                Image(systemName: pinnedExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 12)
        .padding(.bottom, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            pinnedExpansionBinding.wrappedValue.toggle()
        }
    }

    @ViewBuilder
    private func selectionBackground(_ tag: String, greyWhen greyTag: String? = nil) -> some View {
        if selectedItemUrls.contains(tag) {
            Color.clear
        } else if let greyTag, selectedItemUrls.contains(greyTag) {
            Color.secondary.opacity(0.12)
        }
    }

    private func expansionBinding(_ url: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(url) },
            set: { isOpen in
                setExpanded(isOpen, for: url)
            }
        )
    }

    private func setExpanded(_ isOpen: Bool, for url: String) {
        if isOpen {
            expanded.insert(url)
            Task { await model.loadFolder(url: url) }
        } else {
            expanded.remove(url)
        }
        UserDefaults.standard.set(Array(expanded), forKey: Self.expandedKey)
    }

    private var pinnedExpansionBinding: Binding<Bool> {
        Binding(
            get: { pinnedExpanded },
            set: { isOpen in
                pinnedExpanded = isOpen
                UserDefaults.standard.set(isOpen, forKey: Self.pinnedExpandedKey)
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
    private func folderRow(for node: FolderNode, depth: Int) -> some View {
        HStack(spacing: 8) {
            if renamingUrl == node.url {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.plain)
                    .focused($renameFocus, equals: node.url)
                    .onSubmit { commitRename(node) }
                    .onEscape { renamingUrl = nil; renameFocus = nil }
            } else {
                HStack(spacing: 8) {
                    if depth == 0 {
                        Text(node.displayName)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    } else {
                        Label(node.displayName, systemImage: "folder")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    setExpanded(!expanded.contains(node.url), for: node.url)
                }
            }
            Button {
                setExpanded(!expanded.contains(node.url), for: node.url)
            } label: {
                Image(systemName: expanded.contains(node.url) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(depth) * 8)
        .padding(.top, depth == 0 ? 12 : 2)
        .padding(.bottom, depth == 0 ? 5 : 2)
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(object: node.url as NSString) }
        .modifier(FolderDropTarget(node: node, model: model))
        .contextMenu {
            folderContextMenu(for: node)
        }
    }

    @ViewBuilder
    private func folderContextMenu(for node: FolderNode) -> some View {
        Menu("New") {
            Button("Note") { model.createNote(inFolder: node.url) }
            Button("Folder") { model.createSubfolder(in: node.url) }
        }
        if !model.rootFolderUrls.contains(node.url) {
            Button("Pin Folder to Sidebar") {
                Task { await model.addRootFolder(node.url) }
            }
        }
        Button("Rename") { beginRename(node) }
        Button("Copy Folder URL") { Clipboard.copy(node.url) }
        if node.parentUrl != nil {
            Button("Move…") { moveTarget = MoveTarget(urls: [node.url]) }
            Button("Delete", role: .destructive) {
                model.removeEntry(parentUrl: node.parentUrl, url: node.url)
            }
        } else if model.rootFolderUrls.count > 1 {
            Button("Remove from Sidebar", role: .destructive) {
                model.removeRootFolder(node.url)
            }
        }
    }

    @ViewBuilder
    private func noteRow(for node: FolderNode, depth: Int = 0) -> some View {
        NoteRowView(node: node)
            .contentShape(Rectangle())
            .padding(.leading, CGFloat(depth) * 8 + 4)
            .onTapGesture {
                let flags = NSEvent.modifierFlags
                if flags.contains(.command) {
                    if selectedItemUrls.contains(node.url) {
                        selectedItemUrls.remove(node.url)
                    } else {
                        selectedItemUrls.insert(node.url)
                    }
                } else {
                    selectedItemUrls = [node.url]
                    Task { await model.selectItem(node.url) }
                }
            }
            .tag(node.url)
            .onDrag { NSItemProvider(object: node.url as NSString) }
            .contextMenu {
                let targets = selectedItemUrls.contains(node.url)
                    ? Array(selectedItemUrls)
                    : [node.url]
                let many = targets.count > 1
                if (node.kind == "lush" || node.kind == "rich"), !many {
                    Button("Open in New Window") { openWindow(id: "note-detail", value: node.url) }
                    Divider()
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
                    Button("Copy Note URL") { Clipboard.copy(node.url) }
                }
                if node.parentUrl != nil {
                    Button(many ? "Delete \(targets.count) Items" : "Delete", role: .destructive) {
                        for url in targets {
                            if let target = model.node(for: url), target.parentUrl != nil {
                                model.removeEntry(parentUrl: target.parentUrl, url: url)
                            }
                        }
                    }
                }
            }
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            if let url = model.selectedNoteUrl {
                detailContent(for: url)
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
                ControlGroup {
                    Button {
                        model.createNote(snap: contextTracker.snapshot)
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    Menu {
                        Button("Note") { model.createNote(snap: contextTracker.snapshot) }
                        if PatchworkWeb.available {
                            Button("Patchwork Doc…") { showingNewPatchwork = true }
                        }
                    } label: {
                        Image(systemName: "chevron.down.compact")
                    }
                }
                .disabled(model.folderUrl == nil)
            }
        }
    }

    @ViewBuilder
    private func detailContent(for url: String) -> some View {
        if model.node(for: url)?.kind == "lush:script" {
            ScriptEditorView(url: url)
                .environment(model)
                .id(url)
        } else if model.node(for: url)?.isNote != false && !url.hasPrefix("automerge:") {
            NoteDetail(noteUrl: url)
                .id(url)
        } else {
            PatchworkDetail(docUrl: url)
                .id(url)
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

    private func showNoteInFolder(_ node: FolderNode) {
        searchText = ""
        var url: String? = node.parentUrl
        while let u = url {
            expanded.insert(u)
            url = model.node(for: u)?.parentUrl
        }
        UserDefaults.standard.set(Array(expanded), forKey: Self.expandedKey)
        selectedItemUrls = [node.url]
        Task { await model.selectItem(node.url) }
    }

    @ViewBuilder
    private func singleNoteContextMenu(for node: FolderNode, showInFolder: Bool = false) -> some View {
        if node.kind == "lush" || node.kind == "rich" {
            Button("Open in New Window") {
                openWindow(id: "note-detail", value: node.url)
            }
            Divider()
            Button(model.isPinned(node.url) ? "Unpin" : "Pin") {
                model.togglePin(node.url)
            }
            Button(model.quickNoteUrl == node.url ? "Unset Quick Note" : "Set as Quick Note") {
                model.setQuickNote(model.quickNoteUrl == node.url ? nil : node.url)
            }
            if showInFolder {
                Button("Show in Folder") { showNoteInFolder(node) }
            }
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

    #endif
}

#if os(macOS)
private struct SuppressListSelectionHighlight: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            var v: NSView? = nsView
            while let current = v {
                if let scroll = current as? NSScrollView,
                   let table = scroll.documentView as? NSTableView {
                    table.selectionHighlightStyle = .none
                    return
                }
                v = current.superview
            }
        }
    }
}
#endif

extension FolderNode {
    var displayName: String {
        if name.isEmpty {
            return kind == "folder" ? "Untitled Folder" : "Untitled"
        }
        return name
    }
}

struct NoteRowView: View {
    let node: FolderNode
    var showFolder: Bool = false
    @Environment(NotesModel.self) private var model

    private var meta: NoteContextMeta? { model.contextMetas[node.url] }

    private var secondLine: String {
        var parts: [String] = []
        if let d = meta?.created {
            parts.append(d.formatted(.dateTime.month(.abbreviated).day().year()))
        }
        if let loc = meta?.location { parts.append(loc) }
        if let w = meta?.weather { parts.append(w) }
        if let np = meta?.nowPlaying { parts.append(np) }
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(node.displayName)
                        .font(.body)
                        .lineLimit(1)
                    if !node.isNote && node.kind != "lush:script" {
                        Text(node.kind)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                    }
                    Spacer(minLength: 0)
                }
                if !secondLine.isEmpty {
                    Text(secondLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let preview = model.previews[node.url], !preview.isEmpty {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
                if showFolder, let parent = node.parentUrl,
                   let parentNode = model.node(for: parent) {
                    Label(parentNode.displayName, systemImage: "folder")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let data = model.thumbnails[node.url],
               let thumbnail = thumbnailImage(from: data) {
                thumbnail
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 2)
        #if os(macOS)
        .onDrag { NSItemProvider(object: node.url as NSString) }
        #endif
        .task { await model.loadContextMeta(url: node.url) }
    }
}

private func thumbnailImage(from data: Data) -> Image? {
    #if os(macOS)
    guard let ns = NSImage(data: data) else { return nil }
    return Image(nsImage: ns)
    #else
    guard let ui = UIImage(data: data) else { return nil }
    return Image(uiImage: ui)
    #endif
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
    @Environment(ContextTracker.self) private var contextTracker
    @State private var searchText = ""
    @State private var searchHits: [SearchHit] = []
    @State private var showingSettings = false
    @State private var showingNewPatchwork = false
    @State private var renameTarget: FolderNode?
    @State private var renameText = ""
    @State private var moveTarget: MoveTarget?
    @State private var pinnedExpanded = true

    private static let pinnedExpandedKey = "pinnedExpanded"

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
                Section(isExpanded: pinnedExpansionBinding) {
                    NavigationLink(value: NavRoute.recents) {
                        Label("Recents", systemImage: "clock")
                    }
                    ForEach(model.pinnedNodes) { node in
                        NavigationLink(value: NavRoute.note(node.url)) {
                            NoteRowView(node: node, showFolder: true)
                        }
                        .contextMenu {
                            nodeMenu(node)
                            if let parentUrl = node.parentUrl {
                                Button("Show in Folder") { push(.folder(parentUrl)) }
                            }
                        }
                    }
                } header: {
                    Text("Pinned")
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
                        if node.kind == "folder" {
                            Label(node.displayName, systemImage: "folder")
                                .lineLimit(1)
                        } else {
                            NoteRowView(node: node)
                        }
                    }
                    .contextMenu { nodeMenu(node) }
                }
            } else {
                ForEach(searchHits, id: \.url) { hit in
                    NavigationLink(value: NavRoute.note(hit.url)) {
                        if let node = model.node(for: hit.url) {
                            NoteRowView(node: node)
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.name.isEmpty ? "Untitled" : hit.name)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text(highlighted(hit.snippet, query: searchText))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .contextMenu {
                        if let node = model.node(for: hit.url) {
                            nodeMenu(node)
                            if let parentUrl = node.parentUrl {
                                Button("Show in Folder") { push(.folder(parentUrl)) }
                            }
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
            if UserDefaults.standard.object(forKey: Self.pinnedExpandedKey) != nil {
                pinnedExpanded = UserDefaults.standard.bool(forKey: Self.pinnedExpandedKey)
            }
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
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Menu {
                    Button {
                        model.createNote(snap: contextTracker.snapshot)
                        if let url = model.selectedNoteUrl { push(.note(url)) }
                    } label: {
                        Label("Note", systemImage: "square.and.pencil")
                    }
                    if PatchworkWeb.available {
                        Button {
                            showingNewPatchwork = true
                        } label: {
                            Label("Patchwork Doc…", systemImage: "shippingbox")
                        }
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.title2)
                        .padding(16)
                        .background(.regularMaterial, in: Circle())
                }
                .disabled(model.folderUrl == nil)
                .padding(.trailing)
            }
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showingNewPatchwork) {
            NewPatchworkDocSheet { url, _ in
                push(.patchwork(url))
            }
            .environment(model)
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
        if node.kind == "folder" {
            Menu("New") {
                Button("Note") { model.createNote(inFolder: node.url) }
                Button("Folder") { model.createSubfolder(in: node.url) }
            }
        }
        if node.kind == "folder", !model.rootFolderUrls.contains(node.url) {
            Button("Pin Folder to Sidebar") {
                Task { await model.addRootFolder(node.url) }
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

    private var pinnedExpansionBinding: Binding<Bool> {
        Binding(
            get: { pinnedExpanded },
            set: { isOpen in
                pinnedExpanded = isOpen
                UserDefaults.standard.set(isOpen, forKey: Self.pinnedExpandedKey)
            }
        )
    }
}

struct RecentsScreen: View {
    let push: (NavRoute) -> Void
    @Environment(NotesModel.self) private var model
    @State private var moveTarget: MoveTarget?
    @State private var renameTarget: FolderNode?
    @State private var renameText = ""

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
                if let parentUrl = entry.node.parentUrl {
                    Button("Show in Folder") { push(.folder(parentUrl)) }
                }
                Button("Move…") { moveTarget = MoveTarget(urls: [entry.node.url]) }
                Button("Rename") {
                    renameText = entry.node.name
                    renameTarget = entry.node
                }
                Button("Copy Note URL") { Clipboard.copy(entry.node.url) }
                if entry.node.parentUrl != nil {
                    Button("Delete", role: .destructive) {
                        model.removeEntry(parentUrl: entry.node.parentUrl, url: entry.node.url)
                    }
                }
            }
        }
        .navigationTitle("Recents")
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
    @Environment(ContextTracker.self) private var contextTracker
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
            RichTextEditor(noteUrl: noteUrl, model: model, controller: editor, contextTracker: contextTracker)
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: 16)
                        Color.black
                    }
                }
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
                        editor.insertLogline()
                    } label: {
                        Label("Logline", systemImage: "clock")
                    }
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
                        #if os(macOS)
                        Menu("Export") {
                            Button("Export as HTML…") {
                                let title = node.name
                                Task {
                                    await NoteExporter.exportAndSave(
                                        noteUrl: noteUrl,
                                        title: title,
                                        model: model
                                    )
                                }
                            }
                        }
                        #endif
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
        let validKeys = Set(EditorController.styles.map(\.key))
        return Binding(
            get: { validKeys.contains(editor.currentStyleKey) ? editor.currentStyleKey : "paragraph" },
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
            content.onDrop(
                of: [UTType.plainText.identifier],
                delegate: FolderMoveDropDelegate(node: node, model: model)
            )
        } else {
            content
        }
    }
}

private struct FolderMoveDropDelegate: DropDelegate {
    let node: FolderNode
    let model: NotesModel

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.plainText.identifier])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.plainText.identifier]).first else {
            return false
        }
        let targetUrl = node.url
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
            guard let moved = Self.string(from: item) else { return }
            Task { @MainActor in
                if model.rootFolderUrls.contains(moved),
                   model.rootFolderUrls.contains(targetUrl) {
                    model.reorderRootFolder(moved, adjacentTo: targetUrl)
                } else {
                    model.moveItem(moved, into: targetUrl)
                }
            }
        }
        return true
    }

    private static func string(from item: NSSecureCoding?) -> String? {
        if let string = item as? String {
            return string
        }
        if let string = item as? NSString {
            return string as String
        }
        if let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
}

struct FolderColumnBrowser: View {
    let rootUrl: String
    let onSelectNote: (String) -> Void
    @Environment(NotesModel.self) private var model
    @State private var columnUrls: [String] = []
    @State private var selectedPerColumn: [String: String] = [:]

    init(rootUrl: String, onSelectNote: @escaping (String) -> Void) {
        self.rootUrl = rootUrl
        self.onSelectNote = onSelectNote
        _columnUrls = State(initialValue: [rootUrl])
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(columnUrls, id: \.self) { folderUrl in
                        browserColumn(folderUrl: folderUrl)
                            .frame(minWidth: 240, maxWidth: 300, maxHeight: .infinity)
                            .id(folderUrl)
                        Divider()
                    }
                    Color.clear.frame(width: 1)
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: columnUrls) {
                if let last = columnUrls.last {
                    withAnimation { proxy.scrollTo(last, anchor: .trailing) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(model.node(for: rootUrl)?.displayName ?? "Folder")
    }

    @ViewBuilder
    private func browserColumn(folderUrl: String) -> some View {
        let children = model.node(for: folderUrl)?.children ?? []
        List {
            ForEach(children) { node in
                if node.kind == "folder" {
                    Button {
                        if let idx = columnUrls.firstIndex(of: folderUrl) {
                            columnUrls = Array(columnUrls.prefix(idx + 1))
                            columnUrls.append(node.url)
                            selectedPerColumn[folderUrl] = node.url
                        }
                    } label: {
                        HStack {
                            Label(node.displayName, systemImage: "folder")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .listRowBackground(
                        selectedPerColumn[folderUrl] == node.url
                            ? Color.accentColor.opacity(0.12) : Color.clear
                    )
                    .buttonStyle(.plain)
                } else {
                    Button {
                        selectedPerColumn[folderUrl] = node.url
                        onSelectNote(node.url)
                    } label: {
                        NoteRowView(node: node)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        selectedPerColumn[folderUrl] == node.url
                            ? Color(red: 1.0, green: 0.412, blue: 0.647).opacity(0.2) : Color.clear
                    )
                }
            }
        }
        .listStyle(.inset)
        .frame(maxHeight: .infinity)
    }
}

struct PatchworkDetail: View {
    let docUrl: String
    @Environment(NotesModel.self) private var model

    var body: some View {
        Group {
            if PatchworkWeb.available {
                PatchworkDetailWebViewWrapper(docUrl: docUrl)
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
