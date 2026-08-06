import SwiftUI
import UniformTypeIdentifiers
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
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

struct PatchworkCreateRequest: Identifiable {
    let id = UUID()
    let preferredType: String?
    let toolId: String?
    let folderUrl: String?
}

struct ContentView: View {
    @Environment(NotesModel.self) private var model
    @Environment(ContextTracker.self) private var contextTracker
    @State private var router = AppRouter.shared
    @State private var patchworkCreateRequest: PatchworkCreateRequest?
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @State private var selectedItemUrls: Set<String> = []
    @State private var searchText = ""
    @State private var searchPresented = false
    @State private var searchHits: [SearchHit] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var renamingUrl: String?
    @State private var renameText = ""
    @FocusState private var renameFocus: String?
    @FocusState private var sidebarFocused: Bool
    @FocusState private var searchFocused: Bool
    @State private var expanded: Set<String> = []
    @State private var moveTarget: MoveTarget?
    @State private var pinnedExpanded = true
    @State private var rightSidebarVisible = false
    @State private var rightSidebarTab: RightSidebarTab = .history
    @State private var selectedHistoryEntry: DocHistoryEntry?

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
        #if canImport(CoreSpotlight)
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let url = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                router.pending = .note(url)
            }
        }
        #endif
        .onChange(of: router.pending) { processPending() }
        .onChange(of: model.folderUrl) { processPending() }
        .onChange(of: model.selectedNoteUrl) { _, url in
            guard let url else { return }
            selectedHistoryEntry = nil
            if !selectedItemUrls.containsSidebarTag(for: url) { selectedItemUrls = [url] }
        }
        .focusedSceneValue(\.noteSearchActions, NoteSearchActions(
            focusNoteSearch: focusCurrentNoteSearch,
            focusNotesSearch: focusNotesSearch
        ))
        .sheet(item: incomingContentBinding) { content in
            incomingContentSheet(content)
        }
        .sheet(item: $patchworkCreateRequest) { request in
            patchworkCreateSheet(request)
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
        .sheet(item: incomingContentBinding) { content in
            incomingContentSheet(content)
        }
        .sheet(item: $patchworkCreateRequest) { request in
            patchworkCreateSheet(request)
        }
        #endif
    }

    private var incomingContentBinding: Binding<IncomingContent?> {
        Binding(
            get: { model.pendingIncoming },
            set: { model.pendingIncoming = $0 }
        )
    }

    private func incomingContentSheet(_ content: IncomingContent) -> some View {
        IncomingContentSheet(content: content)
            .environment(model)
    }

    private func patchworkCreateSheet(_ request: PatchworkCreateRequest) -> some View {
        NewPatchworkDocSheet(preferredType: request.preferredType, preferredToolId: request.toolId, onPick: { url, tool in
            PatchworkWeb.setLastTool(tool, for: url)
            Task { await model.addDocToFolder(url: url, folderUrl: request.folderUrl) }
            #if os(macOS)
            selectedItemUrls = [url]
            #else
            path = [.patchwork(url)]
            #endif
        })
        .environment(model)
    }

    private func processPending() {
        guard let action = router.pending, model.folderUrl != nil else { return }
        router.pending = nil
        switch action {
        case .newNote:
            model.createNoteInInbox(snap: contextTracker.snapshot)
            if let url = model.selectedNoteUrl {
                open(url)
            }
        case .quickNote:
            if let url = model.quickNoteUrl {
                model.pendingFocusUrl = url
                open(url)
            } else {
                model.createNoteInInbox(snap: contextTracker.snapshot)
                if let url = model.selectedNoteUrl {
                    open(url)
                }
            }
        case .capture:
            #if os(macOS)
            openWindow(id: "quick-capture")
            NSApp.activate()
            #else
            if let url = model.quickNoteUrl {
                open(url)
            }
            #endif
        case .insertQuickNote(let text):
            Task { _ = await model.appendToQuickNote(text) }
        case .note(let url):
            model.pendingFocusUrl = url
            open(url)
        case .folder(let url):
            Task { await model.selectFolder(url) }
            openFolder(url)
        case .search(let query):
            #if os(macOS)
            searchText = query
            searchTask?.cancel()
            searchTask = Task { searchHits = await model.search(query) }
            #endif
        case .createPatchwork(let preferredType, let toolId, let folderUrl):
            patchworkCreateRequest = PatchworkCreateRequest(
                preferredType: preferredType,
                toolId: toolId,
                folderUrl: folderUrl
            )
        case .share(let id):
            model.pendingIncoming = IncomingContent.sharedHandoff(id: id)
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

    private func openFolder(_ url: String) {
        #if os(macOS)
        selectedItemUrls = [url]
        #else
        path = [.folder(url)]
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
                            pinnedNoteRow(node)
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
                    .onDrag({ NSItemProvider(object: hit.url as NSString) }, preview: {
                        DragPreviewView(name: hit.name.isEmpty ? "Untitled" : hit.name)
                    })
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
        .searchable(text: $searchText, isPresented: $searchPresented, placement: .sidebar, prompt: "Search notes")
        .searchFocused($searchFocused)
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Note") { model.createNote(snap: contextTracker.snapshot) }
                    Button("Folder") { model.createFolder() }
                    if PatchworkWeb.available {
                        Button("Patchwork Doc…") {
                            patchworkCreateRequest = PatchworkCreateRequest(
                                preferredType: nil,
                                toolId: nil,
                                folderUrl: model.folderUrl
                            )
                        }
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                } primaryAction: {
                    model.createNote(snap: contextTracker.snapshot)
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
                if model.loggedIn {
                    if let data = model.contactAvatarData, let image = PImage(data: data) {
                        Image(pImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 16, height: 16)
                            .clipShape(Circle())
                    }
                    if let name = model.contactName, !name.isEmpty {
                        Text(name)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }
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

    private func focusCurrentNoteSearch() {
        NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: nil)
    }

    private func focusNotesSearch() {
        searchPresented = true
        searchFocused = true
        sidebarFocused = true
    }

    private func pinnedNoteRow(_ node: FolderNode) -> some View {
        let tag = "pinned:\(node.url)"
        return NoteRowView(node: node, showFolder: true)
            .contentShape(Rectangle())
            .padding(.leading, 12)
            .onTapGesture {
                selectedItemUrls = [tag]
                Task { await model.selectItem(node.url) }
            }
            .tag(tag)
            .onDrag({ NSItemProvider(object: node.url as NSString) }, preview: {
                DragPreviewView(name: node.displayName)
            })
            .listRowInsets(sidebarRowInsets(depth: 1))
            .listRowBackground(selectionBackground(tag, greyWhen: node.url))
            .contextMenu {
                singleNoteContextMenu(for: node, showInFolder: true)
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
                        nodeRows(model.orderedChildren(node.children ?? [], in: node.url), depth: depth + 1)
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
                        if node.name.isEmpty {
                            LoadingFolderLabel()
                        } else {
                            Text(node.displayName)
                                .font(.title3.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
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
        .onDrag({ NSItemProvider(object: node.url as NSString) }, preview: {
            DragPreviewView(name: node.displayName, isFolder: true)
        })
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
            .onDrag({
                let urls = selectedItemUrls.contains(node.url)
                    ? Array(selectedItemUrls)
                    : [node.url]
                return NSItemProvider(object: urls.joined(separator: "\n") as NSString)
            }, preview: {
                let count = selectedItemUrls.contains(node.url) ? selectedItemUrls.count : 1
                DragPreviewView(name: node.displayName, count: count)
            })
            .modifier(NoteReorderDropTarget(node: node, model: model))
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
        HSplitView {
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
            .frame(minWidth: 360)

            if rightSidebarVisible, let url = model.selectedNoteUrl {
                RightSidebarView(
                    url: url,
                    node: model.node(for: url),
                    selectedTab: $rightSidebarTab,
                    selectedEntry: $selectedHistoryEntry
                )
                .environment(model)
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    Button("Note") { model.createNote(snap: contextTracker.snapshot) }
                    Button("Folder") { model.createFolder() }
                    if PatchworkWeb.available {
                        Button("Patchwork Doc…") {
                            patchworkCreateRequest = PatchworkCreateRequest(
                                preferredType: nil,
                                toolId: nil,
                                folderUrl: model.folderUrl
                            )
                        }
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                } primaryAction: {
                    model.createNote(snap: contextTracker.snapshot)
                }
                .disabled(model.folderUrl == nil)
            }
        }
    }

    @ViewBuilder
    private func detailContent(for url: String) -> some View {
        let node = model.node(for: url)
        let isPatchwork = model.patchworkDocUrls.contains(url)
        if node == nil, isPatchwork {
            // Known patchwork doc: open directly, no need to wait for the tree.
            PatchworkDetail(docUrl: url)
                .id(url)
        } else if node == nil, url.hasPrefix("automerge:") {
            // A doc url is enough to load the editor; the tree catches up.
            NoteDetail(
                noteUrl: url,
                historyVersion: selectedHistoryEntry,
                rightSidebarVisible: $rightSidebarVisible
            )
        } else if node == nil {
            ResolvingDocumentView(url: url)
        } else if node?.kind == "lush:script" {
            ScriptEditorView(url: url)
                .environment(model)
                .id(url)
        } else if !isPatchwork && (node?.isNote == true || (!url.hasPrefix("automerge:") && node?.isNote != false)) {
            // No .id here: the editor swaps documents through EditorCore.switchTo,
            // which keeps the text view, its layout manager and the asset cache.
            NoteDetail(
                noteUrl: url,
                historyVersion: selectedHistoryEntry,
                rightSidebarVisible: $rightSidebarVisible
            )
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
private extension Set where Element == String {
    func containsSidebarTag(for url: String) -> Bool {
        contains(url) || contains("pinned:\(url)")
    }
}

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

private struct LoadingFolderLabel: View {
    @State private var dim = false
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.secondary.opacity(dim ? 0.15 : 0.35))
            .frame(width: 72, height: 14)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
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
        .onDrag({ NSItemProvider(object: node.url as NSString) }, preview: {
            DragPreviewView(name: node.displayName)
        })
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
    @State private var searchTask: Task<Void, Never>?
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
            searchTask?.cancel()
            searchTask = Task { searchHits = await model.search(searchText) }
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
                } primaryAction: {
                    model.createNote(snap: contextTracker.snapshot)
                    if let url = model.selectedNoteUrl { push(.note(url)) }
                }
                .disabled(model.folderUrl == nil)
                .padding(.trailing)
            }
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showingNewPatchwork) {
            NewPatchworkDocSheet { url, _ in
                model.addDocToCurrentFolder(url: url)
                push(.patchwork(url))
            }
            .environment(model)
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView()
                    .environment(model)
                    .environment(contextTracker)
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
        List(model.recents) { entry in
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
        .task { await model.refreshRecents() }
        .onChange(of: model.folderTree) { Task { await model.refreshRecents() } }
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

enum RightSidebarTab: String, CaseIterable, Identifiable {
    case history = "History"
    case info = "Info"

    var id: String { rawValue }
}

#if os(macOS)
private struct ResolvingDocumentView: View {
    let url: String

    var body: some View {
        ContentUnavailableView {
            Label("Opening Document", systemImage: "doc.richtext")
        } description: {
            Text(url.shortHash)
                .font(.system(.caption, design: .monospaced))
        }
    }
}

struct RightSidebarView: View {
    let url: String
    let node: FolderNode?
    @Binding var selectedTab: RightSidebarTab
    @Binding var selectedEntry: DocHistoryEntry?

    @Environment(NotesModel.self) private var model
    @State private var history = DocumentHistorySummary(changeCount: 0, heads: [], modified: nil, entries: [])
    @State private var revertingHash: String?
    @State private var historyRefreshTask: Task<Void, Never>?

    private var selectedHistoryHash: String? {
        selectedEntry?.hash
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $selectedTab) {
                ForEach(RightSidebarTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(10)

            Divider()

            switch selectedTab {
            case .history:
                historyView
            case .info:
                infoView
            }
        }
        .background(.regularMaterial)
        .task(id: url) {
            selectedEntry = nil
            await refreshHistory()
        }
        .onChange(of: model.previews[url]) {
            scheduleHistoryRefresh()
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == .history {
                scheduleHistoryRefresh(delay: .zero)
            } else {
                historyRefreshTask?.cancel()
            }
        }
        .onDisappear {
            historyRefreshTask?.cancel()
        }
    }

    private var historyView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HistoryCurrentRow(
                    changeCount: history.changeCount,
                    modified: history.modified,
                    isSelected: selectedHistoryHash == nil
                ) {
                    selectedEntry = nil
                }

                HistoryTimelineView(
                    entries: history.entries,
                    selectedHash: selectedHistoryHash,
                    revertingHash: revertingHash,
                    onSelect: { entry in selectedEntry = entry },
                    onRevert: { entry in
                        revertingHash = entry.hash
                        Task {
                            await model.revertNote(url, to: entry.heads)
                            await refreshHistory()
                            selectedEntry = nil
                            revertingHash = nil
                        }
                    }
                )
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var infoView: some View {
        Form {
            Section("Document") {
                LabeledContent("Name") {
                    Text(node?.displayName.isEmpty == false ? node!.displayName : "Untitled")
                }
                LabeledContent("Kind") {
                    Text(node?.kind ?? "Document")
                }
                Button("Copy URL") {
                    Clipboard.copy(url)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func scheduleHistoryRefresh(delay: Duration = .milliseconds(650)) {
        guard selectedTab == .history else { return }
        historyRefreshTask?.cancel()
        let refreshUrl = url
        historyRefreshTask = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, refreshUrl == url else { return }
            await refreshHistory()
        }
    }

    private func refreshHistory() async {
        let summary = await model.documentHistorySummary(url: url)
        guard !Task.isCancelled else { return }
        history = summary
        if let selectedHistoryHash, !summary.entries.contains(where: { $0.hash == selectedHistoryHash }) {
            selectedEntry = nil
        }
    }
}

private struct HistoryCurrentRow: View {
    let changeCount: Int
    let modified: Date?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Main")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("live")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.16), in: Capsule())
                }
                HStack(spacing: 8) {
                    Text("\(changeCount) changes")
                    if let modified {
                        Text("Updated \(modified, style: .relative)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct HistoryTimelineView: View {
    let entries: [DocHistoryEntry]
    let selectedHash: String?
    let revertingHash: String?
    let onSelect: (DocHistoryEntry) -> Void
    let onRevert: (DocHistoryEntry) -> Void

    private var groups: [HistoryGroup] {
        HistoryGroup.groups(from: entries)
    }

    var body: some View {
        if entries.isEmpty {
            Text("No local history yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            HStack(alignment: .top, spacing: 7) {
                HistoryScrubber(count: entries.count)
                    .padding(.top, 9)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(groups) { group in
                        HistoryGroupRow(
                            group: group,
                            selectedHash: selectedHash,
                            revertingHash: revertingHash,
                            onSelect: onSelect,
                            onRevert: onRevert
                        )
                    }
                }
            }
        }
    }
}

private struct HistoryScrubber: View {
    let count: Int

    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(.secondary)
                .frame(width: 8, height: 8)
            Rectangle()
                .fill(.secondary.opacity(0.25))
                .frame(width: 2)
            Circle()
                .fill(.secondary.opacity(0.55))
                .frame(width: 6, height: 6)
        }
        .frame(width: 14)
        .frame(minHeight: CGFloat(max(count, 1)) * 20)
    }
}

private struct HistoryGroupRow: View {
    let group: HistoryGroup
    let selectedHash: String?
    let revertingHash: String?
    let onSelect: (DocHistoryEntry) -> Void
    let onRevert: (DocHistoryEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(group.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(group.entries.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            ForEach(group.entries, id: \.hash) { entry in
                Button {
                    onSelect(entry)
                } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(entry.hash == selectedHash ? Color.accentColor : Color.secondary.opacity(0.35))
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(entry.message?.isEmpty == false ? entry.message! : "Change \(entry.seq)")
                                    .lineLimit(1)
                                Spacer()
                                Text(entry.date, style: .time)
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.hash.shortHash)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        if entry.hash == selectedHash {
                            Button {
                                onRevert(entry)
                            } label: {
                                if revertingHash == entry.hash {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.uturn.backward.circle")
                                }
                            }
                            .buttonStyle(.borderless)
                            .help("Revert document to this point")
                        }
                    }
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
                    .background(entry.hash == selectedHash ? Color.accentColor.opacity(0.12) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 3)
    }
}

#if os(macOS)
private struct HistoricalNoteSnapshotView: View {
    let noteUrl: String
    let entry: DocHistoryEntry

    @Environment(NotesModel.self) private var model
    @State private var attributed = NSAttributedString(string: "")
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Read Only", systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.hash.shortHash)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)

            HistorySnapshotTextView(attributed: attributed)
        }
        .task(id: "\(noteUrl):\(entry.heads.joined(separator: ","))") {
            isLoading = true
            attributed = await model.renderedSnapshot(for: noteUrl, heads: entry.heads)
            isLoading = false
        }
    }
}

private struct HistorySnapshotTextView: NSViewRepresentable {
    let attributed: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layoutManager = ListMarkerLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.attributedString() != attributed {
            textView.textStorage?.setAttributedString(attributed)
        }
    }
}
#endif

private struct HistoryGroup: Identifiable {
    let id = UUID()
    let entries: [DocHistoryEntry]

    var title: String {
        guard let first = entries.first else { return "Changes" }
        return first.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    static func groups(from entries: [DocHistoryEntry]) -> [HistoryGroup] {
        let newestFirst = entries.reversed()
        var groups: [HistoryGroup] = []
        var current: [DocHistoryEntry] = []
        var previous: Date?
        for entry in newestFirst {
            let date = entry.date
            if let previous, abs(previous.timeIntervalSince(date)) > 60, !current.isEmpty {
                groups.append(HistoryGroup(entries: current))
                current = []
            }
            current.append(entry)
            previous = date
        }
        if !current.isEmpty {
            groups.append(HistoryGroup(entries: current))
        }
        return groups
    }
}

private extension DocHistoryEntry {
    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(time))
    }
}

private extension String {
    var shortHash: String {
        guard count > 10 else { return self }
        return String(prefix(10))
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
    var historyVersion: DocHistoryEntry? = nil
    #if os(macOS)
    var rightSidebarVisible: Binding<Bool>? = nil
    #endif
    @Environment(NotesModel.self) private var model
    @Environment(ContextTracker.self) private var contextTracker
    @Environment(\.dismiss) private var dismiss
    @State private var editor = EditorController()
    @State private var recorder = AudioRecorder()
    @State private var renameText = ""
    @State private var showingRename = false
    @State private var moveTarget: MoveTarget?
    @State private var editorDropTargeted = false
    #if os(iOS)
    @State private var photoItems: [PhotosPickerItem] = []
    #endif

    private var currentNode: FolderNode? { model.node(for: noteUrl) }

    var body: some View {
        VStack(spacing: 0) {
            if editor.recorderVisible, historyVersion == nil {
                RecorderBar(recorder: recorder) { data in
                    editor.recorderVisible = false
                    if let data {
                        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
                        editor.insertRecording(data: data, name: "Recording \(stamp).m4a")
                    }
                }
            }
            #if os(macOS)
            if let historyVersion {
                HistoricalNoteSnapshotView(
                    noteUrl: noteUrl,
                    entry: historyVersion
                )
                .environment(model)
            } else {
                RichTextEditor(noteUrl: noteUrl, model: model, controller: editor, contextTracker: contextTracker)
                    .mask {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                                .frame(height: 16)
                            Color.black
                        }
                    }
            }
            #else
            RichTextEditor(noteUrl: noteUrl, model: model, controller: editor, contextTracker: contextTracker)
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: 16)
                        Color.black
                    }
                }
            #endif
        }
        .focusedSceneValue(\.editorController, editor)
        .overlay {
            if editorDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(
            of: [UTType.plainText.identifier, UTType.fileURL.identifier],
            isTargeted: $editorDropTargeted
        ) { providers in
            guard historyVersion == nil else { return false }
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                        guard let url = droppedString(from: item), url.hasPrefix("automerge:") else { return }
                        Task { @MainActor in editor.insertPatchworkEmbed(url: url, tool: nil) }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        let fileUrl: URL?
                        if let u = item as? URL { fileUrl = u }
                        else if let data = item as? Data { fileUrl = URL(dataRepresentation: data, relativeTo: nil) }
                        else { return }
                        guard let fileUrl else { return }
                        let scoped = fileUrl.startAccessingSecurityScopedResource()
                        defer { if scoped { fileUrl.stopAccessingSecurityScopedResource() } }
                        guard let data = try? Data(contentsOf: fileUrl) else { return }
                        let name = fileUrl.lastPathComponent
                        Task { @MainActor in editor.insertData(data, name: name) }
                    }
                }
            }
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
            #if os(macOS)
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    rightSidebarVisible?.wrappedValue.toggle()
                } label: {
                    Label("Info", systemImage: "info.circle")
                }
            }
            #endif
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
            selection: $photoItems,
            maxSelectionCount: 12,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: photoItems) {
            guard !photoItems.isEmpty else { return }
            let items = photoItems
            photoItems = []
            Task {
                for (offset, item) in items.enumerated() {
                    guard let data = try? await item.loadTransferable(type: Data.self) else {
                        continue
                    }
                    let ext = item.supportedContentTypes.first?
                        .preferredFilenameExtension ?? "png"
                    let stamp = Int(Date().timeIntervalSince1970)
                    editor.insertData(data, name: "photo-\(stamp)-\(offset).\(ext)")
                }
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

private struct DragPreviewView: View {
    let name: String
    var count: Int = 1
    var isFolder: Bool = false

    var body: some View {
        Label(
            count > 1 ? "\(count) items" : name,
            systemImage: isFolder ? "folder.fill" : "doc.text.fill"
        )
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topTrailing) {
            if count > 1 {
                Text("\(count)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.accentColor, in: Circle())
                    .offset(x: 6, y: -6)
            }
        }
    }
}

private struct FolderDropTarget: ViewModifier {
    let node: FolderNode
    let model: NotesModel
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if node.kind == "folder" {
            content
                .background {
                    if isTargeted {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.accentColor.opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1.5)
                            )
                    }
                }
                .onDrop(
                    of: [UTType.plainText.identifier],
                    delegate: FolderMoveDropDelegate(node: node, model: model, isTargeted: $isTargeted)
                )
        } else {
            content
        }
    }
}

private struct FolderMoveDropDelegate: DropDelegate {
    let node: FolderNode
    let model: NotesModel
    @Binding var isTargeted: Bool

    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropExited(info: DropInfo) { isTargeted = false }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.plainText.identifier])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard let provider = info.itemProviders(for: [UTType.plainText.identifier]).first else {
            return false
        }
        let targetUrl = node.url
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
            guard let payload = droppedString(from: item) else { return }
            let moved = payload.components(separatedBy: "\n").filter { !$0.isEmpty }
            Task { @MainActor in
                for url in moved {
                    if model.rootFolderUrls.contains(url),
                       model.rootFolderUrls.contains(targetUrl) {
                        model.reorderRootFolder(url, adjacentTo: targetUrl)
                    } else {
                        model.moveItem(url, into: targetUrl)
                    }
                }
            }
        }
        return true
    }
}

private struct NoteReorderDropTarget: ViewModifier {
    let node: FolderNode
    let model: NotesModel
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if isTargeted {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                }
            }
            .onDrop(
                of: [UTType.plainText.identifier],
                delegate: NoteReorderDropDelegate(node: node, model: model, isTargeted: $isTargeted)
            )
    }
}

private struct NoteReorderDropDelegate: DropDelegate {
    let node: FolderNode
    let model: NotesModel
    @Binding var isTargeted: Bool

    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropExited(info: DropInfo) { isTargeted = false }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.plainText.identifier])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard let provider = info.itemProviders(for: [UTType.plainText.identifier]).first else {
            return false
        }
        let targetNode = node
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
            guard let payload = droppedString(from: item) else { return }
            let urls = payload.components(separatedBy: "\n").filter { !$0.isEmpty }
            Task { @MainActor in
                for url in urls {
                    if model.node(for: url)?.parentUrl == targetNode.parentUrl {
                        model.reorderChild(url, before: targetNode.url)
                    } else if let parent = targetNode.parentUrl {
                        model.moveItem(url, into: parent)
                    }
                }
            }
        }
        return true
    }
}

private func droppedString(from item: NSSecureCoding?) -> String? {
    if let s = item as? String { return s }
    if let s = item as? NSString { return s as String }
    if let d = item as? Data { return String(data: d, encoding: .utf8) }
    return nil
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
    @State private var tools: [ToolChoice] = []
    @State private var toolInput: String
    @State private var appliedToolId: String?
    @State private var toolsLoaded = false

    init(docUrl: String) {
        self.docUrl = docUrl
        let remembered = PatchworkWeb.lastTool(for: docUrl)
        _appliedToolId = State(initialValue: remembered)
        _toolInput = State(initialValue: remembered ?? "")
    }

    private func applyTool(_ tool: String?) {
        appliedToolId = tool
        PatchworkWeb.setLastTool(tool, for: docUrl)
        if let kind = model.node(for: docUrl)?.kind, !kind.isEmpty {
            PatchworkWeb.setLastTool(tool, forType: kind)
        }
    }

    private func rememberedTool() -> String? {
        if let tool = PatchworkWeb.lastTool(for: docUrl) { return tool }
        if let kind = model.node(for: docUrl)?.kind, !kind.isEmpty {
            return PatchworkWeb.lastTool(forType: kind)
        }
        return nil
    }

    private var shouldShowToolPicker: Bool {
        guard !docUrl.isEmpty else { return false }
        guard toolsLoaded else { return false }
        #if os(macOS)
        return model.selectedNoteUrl == docUrl
        #else
        return true
        #endif
    }

    var body: some View {
        Group {
            if PatchworkWeb.available {
                PatchworkBoxWebViewWrapper(
                    docUrl: docUrl,
                    toolId: appliedToolId,
                    onTools: { newTools, current in
                        tools = newTools
                        toolsLoaded = true
                        if toolInput.isEmpty {
                            toolInput = current ?? ""
                        }
                    }
                )
            } else {
                ContentUnavailableView(
                    "Patchwork Unavailable",
                    systemImage: "shippingbox",
                    description: Text("Add PatchworkWeb.bundle to render this document.")
                )
            }
        }
        .navigationTitle(model.node(for: docUrl)?.displayName ?? "")
        .onAppear {
            if appliedToolId == nil, let remembered = rememberedTool() {
                appliedToolId = remembered
                toolInput = remembered
            }
        }
        .onChange(of: docUrl) {
            tools = []
            toolsLoaded = false
            let remembered = rememberedTool()
            toolInput = remembered ?? ""
            appliedToolId = remembered
        }
        .toolbar {
            if shouldShowToolPicker {
                ToolbarItem {
                    HStack(spacing: 4) {
                        TextField("tool-id", text: $toolInput)
                            .frame(width: 200)
                            .onSubmit {
                                let id = toolInput.trimmingCharacters(in: .whitespaces)
                                applyTool(id.isEmpty ? nil : id)
                            }
                        Menu {
                            ForEach(tools) { tool in
                                Button(tool.name) {
                                    toolInput = tool.id
                                    applyTool(tool.id)
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(tools.isEmpty)
                    }
                }
            }
        }
    }
}

struct IncomingContentSheet: View {
    let content: IncomingContent
    @Environment(NotesModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var displayTitle: String {
        content.displayTitle
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
                                if case .text(let text) = content.flattenedPayloads.first,
                                   content.flattenedPayloads.count == 1 {
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
