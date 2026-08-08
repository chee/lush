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
    @Environment(\.scenePhase) private var scenePhase
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
        .onContinueUserActivity(LushHandoff.activityType) { activity in
            _ = LushHandoff.handle(activity)
        }
        .onChange(of: router.pending) { processPending() }
        .onChange(of: model.folderUrl) { processPending() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.drainSharedIntake() }
            }
        }
        .task { await model.drainSharedIntake() }
        // actions queued while no window existed
        .task { processPending() }
        .onChange(of: model.selectedNoteUrl) { _, url in
            guard let url else { return }
            selectedHistoryEntry = nil
            if !selectedItemUrls.containsSidebarTag(for: url) { selectedItemUrls = [url] }
        }
        .onAppear {
            if let url = model.selectedNoteUrl,
               !selectedItemUrls.containsSidebarTag(for: url) {
                selectedItemUrls = [url]
            }
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
                        NoteDetail(noteUrl: model.resolvedNoteUrl(url))
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
        #if canImport(CoreSpotlight)
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let url = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                router.pending = .note(url)
            }
        }
        #endif
        .onContinueUserActivity(LushHandoff.activityType) { activity in
            _ = LushHandoff.handle(activity)
        }
        .onChange(of: router.pending) { processPending() }
        .onChange(of: model.folderUrl) { processPending() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.drainSharedIntake() }
            }
        }
        .task { await model.drainSharedIntake() }
        // actions queued while no window existed
        .task { processPending() }
        .onChange(of: model.selectedNoteUrl) { _, url in
            guard let url, path.isEmpty else { return }
            path = [.note(url)]
        }
        .onAppear {
            if let url = model.selectedNoteUrl, path.isEmpty {
                path = [.note(url)]
            }
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
            Task {
                if let url = await model.createNoteInInbox(snap: contextTracker.snapshot) {
                    open(url)
                }
            }
        case .quickNote:
            if let url = model.quickNoteUrl {
                model.pendingFocusUrl = url
                open(url)
            } else {
                // create once and remember it; every later invocation reuses it
                Task {
                    guard let url = await model.ensureQuickNote() else { return }
                    model.pendingFocusUrl = url
                    open(url)
                    model.refreshNotes()
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
            searchPresented = true
            searchFocused = true
            sidebarFocused = true
            if query.isEmpty {
                searchHits = []
            } else {
                searchTask?.cancel()
                searchTask = Task {
                    let hits = await model.search(query)
                    guard !Task.isCancelled else { return }
                    searchHits = hits
                }
            }
            #else
            path = []
            model.searchQuery = query
            #endif
        case .createPatchwork(let preferredType, let toolId, let folderUrl):
            patchworkCreateRequest = PatchworkCreateRequest(
                preferredType: preferredType,
                toolId: toolId,
                folderUrl: folderUrl
            )
        case .share:
            Task { await model.drainSharedIntake() }
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
        .onChange(of: searchText) {
            model.searchQuery = searchText
            searchTask?.cancel()
            searchTask = Task {
                let hits = await model.search(searchText)
                guard !Task.isCancelled else { return }
                searchHits = hits
            }
        }
        .onChange(of: model.notes) {
            if !searchText.isEmpty {
                searchTask?.cancel()
                searchTask = Task {
                    let hits = await model.search(searchText)
                    guard !Task.isCancelled else { return }
                    searchHits = hits
                }
            }
        }
        .onChange(of: model.folderTree) {
            if !searchText.isEmpty {
                searchTask?.cancel()
                searchTask = Task {
                    let hits = await model.search(searchText)
                    guard !Task.isCancelled else { return }
                    searchHits = hits
                }
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
            Button("Note") {
                Task { if let url = await model.createNote(inFolder: node.url) { open(url) } }
            }
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
                    if isPatchworkDoc(node) {
                        Button("Copy Patchwork URL") { model.copyPatchworkUrl(for: node.url) }
                        Button("Open in Patchwork") { model.openInPatchwork(node.url) }
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
                }
            }
    }

    @ViewBuilder
    private var detail: some View {
        HSplitView {
            Group {
                if let url = model.selectedNoteUrl {
                    if model.core == nil {
                        BootNoteSnapshotView(url: url)
                    } else {
                        detailContent(for: url)
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
                    Button("Note") {
                        Task { if let url = await model.createNote(snap: contextTracker.snapshot) { open(url) } }
                    }
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
                    Task { if let url = await model.createNote(snap: contextTracker.snapshot) { open(url) } }
                }
                .disabled(model.folderUrl == nil)
            }
        }
    }

    @ViewBuilder
    private func detailContent(for url: String) -> some View {
        let node = model.node(for: url)
        let isPatchwork = model.patchworkDocUrls.contains(url)
        // Checked-out drafts redirect the editor to the draft's clone; the
        // sidebar, node and title all keep speaking about the origin url.
        let resolved = model.resolvedNoteUrl(url)
        if node == nil, isPatchwork {
            // Known patchwork doc: open directly, no need to wait for the tree.
            PatchworkDetail(docUrl: url, historyVersion: selectedHistoryEntry, rightSidebarVisible: $rightSidebarVisible)
                .id(url)
        } else if node == nil, url.hasPrefix("automerge:") {
            // A doc url is enough to load the editor; the tree catches up.
            NoteDetail(
                noteUrl: resolved,
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
                noteUrl: resolved,
                historyVersion: selectedHistoryEntry,
                rightSidebarVisible: $rightSidebarVisible
            )
        } else {
            PatchworkDetail(docUrl: url, historyVersion: selectedHistoryEntry, rightSidebarVisible: $rightSidebarVisible)
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

    private func isPatchworkDoc(_ node: FolderNode) -> Bool {
        model.patchworkDocUrls.contains(node.url) || node.isPatchworkDoc
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
        if isPatchworkDoc(node) {
            Button("Copy Patchwork URL") { model.copyPatchworkUrl(for: node.url) }
            Button("Open in Patchwork") { model.openInPatchwork(node.url) }
        }
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
        .userActivity(
            LushHandoff.activityType,
            element: folderUrl.flatMap { LushHandoff.item(for: model.node(for: $0)) }
        ) { item, activity in
            LushHandoff.configure(activity, item: item)
        }
        .onChange(of: searchText) {
            model.searchQuery = searchText
            searchTask?.cancel()
            searchTask = Task {
                let hits = await model.search(searchText)
                guard !Task.isCancelled else { return }
                searchHits = hits
            }
        }
        .onChange(of: model.searchQuery) {
            if searchText != model.searchQuery { searchText = model.searchQuery }
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
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 15))
                    TextField("Search notes", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))

                Menu {
                    Button {
                        Task {
                            if let url = await model.createNote(snap: contextTracker.snapshot) {
                                push(.note(url))
                            }
                        }
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
                } primaryAction: {
                    Task {
                        if let url = await model.createNote(snap: contextTracker.snapshot) {
                            push(.note(url))
                        }
                    }
                }
                .disabled(model.folderUrl == nil)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
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
                Button("Note") {
                    Task { if let url = await model.createNote(inFolder: node.url) { push(.note(url)) } }
                }
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
        if model.patchworkDocUrls.contains(node.url) || node.isPatchworkDoc {
            Button("Copy Patchwork URL") { model.copyPatchworkUrl(for: node.url) }
            Button("Open in Patchwork") { model.openInPatchwork(node.url) }
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
                if model.patchworkDocUrls.contains(entry.node.url) || entry.node.isPatchworkDoc {
                    Button("Copy Patchwork URL") { model.copyPatchworkUrl(for: entry.node.url) }
                    Button("Open in Patchwork") { model.openInPatchwork(entry.node.url) }
                }
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
    case outline = "Outline"
    case canvas = "Canvas"
    case history = "History"
    case info = "Info"
    case chat = "Chat"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .outline: "list.bullet.indent"
        case .canvas: "square.grid.3x3.topleft.filled"
        case .history: "clock.arrow.circlepath"
        case .info: "info.circle"
        case .chat: "bubble.left"
        }
    }
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
#endif

private extension Color {
    static var controlCard: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
}

struct RightSidebarView: View {
    let url: String
    let node: FolderNode?
    @Binding var selectedTab: RightSidebarTab
    @Binding var selectedEntry: DocHistoryEntry?

    @Environment(NotesModel.self) private var model
    @State private var history = DocumentHistorySummary(changeCount: 0, heads: [], modified: nil, entries: [], pendingEntries: [])
    @State private var revertingHash: String?
    @State private var historyRefreshTask: Task<Void, Never>?
    @State private var mainExpanded = true

    private var selectedHistoryHash: String? {
        selectedEntry?.hash
    }

    private var availableTabs: [RightSidebarTab] {
        RightSidebarTab.allCases.filter { tab in
            switch tab {
            case .outline, .canvas: model.activeEditor != nil
            case .history, .info, .chat: node != nil
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(availableTabs) { tab in
                    Image(systemName: tab.icon)
                        .help(tab.rawValue)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            .onChange(of: availableTabs) {
                if !availableTabs.contains(selectedTab) {
                    selectedTab = availableTabs.first ?? .info
                }
            }

            Divider()

            switch selectedTab {
            case .outline:
                OutlineListView(controller: model.activeEditor)
            case .canvas:
                CanvasStashView(controller: model.activeEditor)
            case .history:
                historyView
            case .info:
                infoView
            case .chat:
                NoteChatView(url: model.resolvedNoteUrl(url), node: node)
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
        .onChange(of: model.syncLog.count) {
            scheduleHistoryRefresh()
        }
        .onChange(of: model.docVersions[url]) {
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
        let checkedOut = model.checkedOutDrafts[url]
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if !history.pendingEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("Future", systemImage: "clock.badge")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text("\(history.pendingChangeCount) \(history.pendingChangeCount == 1 ? "change" : "changes")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 9)

                        ChangesListView(
                            entries: history.pendingEntries,
                            selectedHash: selectedHistoryHash,
                            onScrub: { entry in selectedEntry = entry }
                        )
                    }
                    .padding(.vertical, 9)
                    .background(Color.controlCard)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                    }
                }

                HistoryCurrentRow(
                    changeCount: history.changeCount,
                    modified: history.modified,
                    isSelected: selectedHistoryHash == nil && checkedOut == nil,
                    action: {
                        selectedEntry = nil
                        if checkedOut != nil {
                            Task { await model.checkOutDraft(nil, for: url) }
                        }
                    },
                    isExpanded: mainExpanded,
                    onToggle: { withAnimation(.easeOut(duration: 0.15)) { mainExpanded.toggle() } }
                )

                if mainExpanded, checkedOut == nil {
                    ChangesListView(
                        entries: history.entries,
                        selectedHash: selectedHistoryHash,
                        revertingHash: revertingHash,
                        onScrub: { entry in selectedEntry = entry },
                        onRevert: { entry in
                            revertingHash = entry.hash
                            Task {
                                await model.revertNote(url, to: entry.heads)
                                await refreshHistory()
                                selectedEntry = nil
                                revertingHash = nil
                            }
                        },
                        onCreateDraft: { entry in
                            Task {
                                if let draft = await model.createDraftAt(for: url, heads: entry.heads) {
                                    selectedEntry = nil
                                    await model.checkOutDraft(draft, for: url)
                                }
                            }
                        }
                    )
                }

                ForEach(model.draftLists[url]?.drafts ?? []) { draft in
                    DraftCardView(
                        host: url,
                        draft: draft,
                        isCheckedOut: checkedOut == draft.url,
                        selectedEntry: $selectedEntry
                    )
                }

                if let checkedOut {
                    Button {
                        Task {
                            selectedEntry = nil
                            await model.mergeDraft(checkedOut, for: url)
                            await refreshHistory()
                        }
                    } label: {
                        Label("Merge into Main", systemImage: "arrow.triangle.merge")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        Task {
                            if let draft = await model.createDraft(for: url) {
                                selectedEntry = nil
                                await model.checkOutDraft(draft, for: url)
                            }
                        }
                    } label: {
                        Label("New Draft", systemImage: "arrow.branch")
                            .frame(maxWidth: .infinity)
                    }
                }
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
        await model.refreshDrafts(for: url)
        let summary = await model.documentHistorySummary(url: url)
        guard !Task.isCancelled else { return }
        history = summary
        if model.checkedOutDrafts[url] == nil, let selectedHistoryHash,
           !summary.entries.contains(where: { $0.hash == selectedHistoryHash }),
           !summary.pendingEntries.contains(where: { $0.hash == selectedHistoryHash }) {
            selectedEntry = nil
        }
    }
}

private struct DraftCardView: View {
    let host: String
    let draft: DraftInfo
    let isCheckedOut: Bool
    @Binding var selectedEntry: DocHistoryEntry?

    @Environment(NotesModel.self) private var model
    @State private var entries: [DocHistoryEntry] = []
    @State private var memberEntries: [String: [DocHistoryEntry]] = [:]
    @State private var scrubHash: String?
    @State private var checkpointTask: Task<Void, Never>?
    @State private var renaming = false
    @State private var renameText = ""
    @State private var expanded = false
    @State private var revertingHash: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Button {
                    selectedEntry = nil
                    if !isCheckedOut {
                        Task { await model.checkOutDraft(draft.url, for: host) }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(draft.displayName)
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            if isCheckedOut {
                                Text("checked out")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.tint.opacity(0.16), in: Capsule())
                            }
                        }
                        Text(draft.cloneUrl == nil ? "No changes yet" : "\(entries.count) changes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .padding(10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Collapse changes" : "Show changes")
            }
            .background(isCheckedOut ? Color.accentColor.opacity(0.14) : .controlCard)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isCheckedOut ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: 1)
            }
            .contextMenu {
                Button("Rename…") {
                    renameText = draft.name ?? ""
                    renaming = true
                }
            }

            if expanded {
                ScrollView {
                    ChangesListView(
                        entries: entries,
                        selectedHash: isCheckedOut ? scrubHash : nil,
                        interactive: isCheckedOut,
                        revertingHash: revertingHash,
                        onScrub: { entry in
                            scrubHash = entry?.hash
                            selectedEntry = entry.flatMap(hostPin)
                            scheduleCheckpoint(entry)
                        },
                        onActivate: {
                            selectedEntry = nil
                            Task { await model.checkOutDraft(draft.url, for: host) }
                        },
                        onRevert: { entry in
                            guard let clone = draft.cloneUrl, let pin = hostPin(entry) else { return }
                            revertingHash = entry.hash
                            Task {
                                await model.revertNote(clone, to: pin.heads)
                                await refreshEntries()
                                selectedEntry = nil
                                scrubHash = nil
                                revertingHash = nil
                            }
                        }
                    )
                }
                .frame(maxHeight: 220)
                .padding(.leading, 4)
            }
        }
        .onChange(of: selectedEntry == nil) { _, cleared in
            if cleared, scrubHash != nil {
                scrubHash = nil
                if isCheckedOut { scheduleCheckpoint(nil) }
            }
        }
        .alert("Rename Draft", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                Task { await model.renameDraft(draft.url, name: renameText) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: refreshKey) { await refreshEntries() }
        .onChange(of: draft.members.map { model.docVersions[$0.cloneUrl] ?? 0 }) {
            Task { await refreshEntries() }
        }
        .onChange(of: isCheckedOut) { _, checkedOut in
            if checkedOut { withAnimation(.easeOut(duration: 0.15)) { expanded = true } }
        }
        .onAppear {
            if isCheckedOut { expanded = true }
        }
    }

    private var refreshKey: String {
        let clones = draft.members.map(\.cloneUrl).joined(separator: ",")
        return "\(draft.url)|\(clones)|\(isCheckedOut)"
    }

    /// All member docs' changes since their fork points, interleaved newest
    /// first (time, then per-doc seq as the same-second tiebreak) — mimi's
    /// collectInterleavedChanges ordering.
    private func refreshEntries() async {
        func newestFirst(_ a: DocHistoryEntry, _ b: DocHistoryEntry) -> Bool {
            a.time == b.time ? a.seq > b.seq : a.time > b.time
        }
        var perMember: [String: [DocHistoryEntry]] = [:]
        for member in draft.members {
            perMember[member.cloneUrl] = await model
                .draftEntries(cloneUrl: member.cloneUrl, since: member.clonedAt)
                .sorted(by: newestFirst)
        }
        guard !Task.isCancelled else { return }
        entries = perMember.values.flatMap { $0 }.sorted { a, b in
            a.time == b.time ? a.seq < b.seq : a.time < b.time
        }
        memberEntries = perMember
    }

    /// One member's version at a scrub position (patchwork's
    /// computeCheckpoint): the change itself when that member owns it,
    /// otherwise its latest change at or before it. nil when it has nothing
    /// that early — it didn't exist yet, so it renders live.
    private func pin(_ entry: DocHistoryEntry, in list: [DocHistoryEntry]) -> DocHistoryEntry? {
        if list.contains(where: { $0.hash == entry.hash }) { return entry }
        return list.first { $0.time <= entry.time }
    }

    private func checkpointPins(for entry: DocHistoryEntry) -> [CheckpointPin] {
        draft.members.compactMap { member in
            pin(entry, in: memberEntries[member.cloneUrl] ?? []).map {
                CheckpointPin(originalUrl: member.originalUrl, heads: [$0.hash])
            }
        }
    }

    /// Debounced so a scrub drag writes the checkout doc at a sane rate;
    /// the model chains writes per host so they land in order.
    private func scheduleCheckpoint(_ entry: DocHistoryEntry?) {
        let pins = entry.map(checkpointPins)
        checkpointTask?.cancel()
        checkpointTask = Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            await model.setDraftCheckpoint(host: host, pins: pins)
        }
    }

    /// The version of the *displayed* doc (the host's clone) a scrub position
    /// means, falling back to the fork point when the scrub sits before the
    /// host clone's first change.
    private func hostPin(_ entry: DocHistoryEntry) -> DocHistoryEntry? {
        if let clone = draft.cloneUrl,
           let pinned = pin(entry, in: memberEntries[clone] ?? []) {
            return pinned
        }
        guard let clonedAt = draft.clonedAt, !clonedAt.isEmpty else { return nil }
        return DocHistoryEntry(
            hash: "fork:" + clonedAt.joined(separator: ","),
            heads: clonedAt,
            time: entry.time,
            actor: "",
            seq: 0,
            message: nil,
            deps: clonedAt,
            additions: 0,
            deletions: 0
        )
    }
}

private struct HistoryCurrentRow: View {
    let changeCount: Int
    let modified: Date?
    let isSelected: Bool
    let action: () -> Void
    var isExpanded: Bool? = nil
    var onToggle: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let isExpanded, let onToggle {
                Button(action: onToggle) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .padding(10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse changes" : "Show changes")
            }
        }
        .background(isSelected ? Color.accentColor.opacity(0.14) : .controlCard)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: 1)
        }
    }
}

/// Patchwork's draft-changes timeline: activity bursts (≤60 s apart) as
/// single rows — author dots, time, +/− counts — with a scrubber token in
/// the left gutter. The token's line marks the version being looked at;
/// dragging it snaps per individual change, interpolated across each
/// group's row, so mid-group versions are reachable. Above the top = live.
private struct ChangesListView: View {
    let entries: [DocHistoryEntry]
    let selectedHash: String?
    var interactive = true
    var revertingHash: String? = nil
    let onScrub: (DocHistoryEntry?) -> Void
    var onActivate: (() -> Void)? = nil
    var onRevert: ((DocHistoryEntry) -> Void)? = nil
    var onCreateDraft: ((DocHistoryEntry) -> Void)? = nil

    private static let rowHeight: CGFloat = 30
    private static let rowSpacing: CGFloat = 4
    private static let gutterWidth: CGFloat = 16

    private var groups: [ChangeGroup] {
        ChangeGroup.groups(from: entries).filter { $0.additions > 0 || $0.deletions > 0 }
    }

    var body: some View {
        let groups = groups
        let visible = groups.flatMap(\.entries)
        let headIndex = interactive
            ? selectedHash.flatMap { hash in visible.firstIndex { $0.hash == hash } }
            : nil
        if groups.isEmpty {
            Text("No changes yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            let tokenY = Self.yForIndex(headIndex ?? 0, groups: groups)
            ZStack(alignment: .topLeading) {
                if interactive, headIndex != nil {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.7))
                        .frame(height: 1.5)
                        .offset(y: tokenY)
                }
                HStack(alignment: .top, spacing: 5) {
                    Color.clear
                        .frame(width: Self.gutterWidth)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("changesTrack"))
                                .onChanged { value in
                                    guard interactive else { return }
                                    let index = Self.indexForY(value.location.y, groups: groups, count: visible.count)
                                    if let index { onScrub(visible[index]) } else { onScrub(nil) }
                                }
                        )
                    VStack(spacing: Self.rowSpacing) {
                        ForEach(groups) { group in
                            row(group)
                        }
                    }
                }
                if interactive {
                    scrubToken(headIndex: headIndex, visible: visible, groups: groups, tokenY: tokenY)
                }
                if interactive, let headIndex, let head = visible[safe: headIndex] {
                    sticker(for: head)
                        .offset(y: tokenY + 3)
                }
            }
            .coordinateSpace(name: "changesTrack")
        }
    }

    private func row(_ group: ChangeGroup) -> some View {
        let isSelected = interactive && group.entries.contains { $0.hash == selectedHash }
        return Button {
            if interactive {
                onScrub(group.newest)
            } else {
                onActivate?()
            }
        } label: {
            HStack(spacing: 6) {
                ActorDots(actors: group.actors)
                Text(group.endDate, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if group.additions > 0 {
                    Text("+\(group.additions)")
                        .foregroundStyle(.green)
                }
                if group.deletions > 0 {
                    Text("−\(group.deletions)")
                        .foregroundStyle(.red)
                }
            }
            .font(.caption)
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onCreateDraft {
                let entry = group.entries.first { $0.hash == selectedHash } ?? group.newest
                Button {
                    onCreateDraft(entry)
                } label: {
                    Label("New Draft from Here", systemImage: "arrow.branch")
                }
            }
        }
    }

    private func scrubToken(
        headIndex: Int?,
        visible: [DocHistoryEntry],
        groups: [ChangeGroup],
        tokenY: CGFloat
    ) -> some View {
        Circle()
            .fill(headIndex == nil ? Color.secondary.opacity(0.6) : Color.accentColor)
            .frame(width: 9, height: 9)
            .padding(6)
            .contentShape(Rectangle())
            .offset(x: (Self.gutterWidth - 21) / 2, y: tokenY - 10.5)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("changesTrack"))
                    .onChanged { value in
                        let index = Self.indexForY(value.location.y, groups: groups, count: visible.count)
                        guard index != headIndex else { return }
                        if let index {
                            onScrub(visible[index])
                        } else {
                            onScrub(nil)
                        }
                    }
            )
            .help("Drag to scrub through history")
    }

    /// The exact version the token line sits on, floated at the line's right
    /// end, with the way back into the doc (revert).
    private func sticker(for head: DocHistoryEntry) -> some View {
        HStack(spacing: 5) {
            Text(head.date, format: .dateTime.hour().minute().second())
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            if let onRevert {
                Button {
                    onRevert(head)
                } label: {
                    if revertingHash == head.hash {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.borderless)
                .help("Revert document to this point")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.accentColor.opacity(0.4), lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .allowsHitTesting(onRevert != nil)
    }

    private static func yForIndex(_ index: Int, groups: [ChangeGroup]) -> CGFloat {
        var start = 0
        var top: CGFloat = 0
        for group in groups {
            if index < start + group.entries.count {
                let offset = CGFloat(index - start) / CGFloat(group.entries.count)
                return top + offset * rowHeight
            }
            start += group.entries.count
            top += rowHeight + rowSpacing
        }
        return max(0, top - rowSpacing)
    }

    /// nil = dragged above the top: back to live.
    private static func indexForY(_ y: CGFloat, groups: [ChangeGroup], count: Int) -> Int? {
        if y < -10 { return nil }
        var start = 0
        var top: CGFloat = 0
        for group in groups {
            if y < top + rowHeight {
                let slot = ((y - top) / rowHeight * CGFloat(group.entries.count)).rounded(.down)
                return min(max(start, start + Int(slot)), start + group.entries.count - 1)
            }
            top += rowHeight + rowSpacing
            start += group.entries.count
        }
        return max(0, count - 1)
    }
}

/// Deduped author dots, newest contributor first, patchwork-style overlap.
private struct ActorDots: View {
    let actors: [String]

    var body: some View {
        HStack(spacing: -4) {
            ForEach(Array(actors.prefix(3).enumerated()), id: \.offset) { index, actor in
                Circle()
                    .fill(PresenceManager.swatch(PresenceManager.stableColor(for: actor)))
                    .frame(width: 13, height: 13)
                    .overlay(Circle().stroke(Color.controlCard, lineWidth: 1.5))
                    .zIndex(Double(3 - index))
            }
            if actors.count > 3 {
                Text("+\(actors.count - 3)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#if os(macOS)
private struct BootNoteSnapshotView: View {
    let url: String
    @Environment(NotesModel.self) private var model
    @State private var attributed = NSAttributedString(string: "")

    var body: some View {
        HistorySnapshotTextView(attributed: attributed)
            .opacity(0.5)
            .task(id: url) {
                attributed = await model.renderedCurrentSnapshot(for: url)
            }
    }
}

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
            attributed = await model.renderedSnapshot(for: noteUrl, entry: entry)
            isLoading = false
        }
    }
}

#if os(macOS)
private struct HistorySnapshotTextView: NSViewRepresentable {
    let attributed: NSAttributedString

    func makeCoordinator() -> ListMarkerLayoutDelegate {
        ListMarkerLayoutDelegate()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.textLayoutManager?.delegate = context.coordinator
        textView.textLayoutManager?.renderingAttributesValidator = CodeHighlight.applyRenderingAttributes
        textView.textContainer?.widthTracksTextView = true
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
#endif

/// One burst of activity: consecutive changes no more than 60 s apart,
/// regardless of author. Entries are newest-first, matching patchwork's
/// DraftsSidebar grouping.
private struct ChangeGroup: Identifiable {
    let entries: [DocHistoryEntry]
    let actors: [String]
    let additions: Int
    let deletions: Int

    var newest: DocHistoryEntry { entries[0] }
    var id: String { newest.hash }
    var endDate: Date { newest.date }

    static func groups(from entries: [DocHistoryEntry]) -> [ChangeGroup] {
        var groups: [ChangeGroup] = []
        var window: [DocHistoryEntry] = []
        var previous: Date?

        func flush() {
            guard !window.isEmpty else { return }
            var actors: [String] = []
            var additions = 0
            var deletions = 0
            for entry in window {
                if !actors.contains(entry.actor) { actors.append(entry.actor) }
                additions += Int(entry.additions)
                deletions += Int(entry.deletions)
            }
            groups.append(ChangeGroup(
                entries: window,
                actors: actors,
                additions: additions,
                deletions: deletions
            ))
            window = []
        }

        for entry in entries.reversed() {
            if let previous, previous.timeIntervalSince(entry.date) > 60 { flush() }
            window.append(entry)
            previous = entry.date
        }
        flush()
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
    @State private var showingInspector = false
    @State private var inspectorTab: RightSidebarTab = .info
    @State private var inspectorHistoryEntry: DocHistoryEntry?
    #endif

    private var currentNode: FolderNode? { model.node(for: noteUrl) }

    @ViewBuilder
    private var findOverlay: some View {
        if editor.findVisible, historyVersion == nil {
            FindBar(controller: editor)
                .padding(.top, 10)
                .padding(.trailing, 16)
        }
    }

    @ViewBuilder
    private var minimapOverlay: some View {
        #if os(macOS)
        if historyVersion == nil, EditorSettings.minimapVisible, !editor.minimapRows.isEmpty {
            MinimapView(controller: editor)
                .padding(.top, 64)
                .padding(.bottom, 20)
                .padding(.trailing, 2)
        }
        #endif
    }


    @ViewBuilder
    private var draftBadge: some View {
        if historyVersion == nil, let name = model.checkedOutDraftName(forClone: noteUrl) {
            EditorStatusBadges(draftName: name, readOnly: false)
        }
    }

    private func joinPresence() {
        if historyVersion == nil {
            model.presence.join(noteUrl)
        }
    }

    private func leavePresence() {
        if model.presence.docUrl == noteUrl {
            model.presence.leave()
        }
    }

    #if os(iOS)
    private func handlePickedPhotos() {
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

    private func handlePickedFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        if let data = try? Data(contentsOf: url) {
            editor.insertData(data, name: url.lastPathComponent)
        }
    }

    private func handleCapturedImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        editor.insertData(data, name: "photo-\(stamp).jpg")
    }
    #endif

    @ToolbarContentBuilder
    private var noteToolbar: some ToolbarContent {
        #if os(macOS)
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
        #endif
        #if os(macOS)
        ToolbarItem {
            Picker("Style", selection: styleBinding) {
                ForEach(EditorController.styles, id: \.key) { style in
                    Text(style.label).tag(style.key)
                }
            }
            .pickerStyle(.menu)
        }
        if editor.isCodeBlockActive {
            ToolbarItem {
                Picker("Language", selection: languageBinding) {
                    ForEach(CodeLanguage.all) { language in
                        Text(language.name).tag(language.id)
                    }
                }
                .pickerStyle(.menu)
            }
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
                    if model.patchworkDocUrls.contains(noteUrl) || node.isPatchworkDoc {
                        Button("Copy Patchwork URL") { model.copyPatchworkUrl(for: noteUrl) }
                        Button("Open in Patchwork") { model.openInPatchwork(noteUrl) }
                    }
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
                Label("More", systemImage: "ellipsis")
            }
            .disabled(currentNode == nil)
        }
        ToolbarItem(placement: .primaryAction) {
            FocusModeControl(model: model)
        }
        #if os(macOS)
        ToolbarSpacer(.flexible)
        ToolbarItem(placement: .primaryAction) {
            PresenceFacesView(presence: model.presence)
        }
        ToolbarSpacer(.fixed)
        ToolbarItem(placement: .primaryAction) {
            Button {
                rightSidebarVisible?.wrappedValue.toggle()
            } label: {
                Label("Info", systemImage: "info.circle")
            }
            .disabled(rightSidebarVisible == nil)
        }
        #else
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingInspector = true
            } label: {
                Label("Info", systemImage: "info.circle")
            }
        }
        #endif
    }

    private func handleEditorDrop(_ providers: [NSItemProvider]) -> Bool {
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

    private var editorStack: some View {
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
                    .toolbarScrollFade()
            }
            #else
            RichTextEditor(noteUrl: noteUrl, model: model, controller: editor, contextTracker: contextTracker)
                .toolbarScrollFade()
            #endif
        }
        .focusedSceneValue(\.editorController, editor)
        .overlay(alignment: .topTrailing) { findOverlay }
        .overlay(alignment: .trailing) { minimapOverlay }
        .overlay(alignment: .topLeading) { draftBadge }
        .onChange(of: model.searchQuery) {
            editor.core?.updateGlobalMatches()
        }
        .onAppear { model.activeEditor = editor }
        .task(id: noteUrl) { model.activeEditor = editor }
        .userActivity(
            LushHandoff.activityType,
            element: LushHandoff.item(for: currentNode) ?? LushHandoffItem(
                url: noteUrl,
                title: "Lush Note",
                kind: .note
            )
        ) { item, activity in
            LushHandoff.configure(activity, item: item)
        }
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
        ) { handleEditorDrop($0) }
    }

    var body: some View {
        #if os(iOS)
        noteEditorBase
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
            handlePickedPhotos()
        }
        .fileImporter(
            isPresented: Binding(
                get: { editor.filePickerVisible },
                set: { editor.filePickerVisible = $0 }
            ),
            allowedContentTypes: [.item],
            onCompletion: handlePickedFile
        )
        .sheet(isPresented: Binding(
            get: { editor.cameraPickerVisible },
            set: { editor.cameraPickerVisible = $0 }
        )) {
            CameraPicker(onCapture: handleCapturedImage)
        }
        .sheet(isPresented: $showingInspector) {
            RightSidebarView(
                url: noteUrl,
                node: currentNode,
                selectedTab: $inspectorTab,
                selectedEntry: $inspectorHistoryEntry
            )
            .environment(model)
        }
        #else
        noteEditorBase
        #endif
    }

    private var noteEditorBase: some View {
        editorStack
        .toolbar { noteToolbar }
        .task(id: noteUrl) { joinPresence() }
        .onChange(of: model.sharingPresence) { _, enabled in
            if enabled {
                joinPresence()
            } else {
                leavePresence()
            }
        }
        .onDisappear(perform: leavePresence)
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
    }

    #if os(macOS)
    private var styleBinding: Binding<String> {
        let validKeys = Set(EditorController.styles.map(\.key))
        return Binding(
            get: { validKeys.contains(editor.currentStyleKey) ? editor.currentStyleKey : "paragraph" },
            set: { editor.applyStyle($0) }
        )
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { CodeLanguage.named(editor.currentCodeLanguage).id },
            set: { editor.applyCodeLanguage(CodeLanguage.named($0)) }
        )
    }
    #endif
}

private struct FocusModeControl: View {
    @Bindable var model: NotesModel
    @State private var showingOptions = false

    private var partial: Bool {
        !model.focusModeEnabled && (!model.applyingIncomingChanges || !model.sendingChanges || !model.sharingPresence)
    }

    private var focusOptions: some View {
        Group {
            Toggle("Apply incoming changes", isOn: Binding(
                get: { model.applyingIncomingChanges },
                set: model.setApplyingIncomingChanges
            ))
            .disabled(model.changingIncomingChanges)
            Toggle("Send my changes", isOn: Binding(
                get: { model.sendingChanges },
                set: model.setSendingChanges
            ))
            .disabled(model.changingSendingChanges)
            Toggle("Share presence", isOn: Binding(
                get: { model.sharingPresence },
                set: model.setSharingPresence
            ))
        }
    }

    var body: some View {
        #if os(macOS)
        Button {
            model.setFocusMode(!model.focusModeEnabled)
        } label: {
            Label("Focus", systemImage: model.focusModeEnabled ? "moon.fill" : "moon")
                .overlay(alignment: .topTrailing) {
                    if partial {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 5, height: 5)
                            .offset(x: 2, y: -2)
                    }
                }
        }
        .disabled(model.changingIncomingChanges || model.changingSendingChanges)
        .help(model.focusModeEnabled ? "Leave Focus Mode" : "Enter Focus Mode")
        .contextMenu { focusOptions }
        #else
        HStack(spacing: 2) {
            Button {
                model.setFocusMode(!model.focusModeEnabled)
            } label: {
                Label("Focus", systemImage: model.focusModeEnabled ? "moon.fill" : "moon")
            }
            .disabled(model.changingIncomingChanges || model.changingSendingChanges)
            .help(model.focusModeEnabled ? "Leave Focus Mode" : "Enter Focus Mode")

            Button {
                showingOptions.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .help("Focus Options")
            .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    focusOptions
                }
                .toggleStyle(.switch)
                .padding(14)
                .frame(width: 250)
            }
        }
        #endif
    }
}

/// The Notes-style treatment behind the floating toolbar: the editor extends
/// under it, and only content that scrolls into that strip frosts and fades.
/// Resting content sits below the toolbar (the scroll view's automatic
/// insets) and is untouched.
private struct PresenceFacesView: View {
    let presence: PresenceManager
    @Environment(NotesModel.self) private var model

    @ViewBuilder
    private func face(name: String?, color: String?, focused: Bool, avatar: Data? = nil) -> some View {
        Group {
            if let avatar, let image = PImage(data: avatar) {
                Image(pImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 22, height: 22)
                    .clipShape(Circle())
            } else {
                Text(String((name ?? "?").prefix(1)).uppercased())
                    .font(.caption2.weight(.semibold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(PresenceManager.swatch(color).opacity(0.25)))
            }
        }
        .overlay(Circle().strokeBorder(PresenceManager.swatch(color), lineWidth: 2))
        .opacity(focused ? 1 : 0.35)
        .help(name ?? "Anonymous")
    }

    var body: some View {
        let peers = presence.orderedPeers
        // only when someone else is here — then self first, like patchwork
        if presence.docUrl != nil, !peers.isEmpty {
            HStack(spacing: 3) {
                face(
                    name: model.contactName ?? "Anonymous",
                    color: PresenceManager.stableColor(for: model.presenceContactUrl ?? "self"),
                    focused: true,
                    avatar: model.contactAvatarData
                )
                ForEach(peers) { peer in
                    face(name: peer.name, color: peer.color, focused: peer.focused)
                }
            }
            .animation(.default, value: peers.map(\.senderId))
        }
    }
}

private struct MinimapView: View {
    let controller: EditorController

    private func color(for kind: MinimapKind) -> Color {
        switch kind {
        case .heading: .primary.opacity(0.75)
        case .code: Color(red: 0.26, green: 0.52, blue: 0.75).opacity(0.5)
        case .quote: Color(red: 1.0, green: 0.30, blue: 0.59).opacity(0.5)
        case .embed: .secondary.opacity(0.45)
        case .text: .secondary.opacity(0.22)
        }
    }

    private func width(for kind: MinimapKind) -> CGFloat {
        switch kind {
        case .heading: 18
        case .code, .embed: 14
        case .quote: 12
        case .text: 10
        }
    }

    var body: some View {
        let rows = controller.minimapRows
        let docHeight = max(controller.minimapDocHeight, 1)
        GeometryReader { proxy in
            let scale = min(proxy.size.height / docHeight, 0.12)
            Canvas { context, _ in
                for row in rows {
                    let rect = CGRect(
                        x: 2,
                        y: row.y * scale,
                        width: width(for: row.kind),
                        height: max(row.kind == .text ? 1.5 : 2.5, row.height * scale - 1)
                    )
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color(for: row.kind)))
                }
                if let viewport = controller.minimapViewport {
                    let lens = CGRect(
                        x: 0,
                        y: viewport.y * scale,
                        width: 22,
                        height: max(6, viewport.height * scale)
                    )
                    context.fill(Path(roundedRect: lens, cornerRadius: 3), with: .color(.secondary.opacity(0.14)))
                    context.stroke(Path(roundedRect: lens, cornerRadius: 3), with: .color(.secondary.opacity(0.35)), lineWidth: 1)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let mapHeight = docHeight * scale
                        guard mapHeight > 0 else { return }
                        controller.minimapJump(fraction: value.location.y / mapHeight)
                    }
            )
        }
        .frame(width: 22)
    }
}

private struct CanvasStashView: View {
    let controller: EditorController?

    var body: some View {
        if let controller, let core = controller.core {
            let _ = controller.docVersion
            let cards = core.stashedCards()
            if cards.isEmpty {
                ContentUnavailableView(
                    "Nothing Stashed",
                    systemImage: "square.grid.3x1.folder.badge.plus",
                    description: Text("Format → Stash Paragraph to Canvas parks the current paragraph here; drag a card back into the note to return it.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .frame(
                                width: max(400, (cards.map(\.x).max() ?? 0) + 240),
                                height: max(400, (cards.map(\.y).max() ?? 0) + 220)
                            )
                            .contentShape(Rectangle())
                            .gesture(
                                SpatialTapGesture(count: 2)
                                    .onEnded { value in
                                        core.addBlankCardToCanvas(at: value.location)
                                    }
                            )
                        ForEach(cards) { card in
                            StashCardView(card: card, core: core)
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("No Note Open", systemImage: "square.grid.3x1.folder.badge.plus")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct StashSnippetView {
    let attributed: NSAttributedString

    @MainActor
    final class Coordinator {
        let markers = ListMarkerLayoutDelegate()
    }

    @MainActor
    func makeCoordinator() -> Coordinator { Coordinator() }
}

#if os(macOS)
extension StashSnippetView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.textLayoutManager?.delegate = context.coordinator.markers
        textView.textLayoutManager?.renderingAttributesValidator = CodeHighlight.applyRenderingAttributes
        textView.textContainer?.widthTracksTextView = true
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 0)
        textView.textStorage?.setAttributedString(attributed)
        return textView
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        if nsView.attributedString() != attributed {
            nsView.textStorage?.setAttributedString(attributed)
        }
    }
}
#else
extension StashSnippetView: UIViewRepresentable {
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: true)
        textView.textLayoutManager?.delegate = context.coordinator.markers
        textView.textLayoutManager?.renderingAttributesValidator = CodeHighlight.applyRenderingAttributes
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        textView.textStorage.setAttributedString(attributed)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if !uiView.textStorage.isEqual(to: attributed) {
            uiView.textStorage.setAttributedString(attributed)
        }
    }
}
#endif

private struct StashCardView: View {
    let card: StashedCard
    let core: EditorCore
    @State private var dragOffset: CGSize = .zero

    private var paper: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    private var tilt: Angle {
        .degrees(Double(card.location % 5) - 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            StashSnippetView(attributed: card.attributed)
                .frame(height: min(card.contentHeight + 4, 150))
                .allowsHitTesting(false)
                .clipped()
            HStack {
                Button("Return to Note") { core.unstashInPlace(at: card.location) }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(10)
        .frame(width: 184, alignment: .leading)
        .background(paper, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.18)))
        .shadow(color: .black.opacity(0.16), radius: 5, y: 3)
        .rotationEffect(tilt)
        .offset(x: card.x + dragOffset.width, y: card.y + dragOffset.height)
        .simultaneousGesture(
            DragGesture()
                .onChanged { dragOffset = $0.translation }
                .onEnded { value in
                    core.moveStash(card, to: CGPoint(
                        x: card.x + value.translation.width,
                        y: card.y + value.translation.height
                    ))
                    dragOffset = .zero
                }
        )
        .onDrag { NSItemProvider(object: "lush-stash:\(card.location)" as NSString) }
        .contextMenu {
            Button("Return to Note") { core.unstashInPlace(at: card.location) }
        }
    }
}

private struct OutlineListView: View {
    let controller: EditorController?

    var body: some View {
        if let controller, let core = controller.core {
            let _ = controller.docVersion
            let items = core.outlineItems()
            if items.isEmpty {
                ContentUnavailableView(
                    "No Headings",
                    systemImage: "list.bullet.indent",
                    description: Text("Headings in this note appear here.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(items) { item in
                            Button {
                                controller.scrollTo(location: item.location)
                            } label: {
                                Text(item.text.isEmpty ? "Untitled" : item.text)
                                    .font(item.level == 1 ? .callout.weight(.semibold) : .callout)
                                    .foregroundStyle(item.level >= 3 ? .secondary : .primary)
                                    .lineLimit(1)
                                    .padding(.leading, CGFloat(item.level - 1) * 14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 12)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        } else {
            ContentUnavailableView(
                "No Note Open",
                systemImage: "list.bullet.indent"
            )
        }
    }
}

private struct FindBar: View {
    @Bindable var controller: EditorController
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in note", text: $controller.findQuery)
                .textFieldStyle(.plain)
                .focused($focused)
                .frame(width: 170)
                .onSubmit { controller.findNext() }
                .onChange(of: controller.findQuery) { controller.findQueryChanged() }
            Text(controller.findMatchCount == 0 ? "0" : "\(controller.findIndex)/\(controller.findMatchCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                controller.findPrevious()
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(controller.findMatchCount == 0)
            Button {
                controller.findNext()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(controller.findMatchCount == 0)
            Button("Done") { controller.closeFind() }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.25)))
        .onEscape { controller.closeFind() }
        .onAppear { focused = true }
    }
}

private struct ToolbarScrollFade: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let inset = proxy.safeAreaInsets.top
            let band = inset + 24
            let edge = band > 0 ? inset / band : 0
            content
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black.opacity(0.5), location: edge),
                                .init(color: .black, location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: max(band, 1))
                        Color.black
                    }
                }
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .frame(height: max(band, 1))
                        .mask {
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black.opacity(0.35), location: edge),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                        .allowsHitTesting(false)
                }
                .ignoresSafeArea(edges: .top)
        }
    }
}

extension View {
    func toolbarScrollFade() -> some View {
        modifier(ToolbarScrollFade())
    }
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

/// Floating "you are not looking at live Main" markers over an editor.
private struct EditorStatusBadges: View {
    var draftName: String?
    var readOnly: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let draftName {
                badge(draftName, icon: "arrow.branch", stroke: Color.accentColor)
            }
            if readOnly {
                badge("Read Only", icon: "clock.arrow.circlepath", stroke: .secondary)
            }
        }
        .padding(.top, 10)
        .padding(.leading, 16)
        .allowsHitTesting(false)
    }

    private func badge(_ text: String, icon: String, stroke: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(stroke.opacity(0.4), lineWidth: 1))
    }
}

struct PatchworkDetail: View {
    let docUrl: String
    var historyVersion: DocHistoryEntry? = nil
    #if os(macOS)
    var rightSidebarVisible: Binding<Bool>? = nil
    #endif
    @Environment(NotesModel.self) private var model
    @State private var tools: [ToolChoice] = []
    @State private var toolInput: String
    @State private var appliedToolId: String?
    @State private var toolsLoaded = false
    @State private var mainScrubTask: Task<Void, Never>?
    #if os(iOS)
    @State private var showingInspector = false
    @State private var inspectorTab: RightSidebarTab = .info
    @State private var inspectorHistoryEntry: DocHistoryEntry?
    #endif

    #if os(macOS)
    init(docUrl: String, historyVersion: DocHistoryEntry? = nil, rightSidebarVisible: Binding<Bool>? = nil) {
        self.docUrl = docUrl
        self.historyVersion = historyVersion
        self.rightSidebarVisible = rightSidebarVisible
        let remembered = PatchworkWeb.lastTool(for: docUrl)
        _appliedToolId = State(initialValue: remembered)
        _toolInput = State(initialValue: remembered ?? "")
    }
    #else
    init(docUrl: String, historyVersion: DocHistoryEntry? = nil) {
        self.docUrl = docUrl
        self.historyVersion = historyVersion
        let remembered = PatchworkWeb.lastTool(for: docUrl)
        _appliedToolId = State(initialValue: remembered)
        _toolInput = State(initialValue: remembered ?? "")
    }
    #endif

    private func joinPresence() {
        if historyVersion == nil {
            model.presence.join(docUrl)
        }
    }

    private func leavePresence() {
        if model.presence.docUrl == docUrl {
            model.presence.leave()
        }
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
        // The draft overlay provider streams freshly-pinned repo:handle-descriptor
        // answers whenever the checkout doc's checkpoint changes, so OverlayRepo
        // swaps handle backings in place — no remount on scrub. The docUrl is
        // always the plain origin URL; heads ride inside the checkout doc's `at`
        // map, not on the URL itself.
        let draftUrl = model.checkedOutDrafts[docUrl]
        let scrubbed = historyVersion != nil
        Group {
            if PatchworkWeb.available {
                PatchworkBoxWebViewWrapper(
                    docUrl: docUrl,
                    toolId: appliedToolId,
                    draftUrl: draftUrl,
                    checkoutUrl: model.checkoutDocs[docUrl],
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
        .overlay(alignment: .topLeading) {
            EditorStatusBadges(
                draftName: draftUrl.flatMap { model.draftName($0, in: docUrl) },
                readOnly: scrubbed
            )
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
        .onChange(of: historyVersion?.hash) { _, hash in
            guard model.checkedOutDrafts[docUrl] == nil else { return }
            let pins: [CheckpointPin]? = historyVersion.map { [CheckpointPin(originalUrl: docUrl, heads: $0.heads)] }
            mainScrubTask?.cancel()
            mainScrubTask = Task {
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                await model.setDraftCheckpoint(host: docUrl, pins: pins)
            }
        }
        .task(id: docUrl) { joinPresence() }
        .onChange(of: model.sharingPresence) { _, enabled in
            if enabled { joinPresence() } else { leavePresence() }
        }
        .onDisappear(perform: leavePresence)
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
            #if os(macOS)
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .primaryAction) {
                PresenceFacesView(presence: model.presence)
            }
            ToolbarSpacer(.fixed)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    rightSidebarVisible?.wrappedValue.toggle()
                } label: {
                    Label("Info", systemImage: "info.circle")
                }
            }
            #else
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingInspector = true
                } label: {
                    Label("Info", systemImage: "info.circle")
                }
            }
            #endif
        }
        #if os(iOS)
        .sheet(isPresented: $showingInspector) {
            RightSidebarView(
                url: docUrl,
                node: model.node(for: docUrl),
                selectedTab: $inspectorTab,
                selectedEntry: $inspectorHistoryEntry
            )
            .environment(model)
        }
        #endif
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
                                    model.status = "Copied to clipboard — paste into the note"
                                }
                                AppRouter.shared.pending = .note(note.url)
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
