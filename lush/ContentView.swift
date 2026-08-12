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
    case smart(String)
    case calendar
    case meetingNotes
    case shortcutsHelp
}

struct MoveTarget: Identifiable {
    let id = UUID()
    let urls: [String]
}

struct SmartNotebookEdit: Identifiable {
    let id = UUID()
    let folder: SmartNotebook
    var isNew = false
}

struct PatchworkCreateRequest: Identifiable {
    let id = UUID()
    let preferredType: String?
    let toolId: String?
    let folderUrl: String?
}

struct SearchFieldToken: Identifiable, Equatable {
    let id = UUID()
    let raw: String

    var label: String { SearchSyntax(raw).clauses.first?.label ?? raw }
}

#if os(macOS)
struct MainWindowRoute: Codable, Hashable {
    let id: UUID
    let selection: String?
}

@MainActor
enum MainWindowTabs {
    private static var parents: [UUID: NSWindow] = [:]

    private(set) static var routedSelection: String?

    static func open(selection: String?, using openWindow: OpenWindowAction) {
        let route = MainWindowRoute(id: UUID(), selection: selection)
        routedSelection = selection
        if let window = NSApp.keyWindow {
            parents[route.id] = window
        }
        openWindow(id: "main", value: route)
    }

    static func claimRoute(_ selection: String?) {
        guard let selection, routedSelection == selection else { return }
        routedSelection = nil
    }

    static func attach(_ window: NSWindow, route: MainWindowRoute?) {
        window.tabbingIdentifier = "lush-main"
        window.tabbingMode = .preferred
        guard let route, let parent = parents.removeValue(forKey: route.id), parent !== window else { return }
        let frame = parent.frame
        window.orderOut(nil)
        DispatchQueue.main.async {
            window.setFrame(frame, display: false)
            parent.addTabbedWindow(window, ordered: .above)
            for tab in window.tabbedWindows ?? [parent, window] {
                tab.setFrame(frame, display: true)
            }
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async {
                for tab in window.tabbedWindows ?? [window] {
                    tab.setFrame(frame, display: true)
                }
            }
        }
    }
}

struct OpenInTabKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var openInTab: ((String) -> Void)? {
        get { self[OpenInTabKey.self] }
        set { self[OpenInTabKey.self] = newValue }
    }
}

private struct MainWindowBridge: NSViewRepresentable {
    let route: MainWindowRoute?
    let title: String
    let connected: (NSWindow) -> Void

    func makeNSView(context: Context) -> BridgeView {
        BridgeView()
    }

    func updateNSView(_ view: BridgeView, context: Context) {
        view.update = { window in
            window.title = title
            window.tab.title = title
            MainWindowTabs.attach(window, route: route)
            DispatchQueue.main.async { connected(window) }
        }
        view.apply()
    }

    final class BridgeView: NSView {
        var update: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let window, let update else { return }
            update(window)
        }
    }
}

private struct SidebarHistoryEntry: Equatable {
    let tag: String
    let identity: String
}

struct DoubleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let recognizer = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.doubleClicked)
        )
        recognizer.numberOfClicksRequired = 2
        recognizer.delegate = context.coordinator
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.action = action
    }

    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func doubleClicked() { action() }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

private struct PrimaryClickGesture: NSGestureRecognizerRepresentable {
    let action: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSGestureRecognizer(context: Context) -> NSClickGestureRecognizer {
        let recognizer = NSClickGestureRecognizer()
        recognizer.buttonMask = 0x1
        return recognizer
    }

    func updateNSGestureRecognizer(_ recognizer: NSClickGestureRecognizer, context: Context) {
        context.coordinator.action = action
    }

    func handleNSGestureRecognizerAction(_ recognizer: NSClickGestureRecognizer, context: Context) {
        context.coordinator.action()
    }

    final class Coordinator {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }
    }
}
#endif

struct ContentView: View {
    @Environment(NotesModel.self) private var model
    @Environment(ContextTracker.self) private var contextTracker
    @Environment(\.scenePhase) private var scenePhase
    @State private var router = AppRouter.shared
    @State private var patchworkCreateRequest: PatchworkCreateRequest?
    @State private var smartEditor: SmartNotebookEdit?
    @State private var folderSettingsTarget: FolderNode?
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @State private var selectedItemUrls: Set<String> = []
    @State private var sidebarSelectionAnchor: String?
    @State private var searchText = ""
    @State private var searchTokens: [SearchFieldToken] = []
    @State private var preserveSearchInputOnce = false
    @State private var searchPresented = false
    @State private var searchHits: [SearchHit] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var sidebarSelectionTask: Task<Void, Never>?
    @State private var deferredSidebarTag: String?
    @State private var searchScope: String?
    @State private var renamingUrl: String?
    @State private var renameText = ""
    @FocusState private var sidebarFocused: Bool
    @FocusState private var searchFocused: Bool
    @State private var expanded: Set<String> = []
    @State private var revealTarget: String?
    @State private var moveTarget: MoveTarget?
    @State private var pinnedExpanded = true
    @State private var smartExpanded: Set<String> = []
    @State private var sectionOrder: [SidebarSection] = SidebarSection.load()
    @State private var collapsedSections: Set<String> = []
    @State private var rightSidebarVisible = false
    @State private var rightSidebarTab: RightSidebarTab = .history
    @AppStorage("rightSidebarWidth") private var rightSidebarWidth: Double = 280
    @State private var rightSidebarDragStart: Double?
    @State private var rightSidebarLiveWidth: Double?
    @State private var selectedHistoryEntry: DocHistoryEntry?
    @State private var sidebarHistory: [SidebarHistoryEntry] = []
    @State private var sidebarHistoryIndex = -1
    @State private var movingThroughSidebarHistory = false
    @State private var selectedDocumentUrl: String?
    @State private var appliedInitialRoute = false
    @State private var initialRouteSelection: String?
    @State private var hostWindow: NSWindow?
    private let initialRoute: MainWindowRoute?

    private static let expandedKey = "expandedFolders"
    private static let seededRootsKey = "seededRoots"
    private static let pinnedExpandedKey = "pinnedExpanded"
    private static let collapsedSectionsKey = "collapsedSidebarSections"
    #else
    @State private var path: [NavRoute] = []
    @State private var wideRoute: NavRoute?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    #if os(macOS)
    init(initialRoute: MainWindowRoute? = nil) {
        self.initialRoute = initialRoute
    }
    #else
    init() {}
    #endif

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .background {
            MainWindowBridge(route: initialRoute, title: windowTitle) { window in
                if hostWindow !== window {
                    hostWindow = window
                }
            }
            .frame(width: 0, height: 0)
        }
        .environment(\.openInTab) { url in
            MainWindowTabs.open(selection: url, using: openWindow)
        }
        .overlay {
            if model.focusModeEnabled {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Color.purple, lineWidth: 2)
                    .padding(1)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: selectedItemUrls) {
            let initialSelection = selectedItemUrls.count == 1
                && selectedItemUrls.first == initialRouteSelection
            initialRouteSelection = nil
            recordSidebarHistory(selectedItemUrls)
            selectedDocumentUrl = documentUrl(in: selectedItemUrls)
            // Selecting the top search hit must not pull focus out of the
            // field mid-query.
            if !searchFocused { sidebarFocused = true }
            smartEditor = nil
            let deferred = deferredSidebarTag
            deferredSidebarTag = nil
            guard selectedItemUrls.count == 1, let tag = selectedItemUrls.first else { return }
            guard !tag.hasPrefix("smart:"), tag != Agenda.sidebarTag, tag != Agenda.meetingNotesTag else { return }
            guard !initialSelection else { return }
            let delay = deferred == tag ? 80 : 0
            scheduleSidebarSelection(Self.sidebarUrl(tag), delay: delay)
        }
        .onChange(of: model.activeEditor?.padded) { _, padded in
            guard let padded, padded > 0 else { return }
            rightSidebarVisible = true
            rightSidebarTab = .pad
        }
        .onOpenURL { url in
            if url.scheme == "lush" || url.scheme == "automerge" {
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
            guard let url, hostWindow?.isKeyWindow != false else { return }
            guard !isOtherWindowsRoute(url) else { return }
            selectedHistoryEntry = nil
            selectedDocumentUrl = url
            if !selectedItemUrls.contains(where: { Self.sidebarUrl($0) == url }) {
                selectedItemUrls = [rowTag(for: url)]
            }
        }
        .onChange(of: initialRoute, initial: true) { _, route in
            guard let route, !appliedInitialRoute else { return }
            appliedInitialRoute = true
            if let selection = route.selection {
                initialRouteSelection = selection
                selectedItemUrls = [selection]
                selectedDocumentUrl = documentUrl(in: [selection])
            } else {
                selectedItemUrls = []
                selectedDocumentUrl = nil
            }
        }
        .onAppear {
            if !appliedInitialRoute, let url = model.selectedNoteUrl,
               !selectedItemUrls.contains(where: { Self.sidebarUrl($0) == url }) {
                selectedDocumentUrl = url
                selectedItemUrls = [rowTag(for: url)]
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow, window === hostWindow else { return }
            MainWindowTabs.claimRoute(initialRoute?.selection)
            model.selectedNoteUrl = selectedDocumentUrl
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
        .fileImporter(
            isPresented: Binding(
                get: { model.showingFileImporter },
                set: { model.showingFileImporter = $0 }
            ),
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): model.prepareFileImport(urls, into: model.folderUrl)
            case .failure(let error): model.status = "Couldn't import: \(error.localizedDescription)"
            }
        }
        .sheet(item: Binding(
            get: { model.fileImportRequest },
            set: { model.fileImportRequest = $0 }
        )) { request in
            FileImportChoiceSheet(request: request)
                .environment(model)
        }
        #else
        Group {
            if usesWideLayout {
                NavigationSplitView {
                    FolderScreen(folderUrl: nil, push: openMobile)
                        .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
                } detail: {
                    NavigationStack {
                        if let wideRoute {
                            mobileDestination(wideRoute)
                        } else {
                            ContentUnavailableView("Select a Note", systemImage: "doc.text")
                        }
                    }
                }
            } else {
                NavigationStack(path: $path) {
                    FolderScreen(folderUrl: nil, push: openMobile)
                        .navigationDestination(for: NavRoute.self) { route in
                            mobileDestination(route)
                        }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.focusModeEnabled {
                FocusModeControl(model: model)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .tint(.purple)
                    .padding()
            }
        }
        .onOpenURL { url in
            if url.scheme == "lush" || url.scheme == "automerge" {
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
            if usesWideLayout {
                wideRoute = .note(url)
            } else if path.isEmpty {
                path = [.note(url)]
            }
        }
        .onAppear {
            if let url = model.selectedNoteUrl {
                if usesWideLayout {
                    wideRoute = .note(url)
                } else if path.isEmpty {
                    path = [.note(url)]
                }
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
            selectedItemUrls = [rowTag(for: url)]
            #else
            openMobile(.patchwork(url))
            #endif
        })
        .environment(model)
    }

    private func processPending() {
        #if os(macOS)
        guard hostWindow?.isKeyWindow != false else { return }
        #endif
        guard let action = router.pending else { return }
        if action == .shortcutsHelp {
            router.pending = nil
            #if os(macOS)
            openWindow(id: "shortcuts-help")
            #else
            openMobile(.shortcutsHelp)
            #endif
            return
        }
        guard model.folderUrl != nil else { return }
        router.pending = nil
        switch action {
        case .newNote:
            Task {
                contextTracker.start()
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
            Task { await openDispatched(url) }
        case .folder(let url):
            Task { await model.selectFolder(url) }
            openFolder(url)
        case .calendar(let day, let item):
            AgendaStore.shared.focusItem = item
            AgendaStore.shared.focusDay = day.map { Calendar.current.startOfDay(for: $0) }
            openCalendar()
        case .search(let query):
            #if os(macOS)
            setSearchQuery(query)
            searchPresented = true
            searchFocused = true
            sidebarFocused = true
            runSearch()
            #else
            path = []
            wideRoute = nil
            model.searchQuery = query
            #endif
        case .createPatchwork(let preferredType, let toolId, let folderUrl):
            patchworkCreateRequest = PatchworkCreateRequest(
                preferredType: preferredType,
                toolId: toolId,
                folderUrl: folderUrl
            )
        case .newSmartNotebook:
            smartEditor = SmartNotebookEdit(folder: newSmartNotebook(), isNew: true)
        case .share:
            Task { await model.drainSharedIntake() }
        case .shortcutsHelp:
            break
        }
    }

    private func open(_ url: String) {
        #if os(macOS)
        selectedDocumentUrl = url
        model.selectedNoteUrl = url
        selectedItemUrls = [rowTag(for: url)]
        #else
        openMobile(.note(url))
        #endif
    }

    private func openDispatched(_ url: String) async {
        let kind: String?
        if let known = model.node(for: url)?.kind {
            kind = known
        } else {
            kind = await model.documentKind(for: url)
        }
        switch kind {
        case "folder":
            await model.selectFolder(url)
            openFolder(url)
        case "lush:script":
            #if os(macOS)
            open(url)
            #else
            openMobile(.script(url))
            #endif
        case "rich", "lush":
            model.pendingFocusUrl = url
            open(url)
        case .some(_):
            model.rememberPatchworkDocument(url)
            #if os(macOS)
            open(url)
            #else
            openMobile(.patchwork(url))
            #endif
        case nil:
            model.pendingFocusUrl = url
            open(url)
        }
    }

    private func openFolder(_ url: String) {
        #if os(macOS)
        selectedItemUrls = [rowTag(for: url)]
        #else
        openMobile(.folder(url))
        #endif
    }

    private func openCalendar() {
        #if os(macOS)
        selectedItemUrls = [Agenda.sidebarTag]
        #else
        openMobile(.calendar)
        #endif
    }

    #if os(iOS)
    private var usesWideLayout: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
    }

    private func openMobile(_ route: NavRoute) {
        if usesWideLayout {
            wideRoute = route
        } else {
            path.append(route)
        }
    }

    @ViewBuilder
    private func mobileDestination(_ route: NavRoute) -> some View {
        switch route {
        case .folder(let url):
            FolderScreen(folderUrl: url, push: openMobile)
        case .note(let url):
            NoteDetail(noteUrl: model.resolvedNoteUrl(url))
                .onAppear { model.selectedNoteUrl = url }
        case .patchwork(let url):
            PatchworkDetail(docUrl: url)
        case .script(let url):
            ScriptEditorView(url: url)
                .environment(model)
        case .recents:
            RecentsScreen(push: openMobile)
        case .smart(let id):
            SmartNotebookScreen(smartNotebookId: id, push: openMobile)
        case .calendar:
            AgendaScreen { openMobile(.note($0)) }
        case .meetingNotes:
            MeetingNotesScreen { openMobile(.note($0)) }
        case .shortcutsHelp:
            ShortcutsHelpView()
        }
    }
    #endif

    #if os(macOS)

    private var sidebar: some View {
        ScrollViewReader { proxy in
            sidebarList
                .onDrop(
                    of: [UTType.plainText.identifier, UTType.fileURL.identifier],
                    delegate: SidebarDropCleanup(folderUrl: model.folderUrl, model: model)
                )
                .onChange(of: revealTarget) { _, row in
                    guard let row else { return }
                    revealTarget = nil
                    Task { @MainActor in
                        await Task.yield()
                        withAnimation { proxy.scrollTo(row, anchor: .center) }
                    }
                }
        }
    }



    private var sidebarList: some View {
        List {
            if searchQueryText.isEmpty {
                ForEach(sectionOrder, id: \.self) { section in
                    sectionRows(section)
                }
                Color.clear
                    .frame(height: 28)
                    .modifier(SectionTailDrop(order: $sectionOrder, model: model))
                    .listRowInsets(sidebarRowInsets(depth: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                if let searchScope { searchScopeRow(searchScope) }
                saveSearchRow
                ForEach(searchHits, id: \.url) { hit in
                    searchHitRow(hit)
                    .padding(.trailing, sidebarTrailingGutter)
                    .contentShape(Rectangle())
                    .tag(hit.url)
                    .gesture(PrimaryClickGesture { selectSidebarRow(hit.url) })
                    .onDrag({ SidebarDrag.provider(hit.url, kind: .item) }, preview: {
                        DragPreviewView(name: hit.name.isEmpty ? "Untitled" : hit.name)
                    })
                    .listRowInsets(sidebarRowInsets(depth: 0))
                    .listRowBackground(selectionBackground(url: hit.url, tag: hit.url))
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
        .sheet(item: $folderSettingsTarget) { node in
            FolderSettingsEditor(node: node)
                .environment(model)
        }
        .task {
            expanded = Set(
                UserDefaults.standard.stringArray(forKey: Self.expandedKey) ?? []
            )
            if UserDefaults.standard.object(forKey: Self.pinnedExpandedKey) != nil {
                pinnedExpanded = UserDefaults.standard.bool(forKey: Self.pinnedExpandedKey)
            }
            collapsedSections = Set(
                UserDefaults.standard.stringArray(forKey: Self.collapsedSectionsKey) ?? []
            )
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 230)
        .onChange(of: model.folderTree, initial: true) {
            seedRootExpansion()
            resolveSelectionRows()
        }
        .onChange(of: expanded) {
            resolveSelectionRows()
        }
        .onChange(of: searchText) { oldValue, newValue in
            let preserve = preserveSearchInputOnce
            preserveSearchInputOnce = false
            let inserted = newValue.difference(from: oldValue).reduce(into: 0) { count, change in
                if case .insert = change { count += 1 }
            }
            absorbSearchTokens(commitAll: !preserve && inserted > 1)
        }
        .onChange(of: searchTokens) {
            searchDidChange()
        }
        .onChange(of: searchPresented) {
            if !searchPresented { searchScope = nil }
        }
        .onChange(of: model.notes) {
            if !searchQueryText.isEmpty { runSearch(selectTop: false) }
            model.refreshSmartHits()
        }
        .onChange(of: model.folderTree) {
            if !searchQueryText.isEmpty { runSearch(selectTop: false) }
            model.refreshSmartHits()
        }
        .onChange(of: model.smartNotebooks, initial: true) {
            model.refreshSmartHits()
        }
        .onKeyPress(.return) {
            guard renamingUrl == nil,
                  selectedItemUrls.count == 1,
                  let tag = selectedItemUrls.first
            else { return .ignored }
            let selected = Self.sidebarUrl(tag)
            if let node = model.node(for: selected), node.kind == "folder" {
                setExpanded(!expanded.contains(selected), for: selected)
            } else {
                Task { await model.selectItem(selected) }
            }
            return .handled
        }
        .onKeyPress(.upArrow) { moveSidebarSelection(by: -1) }
        .onKeyPress(.downArrow) { moveSidebarSelection(by: 1) }
        .onKeyPress { press in
            guard press.modifiers == .control else { return .ignored }
            if press.characters == "p" { return moveSidebarSelection(by: -1) }
            if press.characters == "n" { return moveSidebarSelection(by: 1) }
            return .ignored
        }
        .onKeyPress(.space) {
            guard renamingUrl == nil,
                  selectedItemUrls.count == 1,
                  let tag = selectedItemUrls.first
            else { return .ignored }
            if tag.hasPrefix("smart:") {
                let id = String(tag.dropFirst(6))
                setSmartExpanded(!smartExpanded.contains(id), id: id)
                return .handled
            }
            let selected = Self.sidebarUrl(tag)
            guard let node = model.node(for: selected), node.kind == "folder" else { return .ignored }
            setExpanded(!expanded.contains(selected), for: selected)
            return .handled
        }
        .onKeyPress(.delete) {
            guard renamingUrl == nil, !selectedItemUrls.isEmpty else { return .ignored }
            for tag in selectedItemUrls {
                let url = Self.sidebarUrl(tag)
                if let node = model.node(for: url), node.parentUrl != nil {
                    model.removeEntry(parentUrl: node.parentUrl, url: url)
                }
            }
            return .handled
        }
        .focused($sidebarFocused)
        .foregroundStyle(Color.primary)
        .tint(Color(red: 1.0, green: 0.412, blue: 0.647))
    }

    private func focusCurrentNoteSearch() {
        NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: nil)
    }

    private func selectSidebarRow(_ tag: String) {
        if let event = NSApp.currentEvent {
            if [.rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp].contains(event.type) {
                return
            }
            if [.leftMouseDown, .leftMouseUp].contains(event.type),
               event.modifierFlags.contains(.control) {
                return
            }
        }
        let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.shift) {
            let rows = visibleSidebarRowTags
            let anchor = sidebarSelectionAnchor.flatMap { rows.firstIndex(of: $0) }
                ?? rows.firstIndex(where: { selectedItemUrls.contains($0) })
            if let anchor, let target = rows.firstIndex(of: tag) {
                let range = Set(rows[min(anchor, target)...max(anchor, target)])
                selectedItemUrls = modifiers.contains(.command) ? selectedItemUrls.union(range) : range
            } else {
                selectedItemUrls.insert(tag)
            }
        } else if modifiers.contains(.command) {
            if selectedItemUrls.contains(tag) {
                selectedItemUrls.remove(tag)
            } else {
                selectedItemUrls.insert(tag)
            }
            sidebarSelectionAnchor = tag
        } else {
            selectedItemUrls = [tag]
            sidebarSelectionAnchor = tag
        }
        if selectedItemUrls.count == 1,
           let selected = selectedItemUrls.first,
           model.node(for: Self.sidebarUrl(selected))?.kind == "folder" {
            model.selectedNoteUrl = nil
        }
        sidebarFocused = true
    }

    private func scheduleSidebarSelection(_ url: String, delay: Int) {
        sidebarSelectionTask?.cancel()
        sidebarSelectionTask = Task {
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            guard !Task.isCancelled else { return }
            if let node = model.node(for: url), node.kind == "folder" {
                await model.selectFolder(url)
            } else {
                await model.selectItem(url)
            }
        }
    }

    private var visibleSidebarRowTags: [String] {
        if !searchQueryText.isEmpty { return searchHits.map(\.url) }
        var tags: [String] = []
        for section in sectionOrder {
            switch section {
            case .calendar:
                tags.append(Agenda.sidebarTag)
            case .pinned:
                if pinnedExpanded {
                    tags += model.pinnedNodes.map { "pinned:\($0.url)" }
                }
            case .smart:
                guard !collapsedSections.contains(section.rawValue) else { continue }
                for folder in model.smartNotebooks {
                    tags.append("smart:\(folder.id)")
                    if smartExpanded.contains(folder.id) {
                        tags += (model.smartHits[folder.id] ?? []).map {
                            "smarthit:\(folder.id)\u{1}\($0.url)"
                        }
                    }
                }
            case .notebooks:
                guard !collapsedSections.contains(section.rawValue) else { continue }
                func append(_ nodes: [FolderNode], path: String) {
                    for row in Self.sidebarRows(nodes, path: path) {
                        tags.append(row.id)
                        if row.node.kind == "folder", expanded.contains(row.node.url) {
                            append(
                                model.orderedChildren(row.node.children ?? [], in: row.node.url),
                                path: row.id
                            )
                        }
                    }
                }
                append(model.visibleFolderTree, path: "")
            }
        }
        return tags
    }

    private func moveSidebarSelection(by offset: Int) -> KeyPress.Result {
        guard renamingUrl == nil else { return .ignored }
        let rows = visibleSidebarRowTags
        guard !rows.isEmpty else { return .ignored }
        let current = rows.firstIndex { selectedItemUrls.contains($0) }
        if current == nil, !selectedItemUrls.isEmpty { return .handled }
        let index = min(max((current ?? (offset > 0 ? -1 : rows.count)) + offset, 0), rows.count - 1)
        let tag = rows[index]
        deferredSidebarTag = tag
        selectedItemUrls = [tag]
        sidebarSelectionAnchor = tag
        revealTarget = tag
        return .handled
    }

    /// Notes-style: the sidebar becomes the hit list and the top hit opens, so
    /// typing walks straight into the best match without leaving the field.
    private func runSearch(selectTop: Bool = true) {
        searchTask?.cancel()
        let query = searchQueryText
        guard !query.isEmpty else {
            searchHits = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let hits = await model.search(query, in: searchScope)
            guard !Task.isCancelled else { return }
            searchHits = hits
            guard selectTop, let first = hits.first else { return }
            selectedItemUrls = [first.url]
            await model.selectItem(first.url)
        }
    }

    private func focusNotesSearch() {
        searchPresented = true
        searchFocused = true
        sidebarFocused = true
    }

    /// Points the sidebar search at one notebook. The field opens empty rather
    /// than re-running whatever was last typed, since the folder is the point.
    private func searchInFolder(_ url: String) {
        searchScope = url
        focusNotesSearch()
        if !searchQueryText.isEmpty { runSearch(selectTop: false) }
    }

    @ViewBuilder
    private func sectionRows(_ section: SidebarSection) -> some View {
        switch section {
        case .calendar:
            calendarRow
                .modifier(SectionDragReorder(section: .calendar, order: $sectionOrder))
                .listRowInsets(sidebarRowInsets(depth: 0))
                .listRowBackground(
                    selectionBackground(url: Agenda.sidebarTag, tag: Agenda.sidebarTag)
                )
        case .pinned:
            if !model.pinnedNodes.isEmpty {
                pinnedRootRow
                    .modifier(SectionDragReorder(section: .pinned, order: $sectionOrder))
                    .listRowInsets(sidebarRowInsets(depth: 0))
                if pinnedExpanded {
                    ForEach(model.pinnedNodes) { node in
                        pinnedNoteRow(node)
                    }
                }
            }
        case .smart:
            if !model.smartNotebooks.isEmpty {
                sectionHeader("Smart Notebooks", section: .smart)
                if !collapsedSections.contains(SidebarSection.smart.rawValue) {
                    ForEach(model.smartNotebooks) { folder in
                        smartNotebookRow(folder)
                            .listRowInsets(sidebarRowInsets(depth: 0))
                            .listRowBackground(
                                selectionBackground(
                                    url: "smart:\(folder.id)",
                                    tag: "smart:\(folder.id)"
                                )
                            )
                        if smartExpanded.contains(folder.id) {
                            ForEach(model.smartHits[folder.id] ?? [], id: \.url) { hit in
                                smartHitRow(hit, smartNotebookId: folder.id)
                            }
                        }
                    }
                }
            }
        case .notebooks:
            sectionHeader("Notebooks", section: .notebooks)
            if !collapsedSections.contains(SidebarSection.notebooks.rawValue) {
                nodeRows(model.visibleFolderTree)
            }
        }
    }

    private func sectionHeader(_ title: String, section: SidebarSection) -> some View {
        let collapsed = collapsedSections.contains(section.rawValue)
        return HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer(minLength: 8)
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 18)
        .padding(.bottom, 2)
        .padding(.trailing, sidebarTrailingGutter)
        .contentShape(Rectangle())
        .onTapGesture { toggleSection(section) }
        .modifier(SectionDragReorder(section: section, order: $sectionOrder))
        .listRowInsets(sidebarRowInsets(depth: 0))
    }

    private func toggleSection(_ section: SidebarSection) {
        if collapsedSections.contains(section.rawValue) {
            collapsedSections.remove(section.rawValue)
        } else {
            collapsedSections.insert(section.rawValue)
        }
        UserDefaults.standard.set(Array(collapsedSections), forKey: Self.collapsedSectionsKey)
    }

    private var calendarRow: some View {
        CalendarSidebarLabel()
            .font(.title3.weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
            .padding(.bottom, 5)
            .padding(.trailing, sidebarTrailingGutter)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                // Coming back lands where she left. Clicking the row while the
                // calendar is already up is the one way to ask for today.
                let wasSelected = calendarSelected
                selectSidebarRow(Agenda.sidebarTag)
                guard wasSelected else { return }
                AgendaStore.shared.restoreDay = nil
                AgendaStore.shared.focusDay = Calendar.current.startOfDay(for: Date())
            })
            .contextMenu {
                Button {
                    MainWindowTabs.open(selection: Agenda.sidebarTag, using: openWindow)
                } label: {
                    Label("Open in New Tab", systemImage: "plus.square.on.square")
                }
                Divider()
                Button("Show Meeting Notes") {
                    selectedItemUrls = [Agenda.meetingNotesTag]
                }
            }
            .tag(Agenda.sidebarTag)
            .listRowInsets(sidebarRowInsets(depth: 0))
    }

    private var calendarSelected: Bool {
        selectedItemUrls.count == 1 && selectedItemUrls.first == Agenda.sidebarTag
    }

    private var meetingNotesSelected: Bool {
        selectedItemUrls.count == 1 && selectedItemUrls.first == Agenda.meetingNotesTag
    }

    @ViewBuilder
    private func searchHitRow(_ hit: SearchHit) -> some View {
        let snippet = highlighted(hit.snippet, query: SearchSyntax(searchQueryText).text)
        if let node = model.node(for: hit.url) {
            NoteRowView(node: node, showFolder: true, snippet: snippet)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.name.isEmpty ? "Untitled" : hit.name)
                    .font(.body)
                    .lineLimit(1)
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            .padding(.vertical, 2)
        }
    }

    private func pinnedNoteRow(_ node: FolderNode) -> some View {
        let tag = "pinned:\(node.url)"
        return NoteRowView(node: node, showFolder: true)
            .padding(.trailing, sidebarTrailingGutter)
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .tag(tag)
            .id(tag)
            .gesture(PrimaryClickGesture { selectSidebarRow(tag) })
            .onDrag({ SidebarDrag.provider(node.url, kind: .item) }, preview: {
                DragPreviewView(name: node.displayName)
            })
            .modifier(PinReorderTarget(url: node.url, model: model))
            .listRowInsets(sidebarRowInsets(depth: 1))
            .listRowBackground(selectionBackground(url: node.url, tag: tag))
            .contextMenu {
                singleNoteContextMenu(for: node, showInFolder: true)
            }
    }

    private func nodeRows(_ nodes: [FolderNode], depth: Int = 0, path: String = "") -> AnyView {
        AnyView(
            ForEach(Self.sidebarRows(nodes, path: path)) { row in
                let node = row.node
                if node.kind == "folder" {
                    folderRow(for: node, depth: depth, tag: row.id)
                        .tag(row.id)
                        .listRowInsets(sidebarRowInsets(depth: depth))
                        .listRowBackground(selectionBackground(url: node.url, tag: row.id))
                    if expanded.contains(node.url) {
                        nodeRows(
                            model.orderedChildren(node.children ?? [], in: node.url),
                            depth: depth + 1,
                            path: row.id
                        )
                    }
                } else {
                    noteRow(for: node, depth: depth, tag: row.id)
                        .listRowInsets(sidebarRowInsets(depth: depth))
                        .listRowBackground(selectionBackground(url: node.url, tag: row.id))
                }
            }
        )
    }

    /// The same item can sit in a folder more than once, so a row is named by
    /// where it is, not by what it holds. Two copies are two selections.
    private static func sidebarRows(_ nodes: [FolderNode], path: String) -> [SidebarRow] {
        nodes.enumerated().map {
            SidebarRow(id: "\(path)\u{1}\($0.offset)\u{1}\($0.element.url)", node: $0.element)
        }
    }

    /// Where a url first shows up in the tree as it is currently unfolded.
    private func firstRowId(for url: String) -> String? {
        func walk(_ nodes: [FolderNode], path: String) -> String? {
            for row in Self.sidebarRows(nodes, path: path) {
                if row.node.url == url { return row.id }
                guard row.node.kind == "folder", expanded.contains(row.node.url) else { continue }
                let children = model.orderedChildren(row.node.children ?? [], in: row.node.url)
                if let hit = walk(children, path: row.id) { return hit }
            }
            return nil
        }
        return walk(model.visibleFolderTree, path: "")
    }

    private func rowTag(for url: String) -> String {
        if let row = firstRowId(for: url) { return row }
        if pinnedExpanded, model.isPinned(url) { return "pinned:\(url)" }
        return url
    }

    /// A url picked before its row existed — at launch, or while its folder was
    /// folded — is held as the bare url. Once the row shows up, point at it,
    /// otherwise every copy reads as the unfocused one.
    private func resolveSelectionRows() {
        guard searchQueryText.isEmpty else { return }
        let resolved = Set(selectedItemUrls.map { tag in
            guard !Self.isRowTag(tag), tag.hasPrefix("automerge:") else { return tag }
            return rowTag(for: tag)
        })
        if resolved != selectedItemUrls { selectedItemUrls = resolved }
    }

    /// Rows run the full width and keep the right-hand gutter in their own
    /// content, so every trailing chevron lands on the same line.
    private var sidebarTrailingGutter: CGFloat { 8 }

    private func sidebarRowInsets(depth: Int) -> EdgeInsets {
        EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0)
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
        .padding(.trailing, sidebarTrailingGutter)
        .contentShape(Rectangle())
        .onTapGesture {
            pinnedExpansionBinding.wrappedValue.toggle()
        }
    }

    private func smartNotebookRow(_ folder: SmartNotebook) -> some View {
        let tag = "smart:\(folder.id)"
        let isOpen = smartExpanded.contains(folder.id)
        return HStack(spacing: 8) {
            Label(folder.displayName, systemImage: "folder.badge.gearshape")
                .font(.title3.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if folder.showCount, let count = model.smartHits[folder.id]?.count {
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button {
                setSmartExpanded(!isOpen, id: folder.id)
            } label: {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 12)
        .padding(.bottom, 5)
        .padding(.trailing, sidebarTrailingGutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(PrimaryClickGesture { selectSidebarRow(tag) })
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            setSmartExpanded(!isOpen, id: folder.id)
        })
        .tag(tag)
        .onDrag({ SidebarDrag.provider(folder.id, kind: .smart) }, preview: {
            DragPreviewView(name: folder.displayName, isFolder: true)
        })
        .modifier(SmartReorderTarget(id: folder.id, model: model))
        .contextMenu {
            Group {
                Button {
                    smartEditor = SmartNotebookEdit(folder: folder)
                } label: {
                    Label("Edit Smart Notebook…", systemImage: "gearshape")
                }
                Button {
                    model.refreshSmartHits(folder)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Divider()
                Button(role: .destructive) {
                    model.removeSmartNotebook(id: folder.id)
                    smartExpanded.remove(folder.id)
                    model.smartHits[folder.id] = nil
                    SmartNotebookAlerts.forget(id: folder.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .tint(nil)
        }
    }

    private func setSmartExpanded(_ isOpen: Bool, id: String) {
        if isOpen {
            smartExpanded.insert(id)
            if let folder = model.smartNotebook(id: id) { model.refreshSmartHits(folder) }
        } else {
            smartExpanded.remove(id)
        }
    }

    @ViewBuilder
    private func smartHitRow(_ hit: SearchHit, smartNotebookId: String) -> some View {
        let tag = "smarthit:\(smartNotebookId)\u{1}\(hit.url)"
        searchHitRow(hit)
            .padding(.trailing, sidebarTrailingGutter)
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .tag(tag)
            .id(tag)
            .gesture(PrimaryClickGesture { selectSidebarRow(tag) })
            .onDrag({ SidebarDrag.provider(hit.url, kind: .item) }, preview: {
                DragPreviewView(name: hit.name.isEmpty ? "Untitled" : hit.name)
            })
            .listRowInsets(sidebarRowInsets(depth: 1))
            .listRowBackground(selectionBackground(url: hit.url, tag: tag))
            .contextMenu {
                if let node = model.node(for: hit.url) {
                    singleNoteContextMenu(for: node, showInFolder: true)
                }
            }
    }

    /// Only ever shown while a scope is set, so it doubles as the reminder that
    /// the hit list is not the whole library.
    private func searchScopeRow(_ scope: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 10, weight: .semibold))
            Text(model.node(for: scope)?.displayName ?? "Notebook")
                .lineLimit(1)
            Button {
                searchScope = nil
                runSearch(selectTop: false)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .help("Search everywhere")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Self.selectionTint)
        .padding(.vertical, 4)
        .listRowInsets(sidebarRowInsets(depth: 0))
    }

    private var saveSearchRow: some View {
        Button {
            smartEditor = SmartNotebookEdit(
                folder: newSmartNotebook(query: searchQueryText, scope: searchScope ?? ""),
                isNew: true
            )
        } label: {
            Label("Save as Smart Notebook", systemImage: "folder.badge.gearshape")
                .font(.body.weight(.medium))
                .foregroundStyle(Self.selectionTint)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .listRowInsets(sidebarRowInsets(depth: 0))
    }

    private func newNotebook() {
        Task {
            guard let url = await model.createNotebook() else { return }
            selectedItemUrls = [rowTag(for: url)]
            renameText = "New Notebook"
            renamingUrl = url
        }
    }

    private var sidebarFooterRow: some View {
        HStack(spacing: 14) {
            Button {
                newNotebook()
            } label: {
                Label("Notebook", systemImage: "plus")
            }
            Button {
                smartEditor = SmartNotebookEdit(folder: newSmartNotebook(), isNew: true)
            } label: {
                Label("Smart Notebook", systemImage: "plus")
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .listRowInsets(sidebarRowInsets(depth: 0))
    }

    /// The copy she clicked keeps the real selection; the others draw the
    /// system's unfocused selection, in the same shape the list uses.
    /// Selection is drawn here rather than left to the list: the row she
    /// clicked gets the pink, every other copy of it gets the system's
    /// unfocused grey.
    private func selectionBackground(url: String, tag: String) -> SidebarSelectionRow {
        if selectedItemUrls.contains(tag) {
            return SidebarSelectionRow(state: sidebarFocused ? .clicked : .echo)
        }
        let selectedElsewhere = selectedItemUrls.contains {
            $0 != tag && Self.isRowTag($0) && Self.sidebarUrl($0) == url
        }
        return SidebarSelectionRow(state: selectedElsewhere ? .echo : .none)
    }

    /// A bare url is a selection made before its row existed. It names no row,
    /// so it must not grey the copies either.
    private static func isRowTag(_ tag: String) -> Bool {
        tag.contains("\u{1}") || tag.hasPrefix("pinned:") || tag.hasPrefix("smarthit:")
    }

    nonisolated private static func sidebarUrl(_ tag: String) -> String {
        if tag.hasPrefix("pinned:") { return String(tag.dropFirst(7)) }
        if let sep = tag.lastIndex(of: "\u{1}") { return String(tag[tag.index(after: sep)...]) }
        if tag.hasPrefix("smarthit:") { return String(tag.dropFirst(9)) }
        return tag
    }

    private func isOtherWindowsRoute(_ url: String) -> Bool {
        guard let routed = MainWindowTabs.routedSelection else { return false }
        return routed != initialRoute?.selection && Self.sidebarUrl(routed) == url
    }

    private static let selectionTint = Color(red: 1.0, green: 0.412, blue: 0.647)

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
    private func folderRow(for node: FolderNode, depth: Int, tag: String) -> some View {
        HStack(spacing: 8) {
            if renamingUrl == node.url {
                HStack(spacing: 8) {
                    if depth > 0 {
                        Image(systemName: "folder")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                    InlineRenameField(
                        text: $renameText,
                        font: depth == 0 ? .title3.weight(.medium) : .body.weight(.medium)
                    ) {
                        commitRename(node)
                    }
                }
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
            }
            if model.folderSettings(for: node.url).showCount {
                Text("\(model.folderNoteCount(node))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
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
        .padding(.trailing, sidebarTrailingGutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(PrimaryClickGesture { selectSidebarRow(tag) })
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            setExpanded(!expanded.contains(node.url), for: node.url)
        })
        .onDrag({
            SidebarDrag.provider(
                node.url,
                kind: model.rootFolderUrls.contains(node.url) ? .notebook : .item
            )
        }, preview: {
            DragPreviewView(name: node.displayName, isFolder: true)
        })
        .modifier(
            FolderDropTarget(
                node: node,
                isRoot: model.rootFolderUrls.contains(node.url),
                model: model
            )
        )
        .contextMenu {
            folderContextMenu(for: node)
        }
    }

    private func folderContextMenu(for node: FolderNode) -> some View {
        Group {
            folderContextMenuContent(for: node)
        }
        .tint(nil)
    }

    @ViewBuilder
    private func folderContextMenuContent(for node: FolderNode) -> some View {
        Menu("New") {
            NewItemMenuItems(
                model: model,
                folderUrl: node.url,
                onNewSmartNotebook: { smartEditor = SmartNotebookEdit(folder: newSmartNotebook(), isNew: true) }
            ) { open($0) }
        }
        Divider()
        Button {
            searchInFolder(node.url)
        } label: {
            Label("Search in \(node.displayName)…", systemImage: "magnifyingglass")
        }
        Divider()
        Button {
            folderSettingsTarget = node
        } label: {
            Label("Folder Settings…", systemImage: "gearshape")
        }
        Button {
            beginRename(node)
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        if node.parentUrl != nil {
            Button {
                moveTarget = MoveTarget(urls: [node.url])
            } label: {
                Label("Move…", systemImage: "arrowshape.turn.up.right")
            }
        }
        if !model.rootFolderUrls.contains(node.url) {
            Button {
                Task { await model.addRootFolder(node.url) }
            } label: {
                Label("Add to Notebooks", systemImage: "book.closed")
            }
        }
        Divider()
        CopyUrlMenu(url: node.url)
        Divider()
        if node.parentUrl != nil {
            Button(role: .destructive) {
                model.removeEntry(parentUrl: node.parentUrl, url: node.url)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } else if model.rootFolderUrls.count > 1 {
            Button(role: .destructive) {
                model.removeRootFolder(node.url)
            } label: {
                Label("Remove from Notebooks", systemImage: "trash")
            }
        }
    }

    private func draggedUrls(node: FolderNode, tag: String) -> String {
        let urls = selectedItemUrls.contains(tag)
            ? selectedItemUrls.map(Self.sidebarUrl)
            : [node.url]
        return urls.joined(separator: "\n")
    }

    @ViewBuilder
    private func noteRow(for node: FolderNode, depth: Int = 0, tag: String) -> some View {
        NoteRowView(
            node: node,
            renameText: renamingUrl == node.url ? $renameText : nil,
            commitRename: { commitRename(node) }
        )
            .padding(.trailing, sidebarTrailingGutter)
            .padding(.leading, CGFloat(depth) * 8 + 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .tag(tag)
            .gesture(PrimaryClickGesture { selectSidebarRow(tag) })
            .onDrag({
                SidebarDrag.provider(draggedUrls(node: node, tag: tag), kind: .item)
            }, preview: {
                let count = selectedItemUrls.contains(tag) ? selectedItemUrls.count : 1
                DragPreviewView(name: node.displayName, count: count)
            })
            .modifier(NoteReorderDropTarget(node: node, model: model))
            .contextMenu {
                let targets = selectedItemUrls.contains(tag)
                    ? selectedItemUrls.map(Self.sidebarUrl)
                    : [node.url]
                if targets.count > 1 {
                    Group {
                        Button {
                            moveTarget = MoveTarget(
                                urls: targets.filter { model.node(for: $0)?.parentUrl != nil }
                            )
                        } label: {
                            Label("Move \(targets.count) Items…", systemImage: "arrowshape.turn.up.right")
                        }
                        Divider()
                        Button(role: .destructive) {
                            for url in targets {
                                if let target = model.node(for: url), target.parentUrl != nil {
                                    model.removeEntry(parentUrl: target.parentUrl, url: url)
                                }
                            }
                        } label: {
                            Label("Delete \(targets.count) Items", systemImage: "trash")
                        }
                    }
                    .tint(nil)
                } else {
                    singleNoteContextMenu(for: node)
                }
            }
    }

    private var rightSidebarDivider: some View {
        Color.clear
            .frame(width: 10)
            .overlay {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = rightSidebarDragStart ?? rightSidebarWidth
                        rightSidebarDragStart = start
                        rightSidebarLiveWidth = min(1100, max(240, (start - drag.translation.width).rounded()))
                    }
                    .onEnded { _ in
                        rightSidebarDragStart = nil
                        if let width = rightSidebarLiveWidth { rightSidebarWidth = width }
                        rightSidebarLiveWidth = nil
                    }
            )
    }

    private func documentUrl(in selection: Set<String>) -> String? {
        guard selection.count == 1, let tag = selection.first,
              !tag.hasPrefix("smart:"),
              tag != Agenda.sidebarTag,
              tag != Agenda.meetingNotesTag
        else { return nil }
        let url = Self.sidebarUrl(tag)
        guard url.hasPrefix("automerge:"), model.node(for: url)?.kind != "folder" else { return nil }
        return url
    }

    private var windowTitle: String {
        guard selectedItemUrls.count == 1, let tag = selectedItemUrls.first else { return "Lush" }
        if tag == Agenda.sidebarTag { return "Calendar" }
        if tag == Agenda.meetingNotesTag { return "Meeting Notes" }
        if tag.hasPrefix("smart:") {
            return model.smartNotebook(id: String(tag.dropFirst(6)))?.name ?? "Smart Notebook"
        }
        guard let node = model.node(for: Self.sidebarUrl(tag)) else { return "Lush" }
        return node.displayName
    }

    @ViewBuilder
    private var detail: some View {
        // Not HSplitView: a second pane makes AppKit align the search item to
        // the trailing pane, which inserts a flexible space in front of it and
        // drags the field over into the sidebar.
        HStack(spacing: 0) {
            Group {
                if let edit = smartEditor {
                    SmartNotebookEditor(
                        existing: edit.folder,
                        isNew: edit.isNew,
                        close: { smartEditor = nil }
                    )
                } else if meetingNotesSelected {
                    MeetingNotesScreen { open($0) }
                } else if calendarSelected {
                    AgendaScreen { open($0) }
                } else if let url = selectedDocumentUrl {
                    detailContent(for: url)
                } else {
                    Color.clear
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity)

            if rightSidebarVisible, let url = selectedDocumentUrl {
                rightSidebarDivider
                RightSidebarView(
                    url: url,
                    node: model.node(for: url),
                    selectedTab: $rightSidebarTab,
                    selectedEntry: $selectedHistoryEntry
                )
                .environment(model)
                .frame(width: CGFloat(rightSidebarLiveWidth ?? rightSidebarWidth))
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Menu {
                    NewItemMenuItems(
                        model: model,
                        snap: contextTracker.snapshot,
                        onNewSmartNotebook: { smartEditor = SmartNotebookEdit(folder: newSmartNotebook(), isNew: true) }
                    ) { open($0) }
                } label: {
                    Image(systemName: "square.and.pencil")
                } primaryAction: {
                    Task {
                        contextTracker.start()
                        if let url = await model.createNote(snap: contextTracker.snapshot) { open(url) }
                    }
                }
                .disabled(model.folderUrl == nil)
                Button {
                    moveThroughSidebarHistory(by: -1)
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(sidebarHistoryIndex <= 0)
                if sidebarHistoryIndex >= 0, sidebarHistoryIndex < sidebarHistory.count - 1 {
                    Button {
                        moveThroughSidebarHistory(by: 1)
                    } label: {
                        Label("Forward", systemImage: "chevron.right")
                    }
                }
                FocusModeControl(model: model)
            }
            #if os(macOS)
            ToolbarSpacer(.flexible)
            #endif
        }
        // AppKit pins the field to the trailing end of the toolbar; the
        // inspector button lands before it and that's that.
        .searchable(
            text: $searchText,
            tokens: $searchTokens,
            isPresented: $searchPresented,
            placement: .toolbar,
            prompt: searchScope.flatMap { model.node(for: $0)?.displayName }
                .map { "Search \($0)" } ?? "Search notes"
        ) { token in
            Text(token.label)
                .overlay {
                    DoubleClickCatcher { editSearchToken(token) }
                }
        }
        .searchSuggestions {
            ForEach(SearchSyntax.suggestions(for: searchText)) { suggestion in
                Text(suggestion.label)
                    .searchCompletion(SearchSyntax.completing(suggestion, in: searchText))
            }
        }
        .searchFocused($searchFocused)
        .onSubmit(of: .search) {
            absorbSearchTokens(commitAll: true)
            searchDidChange()
        }
        .onChange(of: searchFocused) { _, focused in
            if !focused { absorbSearchTokens(commitAll: true) }
        }
    }

    private var searchQueryText: String {
        (searchTokens.map(\.raw) + [searchText])
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func setSearchQuery(_ query: String) {
        let syntax = SearchSyntax(query)
        searchTokens = syntax.clauses.map { SearchFieldToken(raw: $0.raw) }
        searchText = syntax.text
    }

    private func absorbSearchTokens(commitAll: Bool = false) {
        let syntax = SearchSyntax(searchText)
        let source = searchText as NSString
        let length = (searchText as NSString).length
        let clauses = syntax.clauses.filter {
            if commitAll { return true }
            let end = NSMaxRange($0.range)
            guard end < length else { return false }
            return source.substring(with: NSRange(location: end, length: 1)) == " "
        }
        guard !clauses.isEmpty else {
            searchDidChange()
            return
        }
        let remaining = NSMutableString(string: searchText)
        for clause in clauses.reversed() {
            remaining.replaceCharacters(in: clause.range, with: "")
        }
        searchTokens += clauses.map { SearchFieldToken(raw: $0.raw) }
        searchText = (remaining as String)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }

    private func editSearchToken(_ token: SearchFieldToken) {
        searchTokens.removeAll { $0.id == token.id }
        preserveSearchInputOnce = true
        searchText = [searchText, token.raw]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        searchFocused = true
    }

    private func searchDidChange() {
        model.searchQuery = searchQueryText
        runSearch()
    }

    @ViewBuilder
    private func detailContent(for url: String) -> some View {
        let node = model.node(for: url)
        let isPatchwork = model.patchworkDocUrls.contains(url)
        // Checked-out drafts redirect the editor to the draft's clone; the
        // sidebar, node and title all keep speaking about the origin url.
        let resolved = model.resolvedNoteUrl(url)
        // One NoteDetail call site: a second one in another branch of this
        // chain is a different view identity, so a new note's editor was torn
        // down and rebuilt the moment the tree caught up and `node` resolved,
        // leaving two EditorCores on one shared text storage.
        let isNoteDetail: Bool = {
            guard !isPatchwork else { return false }
            guard let node else { return url.hasPrefix("automerge:") }
            return node.isNote
        }()
        if isNoteDetail {
            // No .id here: the editor swaps documents through EditorCore.switchTo,
            // which keeps the text view, its layout manager and the asset cache.
            NoteDetail(
                noteUrl: resolved,
                historyVersion: selectedHistoryEntry,
                rightSidebarVisible: $rightSidebarVisible
            )
        } else if node == nil, isPatchwork {
            // Known patchwork doc: open directly, no need to wait for the tree.
            PatchworkDetail(
                docUrl: url,
                historyVersion: selectedHistoryEntry,
                rightSidebarVisible: $rightSidebarVisible
            )
                .id(url)
        } else if node == nil {
            ResolvingDocumentView(url: url)
        } else if node?.kind == "lush:script" {
            ScriptEditorView(url: url)
                .environment(model)
                .id(url)
        } else {
            PatchworkDetail(
                docUrl: url,
                historyVersion: selectedHistoryEntry,
                rightSidebarVisible: $rightSidebarVisible
            )
                .id(url)
        }
    }

    private func beginRename(_ node: FolderNode) {
        renameText = node.name
        renamingUrl = node.url
    }

    private func commitRename(_ node: FolderNode) {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingUrl = nil
        guard !name.isEmpty, name != node.name else { return }
        model.renameNode(node, to: name)
    }

    private func showNoteInFolder(_ node: FolderNode) {
        searchText = ""
        searchTokens = []
        var url: String? = node.parentUrl
        while let u = url {
            expanded.insert(u)
            url = model.node(for: u)?.parentUrl
        }
        UserDefaults.standard.set(Array(expanded), forKey: Self.expandedKey)
        selectedItemUrls = [rowTag(for: node.url)]
        revealTarget = rowTag(for: node.url)
        Task { await model.selectItem(node.url) }
    }

    private func recordSidebarHistory(_ selection: Set<String>) {
        guard selection.count == 1, let tag = selection.first else { return }
        if movingThroughSidebarHistory {
            movingThroughSidebarHistory = false
            return
        }
        let identity: String
        if tag.hasPrefix("smart:") || tag == Agenda.sidebarTag || tag == Agenda.meetingNotesTag {
            identity = tag
        } else {
            identity = Self.sidebarUrl(tag)
        }
        let entry = SidebarHistoryEntry(tag: tag, identity: identity)
        if sidebarHistory.indices.contains(sidebarHistoryIndex),
           sidebarHistory[sidebarHistoryIndex].identity == identity {
            sidebarHistory[sidebarHistoryIndex] = entry
            return
        }
        if sidebarHistoryIndex + 1 < sidebarHistory.count {
            sidebarHistory.removeSubrange((sidebarHistoryIndex + 1)...)
        }
        sidebarHistory.append(entry)
        sidebarHistoryIndex = sidebarHistory.count - 1
    }

    private func moveThroughSidebarHistory(by offset: Int) {
        let index = sidebarHistoryIndex + offset
        guard sidebarHistory.indices.contains(index) else { return }
        sidebarHistoryIndex = index
        let entry = sidebarHistory[index]
        let tag: String
        if visibleSidebarRowTags.contains(entry.tag)
            || entry.tag.hasPrefix("smart:")
            || entry.tag == Agenda.sidebarTag
            || entry.tag == Agenda.meetingNotesTag {
            tag = entry.tag
        } else if entry.identity.hasPrefix("automerge:") {
            tag = rowTag(for: entry.identity)
        } else {
            tag = entry.tag
        }
        movingThroughSidebarHistory = true
        selectedItemUrls = [tag]
        revealTarget = tag
    }

    private func singleNoteContextMenu(for node: FolderNode, showInFolder: Bool = false) -> some View {
        Group {
            Button {
                MainWindowTabs.open(selection: node.url, using: openWindow)
            } label: {
                Label("Open in New Tab", systemImage: "plus.square.on.square")
            }
            NoteContextMenu(
                node: node,
                showInFolder: showInFolder ? { showNoteInFolder(node) } : nil,
                move: { moveTarget = MoveTarget(urls: [node.url]) },
                rename: { beginRename(node) }
            )
        }
        .tint(nil)
    }

    #endif
}

#if os(macOS)
struct SidebarRow: Identifiable {
    let id: String
    let node: FolderNode
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
    /// A search match stands in for the note's own preview line.
    var snippet: AttributedString?
    var renameText: Binding<String>?
    var commitRename: () -> Void = {}
    @Environment(NotesModel.self) private var model

    private var row: NoteRow { model.noteRow(for: node.url) }
    private var meta: NoteContextMeta? { row.contextMeta }

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
                    if let renameText {
                        InlineRenameField(text: renameText, font: .body, commit: commitRename)
                    } else {
                        Text(node.displayName)
                            .font(.body)
                            .lineLimit(1)
                    }
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
                if let snippet {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                } else if !row.preview.isEmpty {
                    Text(row.preview)
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
            if let data = row.thumbnail,
               let thumbnail = thumbnailImage(from: data) {
                thumbnail
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 2)
        .task { await model.loadContextMeta(url: node.url) }
    }
}

/// Renaming edits the row's own label in place: same font, same position, no
/// field chrome. Return commits, Escape restores the old name.
struct InlineRenameField: View {
    @Binding var text: String
    var font: Font = .body
    let commit: () -> Void
    @State private var original = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .labelsHidden()
            .focused($focused)
            .onSubmit { commit() }
            .onEscape {
                text = original
                commit()
            }
            .onAppear {
                original = text
                DispatchQueue.main.async { focused = true }
            }
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

struct FolderSettingsEditor: View {
    let node: FolderNode
    @Environment(NotesModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var showCount = false
    @State private var recursiveCount = false
    @State private var notifyOnChange = false
    @State private var notificationsDenied = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Section {
                    Toggle("Show count", isOn: $showCount)
                    Toggle("Include docs in subfolders in count", isOn: $recursiveCount)
                        .disabled(!showCount && !notifyOnChange)
                    Toggle("Notify when count changes", isOn: $notifyOnChange)
                } footer: {
                    if notificationsDenied {
                        Text("Notifications are turned off for Lush in System Settings.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Folder Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear {
            name = node.name
            let settings = model.folderSettings(for: node.url)
            showCount = settings.showCount
            recursiveCount = settings.recursiveCount
            notifyOnChange = settings.notifyOnChange
        }
        .onChange(of: notifyOnChange) {
            guard notifyOnChange else { return }
            Task { notificationsDenied = await !SmartNotebookAlerts.requestAuthorization() }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 220)
        #endif
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != node.name {
            model.renameNode(node, to: trimmed)
        }
        model.setFolderSettings(FolderSettings(
            url: node.url,
            showCount: showCount,
            recursiveCount: recursiveCount,
            notifyOnChange: notifyOnChange
        ))
        dismiss()
    }
}

func highlighted(_ snippet: String, query: String) -> AttributedString {
    var text = AttributedString(snippet)
    if !query.isEmpty,
       let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
        text[range].font = .caption.bold()
        text[range].foregroundColor = .primary
    }
    return text
}

struct SearchSyntaxPills: View {
    @Binding var text: String

    var body: some View {
        let syntax = SearchSyntax(text)
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(syntax.clauses) { clause in
                    Button {
                        text = syntax.removing(clause, from: text)
                    } label: {
                        HStack(spacing: 5) {
                            Text(clause.label)
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.tint.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

struct SearchSyntaxSuggestions: View {
    @Binding var text: String

    var body: some View {
        let suggestions = SearchSyntax.suggestions(for: text)
        if !suggestions.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(suggestions) { suggestion in
                        Button(suggestion.label) {
                            text = SearchSyntax.completing(suggestion, in: text)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .font(.caption)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
        }
    }
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
    @State private var expandedFolders: Set<String> = []
    @State private var smartEditor: SmartNotebookEdit?
    @State private var folderSettingsTarget: FolderNode?
    @Environment(\.editMode) private var editMode

    private static let pinnedExpandedKey = "pinnedExpanded"

    private var nodes: [FolderNode] {
        if let folderUrl {
            return model.node(for: folderUrl)?.children?.filter {
                !($0.kind == "folder" && model.focus.hides($0.url))
            } ?? []
        }
        return model.visibleFolderTree
    }

    private var title: String {
        guard let folderUrl else { return "" }
        return model.node(for: folderUrl)?.displayName ?? "Folder"
    }

    private var editing: Bool { editMode?.wrappedValue.isEditing == true }

    private struct DisplayedNode: Identifiable {
        let node: FolderNode
        let depth: Int
        var id: String { node.url }
    }

    private var displayedNodes: [DisplayedNode] {
        flattened(nodes, depth: 0)
    }

    private func flattened(_ nodes: [FolderNode], depth: Int) -> [DisplayedNode] {
        nodes.flatMap { node in
            var result = [DisplayedNode(node: node, depth: depth)]
            if node.kind == "folder", expandedFolders.contains(node.url) {
                result += flattened(node.children ?? [], depth: depth + 1)
            }
            return result
        }
    }

    private func route(for node: FolderNode) -> NavRoute {
        node.kind == "folder"
            ? .folder(node.url)
            : node.kind == "lush:script"
                ? .script(node.url)
                : node.isNote
                    ? .note(node.url)
                    : .patchwork(node.url)
    }

    /// Reordering flattens the tree to the level being shown; nesting is what
    /// drilling in is for.
    @ViewBuilder
    private func nodeLabel(_ node: FolderNode) -> some View {
        if node.kind == "folder" {
            HStack {
                Label(node.displayName, systemImage: "folder")
                    .lineLimit(1)
                if model.folderSettings(for: node.url).showCount {
                    Spacer()
                    Text("\(model.folderNoteCount(node))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            NoteRowView(node: node)
        }
    }

    private func moveNodes(from: IndexSet, to: Int) {
        let displayed = nodes.map(\.url)
        if let folderUrl {
            model.moveChildren(in: folderUrl, displayed: displayed, from: from, to: to)
        } else {
            model.moveRootFolders(displayed: displayed, from: from, to: to)
        }
    }

    var body: some View {
        List {
            if searchText.isEmpty, folderUrl == nil {
                Section {
                    Button {
                        push(.calendar)
                    } label: {
                        CalendarSidebarLabel()
                    }
                    .buttonStyle(.plain)
                }
                Section(isExpanded: pinnedExpansionBinding) {
                    Button {
                        push(.recents)
                    } label: {
                        Label("Recents", systemImage: "clock")
                    }
                    .buttonStyle(.plain)
                    ForEach(model.pinnedNodes) { node in
                        Button {
                            push(.note(node.url))
                        } label: {
                            NoteRowView(node: node, showFolder: true)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            nodeMenu(node)
                            if let parentUrl = node.parentUrl {
                                Button {
                                    push(.folder(parentUrl))
                                } label: {
                                    Label("Show in Folder", systemImage: "folder")
                                }
                            }
                        }
                    }
                    .onMove { from, to in
                        model.movePins(displayed: model.pinnedNodes.map(\.url), from: from, to: to)
                    }
                } header: {
                    Text("Pinned")
                }
            }
            if searchText.isEmpty {
                if editing {
                    Section {
                        ForEach(nodes) { node in
                            nodeLabel(node)
                                .moveDisabled(node.kind == "folder" && folderUrl != nil)
                        }
                        .onMove(perform: moveNodes)
                    } header: {
                        if folderUrl == nil { Text("Notebooks") }
                    }
                } else {
                    Section {
                        ForEach(displayedNodes) { displayed in
                            HStack(spacing: 4) {
                                Button {
                                    push(route(for: displayed.node))
                                } label: {
                                    nodeLabel(displayed.node)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if displayed.node.kind == "folder" {
                                    Button {
                                        if expandedFolders.contains(displayed.node.url) {
                                            expandedFolders.remove(displayed.node.url)
                                        } else {
                                            expandedFolders.insert(displayed.node.url)
                                        }
                                    } label: {
                                        Image(systemName: expandedFolders.contains(displayed.node.url)
                                            ? "chevron.down"
                                            : "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 24, height: 32)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.leading, CGFloat(displayed.depth) * 20)
                            .contextMenu { nodeMenu(displayed.node) }
                        }
                    } header: {
                        if folderUrl == nil { Text("Notebooks") }
                    }
                }
                if folderUrl == nil, !model.smartNotebooks.isEmpty {
                    Section {
                        ForEach(model.smartNotebooks) { folder in
                            Button {
                                push(.smart(folder.id))
                            } label: {
                                HStack {
                                    Label(folder.displayName, systemImage: "folder.badge.gearshape")
                                        .lineLimit(1)
                                    if folder.showCount, let count = model.smartHits[folder.id]?.count {
                                        Spacer()
                                        Text("\(count)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Group {
                                    Button {
                                        smartEditor = SmartNotebookEdit(folder: folder)
                                    } label: {
                                        Label("Edit Smart Notebook…", systemImage: "gearshape")
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        model.removeSmartNotebook(id: folder.id)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .tint(nil)
                            }
                        }
                        .onMove { from, to in
                            model.moveSmartNotebooks(from: from, to: to)
                        }
                    } header: {
                        Text("Smart Notebooks")
                    }
                }
            } else {
                Section {
                    if !SearchSyntax(searchText).clauses.isEmpty {
                        SearchSyntaxPills(text: $searchText)
                    }
                    Button {
                        smartEditor = SmartNotebookEdit(
                            folder: newSmartNotebook(query: searchText, scope: folderUrl ?? ""),
                            isNew: true
                        )
                    } label: {
                        Label("Save as Smart Notebook", systemImage: "folder.badge.gearshape")
                    }
                }
                ForEach(searchHits, id: \.url) { hit in
                    Button {
                        push(.note(hit.url))
                    } label: {
                        if let node = model.node(for: hit.url) {
                            NoteRowView(node: node)
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.name.isEmpty ? "Untitled" : hit.name)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text(highlighted(hit.snippet, query: SearchSyntax(searchText).text))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if let node = model.node(for: hit.url) {
                            nodeMenu(node)
                            if let parentUrl = node.parentUrl {
                                Button {
                                    push(.folder(parentUrl))
                                } label: {
                                    Label("Show in Folder", systemImage: "folder")
                                }
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
            let query = searchText
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                let hits = await model.search(query, in: folderUrl)
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
            } else {
                model.refreshSmartHits()
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
                if !model.focusModeEnabled {
                    ToolbarItem(placement: .topBarTrailing) {
                        FocusModeControl(model: model)
                    }
                }
            }
            ToolbarItem {
                EditButton()
            }
            ToolbarItemGroup {
                Button {
                    model.undoManager.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.undoManager.canUndo)
                Button {
                    model.undoManager.redo()
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!model.undoManager.canRedo)
            }
            ToolbarItem {
                Menu {
                    NewItemMenuItems(
                        model: model,
                        folderUrl: folderUrl,
                        onNewSmartNotebook: { smartEditor = SmartNotebookEdit(folder: newSmartNotebook(), isNew: true) }
                    ) { push(.note($0)) }
                } label: {
                    Label("New", systemImage: "square.and.pencil")
                }
                .disabled(model.folderUrl == nil)
            }
        }
        .sheet(item: $smartEditor) { edit in
            SmartNotebookEditor(existing: edit.folder, isNew: edit.isNew)
                .environment(model)
        }
        .sheet(item: $folderSettingsTarget) { node in
            FolderSettingsEditor(node: node)
                .environment(model)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                SearchSyntaxSuggestions(text: $searchText)
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 15))
                    TextField(folderUrl == nil ? "Search notes" : "Search \(title)", text: $searchText)
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
                            contextTracker.start()
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
                        contextTracker.start()
                        if let url = await model.createNote(snap: contextTracker.snapshot) {
                            push(.note(url))
                        }
                    }
                }
                    .accessibilityLabel("New")
                    .disabled(model.folderUrl == nil)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
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
                        model.renameNode(node, to: name)
                    }
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    private func nodeMenu(_ node: FolderNode) -> some View {
        Group {
            nodeMenuContent(node)
        }
        .tint(nil)
    }

    @ViewBuilder
    private func nodeMenuContent(_ node: FolderNode) -> some View {
        if node.kind == "folder" {
            Menu("New") {
                NewItemMenuItems(
                    model: model,
                    folderUrl: node.url,
                    onNewSmartNotebook: { smartEditor = SmartNotebookEdit(folder: newSmartNotebook(), isNew: true) }
                ) { push(.note($0)) }
            }
            Divider()
            Button {
                folderSettingsTarget = node
            } label: {
                Label("Folder Settings…", systemImage: "gearshape")
            }
            Button {
                renameText = node.name
                renameTarget = node
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            if node.parentUrl != nil {
                Button {
                    moveTarget = MoveTarget(urls: [node.url])
                } label: {
                    Label("Move…", systemImage: "arrowshape.turn.up.right")
                }
            }
            if !model.rootFolderUrls.contains(node.url) {
                Button {
                    Task { await model.addRootFolder(node.url) }
                } label: {
                    Label("Add to Notebooks", systemImage: "book.closed")
                }
            }
            Divider()
            CopyUrlMenu(url: node.url)
            if model.patchworkDocUrls.contains(node.url) || node.isPatchworkDoc {
                Button {
                    model.openInPatchwork(node.url)
                } label: {
                    OpenInPatchworkLabel()
                }
            }
            Divider()
            if node.parentUrl != nil {
                Button(role: .destructive) {
                    model.removeEntry(parentUrl: node.parentUrl, url: node.url)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } else if model.rootFolderUrls.count > 1 {
                Button(role: .destructive) {
                    model.removeRootFolder(node.url)
                } label: {
                    Label("Remove from Notebooks", systemImage: "trash")
                }
            }
        } else {
            NoteContextMenu(
                node: node,
                move: { moveTarget = MoveTarget(urls: [node.url]) },
                rename: {
                    renameText = node.name
                    renameTarget = node
                }
            )
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

struct SmartNotebookScreen: View {
    let smartNotebookId: String
    let push: (NavRoute) -> Void
    @Environment(NotesModel.self) private var model
    @State private var hits: [SearchHit] = []
    @State private var editing = false

    private var folder: SmartNotebook? { model.smartNotebook(id: smartNotebookId) }

    var body: some View {
        Group {
            if editing, let folder {
                SmartNotebookEditor(existing: folder, close: { editing = false })
            } else {
                list
            }
        }
        .navigationTitle(folder?.displayName ?? "Smart Notebook")
        .toolbar {
            if !editing {
                Button("Edit") { editing = true }
                    .disabled(folder == nil)
            }
        }
        .task(id: folder) { await refresh() }
        .onChange(of: model.notes) { Task { await refresh() } }
    }

    private var list: some View {
        List(hits, id: \.url) { hit in
            NavigationLink(value: NavRoute.note(hit.url)) {
                if let node = model.node(for: hit.url) {
                    NoteRowView(node: node, showFolder: true)
                } else {
                    Text(hit.name.isEmpty ? "Untitled" : hit.name)
                }
            }
        }
        .overlay {
            if hits.isEmpty {
                ContentUnavailableView("Nothing Matches", systemImage: "folder.badge.gearshape")
            }
        }
    }

    private func refresh() async {
        guard let folder else { return }
        hits = await model.smartNotebookHits(folder)
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
                NoteContextMenu(
                    node: entry.node,
                    showInFolder: entry.node.parentUrl.map { url in { push(.folder(url)) } },
                    move: { moveTarget = MoveTarget(urls: [entry.node.url]) },
                    rename: {
                        renameText = entry.node.name
                        renameTarget = entry.node
                    }
                )
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
                        model.renameNode(node, to: name)
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
    case pad = "Scratchpad"
    case history = "History"
    case info = "Info"
    case chat = "Chat"
    case tools = "Tools"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .outline: "list.bullet.indent"
        case .pad: "scribble.variable"
        case .history: "clock.arrow.circlepath"
        case .info: "info.circle"
        case .chat: "bubble.left"
        case .tools: "puzzlepiece.extension"
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

private enum InspectorMetrics {
    #if os(macOS)
    static let badgeSize: CGFloat = 10
    static let chevronSize: CGFloat = 11
    static let changeRowHeight: CGFloat = 30
    #else
    static let badgeSize: CGFloat = 12
    static let chevronSize: CGFloat = 15
    static let changeRowHeight: CGFloat = 38
    #endif
}

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
            // a controller outlives its editor — the focused scene value holds
            // the last one — so the live core, not the controller, is the test
            case .outline: model.activeEditor?.core != nil
            case .pad: true
            case .history, .info, .chat: node != nil
            case .tools: node != nil && PatchworkWeb.available
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
                .onChange(of: availableTabs) {
                    if !availableTabs.contains(selectedTab) {
                        selectedTab = availableTabs.first ?? .info
                    }
                }

            Divider()

            switch selectedTab {
            case .outline:
                OutlineListView(controller: model.activeEditor)
            case .pad:
                ScratchpadView(controller: model.activeEditor, noteUrl: model.activeEditor?.core?.noteUrl)
                    .environment(model)
            case .history:
                historyView
            case .info:
                infoView
            case .chat:
                NoteChatView(url: model.resolvedNoteUrl(url), node: node)
            case .tools:
                ContextToolsView(url: url)
            }
        }
        .background(.regularMaterial)
        .task(id: url) {
            selectedEntry = nil
            await refreshHistory()
        }
        .onChange(of: model.noteRow(for: url).preview) {
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

    private var tabBar: some View {
        #if os(iOS)
        HStack(spacing: 6) {
            ForEach(availableTabs) { tab in
                let isActive = selectedTab == tab
                Button {
                    selectedTab = tab
                } label: {
                    Image(systemName: tab.icon)
                        .font(.system(size: 20, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .background(
                            isActive ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.rawValue)
                .accessibilityValue(isActive ? "Selected" : "Not selected")
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        #else
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
        #endif
    }

    private var historyView: some View {
        let checkedOut = model.checkedOutDrafts[url]
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if !history.pendingEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("Future", systemImage: "clock.badge")
                                .uiFont(.body, weight: .semibold)
                            Spacer()
                            Text("\(history.pendingChangeCount) \(history.pendingChangeCount == 1 ? "change" : "changes")")
                                .uiFont(.caption)
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
        DocumentInfoView(url: url, node: node, history: history)
    }

    private func scheduleHistoryRefresh(delay: Duration = .milliseconds(650)) {
        guard selectedTab == .history || selectedTab == .info else { return }
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
                                .uiFont(.body, weight: .semibold)
                            Spacer()
                            if isCheckedOut {
                                Text("checked out")
                                    .font(.system(size: InspectorMetrics.badgeSize, weight: .medium, design: .monospaced))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.tint.opacity(0.16), in: Capsule())
                            }
                        }
                        Text(draft.cloneUrl == nil ? "No changes yet" : "\(entries.count) changes")
                            .uiFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear Search")

                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: InspectorMetrics.chevronSize, weight: .semibold))
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
                            .uiFont(.body, weight: .semibold)
                        Spacer()
                        Text("live")
                            .font(.system(size: InspectorMetrics.badgeSize, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.16), in: Capsule())
                    }
                    HStack(spacing: 8) {
                        Text("\(changeCount) changes")
                        if let modified {
                            Text("Changed \(modified, style: .relative)")
                        }
                    }
                    .uiFont(.caption)
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
                        .font(.system(size: InspectorMetrics.chevronSize, weight: .semibold))
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

    private static let rowHeight: CGFloat = InspectorMetrics.changeRowHeight
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
                .uiFont(.caption)
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
            .uiFont(.caption)
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

extension String {
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

    #if os(macOS)
    private var attachMenu: some View {
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
                editor.startLiveTranscription()
            } label: {
                Label("Live Transcription", systemImage: "mic.fill")
            }
            .disabled(editor.liveTranscriptionActive)
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
        .menuIndicator(.hidden)
        .fixedSize()
    }
    #endif

    @ToolbarContentBuilder
    private var noteToolbar: some ToolbarContent {
        #if os(macOS)
        ToolbarSpacer(.fixed)
        ToolbarItem {
            HStack(spacing: 2) {
                FormatMenuButton(controller: editor)
                attachMenu
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            PresenceFacesView(presence: model.presence)
        }
        ToolbarSpacer(.flexible)
        #endif
        ToolbarItem {
            #if os(macOS)
            HStack(spacing: 2) {
                moreMenu
                Button {
                    rightSidebarVisible?.wrappedValue.toggle()
                } label: {
                    Label("Inspector", systemImage: "info.circle")
                        .foregroundStyle(rightSidebarVisible?.wrappedValue == true ? Color.accentColor : Color.primary)
                }
                .disabled(rightSidebarVisible == nil)
            }
            #else
            moreMenu
            #endif
        }
        #if !os(macOS)
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if editor.undoManager?.canUndo == true {
                    editor.undo()
                } else {
                    model.undoManager.undo()
                }
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(editor.undoManager?.canUndo != true && !model.undoManager.canUndo)
            Button {
                if editor.undoManager?.canRedo == true {
                    editor.redo()
                } else {
                    model.undoManager.redo()
                }
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(editor.undoManager?.canRedo != true && !model.undoManager.canRedo)
        }
        if !model.focusModeEnabled {
            ToolbarItem(placement: .primaryAction) {
                FocusModeControl(model: model)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingInspector = true
            } label: {
                Label("Info", systemImage: "info.circle")
            }
        }
        #endif
    }

    private var moreMenu: some View {
        Menu {
            moreMenuContent
                .tint(nil)
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .disabled(currentNode == nil)
    }

    @ViewBuilder
    private var moreMenuContent: some View {
        Group {
            if let node = currentNode {
                if node.kind == "lush" || node.kind == "rich" {
                    Button {
                        model.togglePin(noteUrl)
                    } label: {
                        Label(
                            model.isPinned(noteUrl) ? "Unpin" : "Pin",
                            systemImage: model.isPinned(noteUrl) ? "pin.slash" : "pin"
                        )
                    }
                    Button {
                        model.setQuickNote(model.quickNoteUrl == noteUrl ? nil : noteUrl)
                    } label: {
                        Label(
                            model.quickNoteUrl == noteUrl ? "Unset Quick Note" : "Set as Quick Note",
                            systemImage: "bolt"
                        )
                    }
                    Divider()
                }
                Button {
                    renameText = node.name
                    showingRename = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                if node.parentUrl != nil {
                    Button {
                        moveTarget = MoveTarget(urls: [noteUrl])
                    } label: {
                        Label("Move…", systemImage: "arrowshape.turn.up.right")
                    }
                }
                Divider()
                CopyUrlMenu(url: noteUrl)
                if node.isNote || node.isPatchworkDoc || model.patchworkDocUrls.contains(noteUrl) {
                    Button {
                        model.openInPatchwork(noteUrl)
                    } label: {
                        OpenInPatchworkLabel()
                    }
                }
                #if os(macOS)
                Menu {
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
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                #endif
                if node.parentUrl != nil {
                    Divider()
                    Button(role: .destructive) {
                        model.removeEntry(parentUrl: node.parentUrl, url: noteUrl)
                        #if os(macOS)
                        model.selectedNoteUrl = nil
                        #else
                        dismiss()
                        #endif
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
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
            if editor.findVisible, historyVersion == nil {
                FindBar(controller: editor)
            }
            if editor.recorderVisible, historyVersion == nil {
                RecorderBar(
                    recorder: recorder,
                    recoveryKey: "note:\(model.accountConfigUrl ?? "local"):\(noteUrl)",
                    prepareSave: {
                        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
                        return RecordingSaveState(
                            assetUrl: nil,
                            name: "Recording \(stamp).m4a",
                            noteUrl: noteUrl,
                            accountUrl: model.accountConfigUrl,
                            embedded: false
                        )
                    },
                    onSave: { data, state in
                        await editor.insertRecording(
                            data: data,
                            name: state?.name ?? "Recording.m4a",
                            state: state
                        )
                    },
                    onSaved: {
                        editor.recorderVisible = false
                    },
                    onCancel: {
                        editor.recorderVisible = false
                    }
                )
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
        .overlay(alignment: .trailing) { minimapOverlay }
        .overlay(alignment: .topLeading) { draftBadge }
        .onChange(of: model.searchQuery) {
            editor.core?.updateGlobalMatches()
        }
        .onChange(of: editor.padded) {
            guard editor.padded > 0 else { return }
            #if os(macOS)
            rightSidebarVisible?.wrappedValue = true
            #else
            inspectorTab = .pad
            showingInspector = true
            #endif
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

    #if os(iOS)
    private var formatHeight: CGFloat { editor.isCodeBlockActive ? 316 : 264 }

    @ViewBuilder
    private var formatIsland: some View {
        if editor.formatVisible {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("Format").uiFont(.headline)
                    Spacer()
                    Button {
                        editor.formatVisible = false
                        editor.resumeKeyboard()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .uiFont(.title3)
                            .foregroundStyle(Color.secondary, Color(.systemFill))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close Format")
                }
                .padding(.leading, 18)
                .padding(.trailing, 4)
                .frame(height: 52)

                Divider()
                FormatPanel(controller: editor).padding(.top, 14)
            }
            .frame(maxWidth: 440)
            .frame(height: formatHeight)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(12)
            .onAppear {
                if let textView = editor.core?.view as? EditorTextView {
                    textView.scrollSelectionAboveSheet(height: formatHeight + 24)
                }
            }
        }
    }
    #endif

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
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .interactiveDismissDisabled(model.pads.drawing)
        }
        .overlay(alignment: .bottom) { formatIsland }
        .onChange(of: editor.formatVisible) { _, visible in
            if visible { showingInspector = false }
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
}

private struct FocusModeControl: View {
    @Bindable var model: NotesModel
    @State private var showingOptions = false

    private var engaged: Bool {
        model.focusModeEnabled || !model.applyingIncomingChanges || !model.sendingChanges || !model.sharingPresence
    }

    var body: some View {
        HStack(spacing: 2) {
            Button {
                model.setFocusMode(!model.focusModeEnabled)
            } label: {
                Label {
                    Text("Moon Mode")
                } icon: {
                    if model.focusModeEnabled {
                        Image(systemName: "moon.fill")
                            .foregroundStyle(Color.purple)
                    } else {
                        Image(systemName: "moon")
                            .overlay {
                                if engaged {
                                    Image(systemName: "moon.fill")
                                        .foregroundStyle(Color.purple)
                                        .mask(alignment: .leading) {
                                            Rectangle().scaleEffect(x: 0.5, anchor: .leading)
                                        }
                                }
                            }
                    }
                }
                .overlay {
                    if engaged {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.purple.opacity(0.6), lineWidth: 1)
                            .padding(-4)
                    }
                }
            }
            .disabled(model.changingIncomingChanges || model.changingSendingChanges)
            .help(model.focusModeEnabled ? "Leave Moon Mode" : "Enter Moon Mode")
            Button {
                showingOptions = true
            } label: {
                Label("Moon Mode Options", systemImage: "chevron.down")
                    .imageScale(.small)
            }
            .help("Moon Mode Options")
            .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
                FocusModeOptions(model: model)
            }
        }
    }
}

private struct FocusModeOptions: View {
    @Bindable var model: NotesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
        .toggleStyle(.switch)
        .padding(10)
        .frame(width: 220)
        #if os(iOS)
        .presentationCompactAdaptation(.popover)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct FindBar: View {
    @Bindable var controller: EditorController
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    controller.replaceVisible.toggle()
                } label: {
                    Image(systemName: controller.replaceVisible ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                field
                HStack(spacing: 0) {
                    step("chevron.left") { controller.findPrevious() }
                    Divider().frame(height: 14)
                    step("chevron.right") { controller.findNext() }
                }
                .background(Color.primary.opacity(0.06), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2)))
                Button("Done") { controller.closeFind() }
            }
            if controller.replaceVisible {
                HStack(spacing: 8) {
                    TextField("Replace with", text: $controller.replaceQuery)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2)))
                        .onSubmit { controller.replaceCurrent() }
                    Button("Replace") { controller.replaceCurrent() }
                        .disabled(controller.findMatchCount == 0)
                    Button("All") { controller.replaceAll() }
                        .disabled(controller.findMatchCount == 0)
                }
                .padding(.leading, 28)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onEscape { controller.closeFind() }
        .onAppear { focused = true }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Find in note", text: $controller.findQuery)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { controller.findNext() }
                .onChange(of: controller.findQuery) { controller.findQueryChanged() }
            if !controller.findQuery.isEmpty {
                Text(controller.findMatchCount == 0 ? "0" : "\(controller.findIndex)/\(controller.findMatchCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    controller.findQuery = ""
                    controller.findQueryChanged()
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2)))
    }

    private func step(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 30, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(controller.findMatchCount == 0)
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

enum SidebarSection: String, CaseIterable, Hashable {
    case calendar
    case pinned
    case smart
    case notebooks

    private static let orderKey = "sidebarSectionOrder"

    var title: String {
        switch self {
        case .calendar: "Calendar"
        case .pinned: "Pinned"
        case .smart: "Smart Notebooks"
        case .notebooks: "Notebooks"
        }
    }

    static func load() -> [SidebarSection] {
        let saved = (UserDefaults.standard.stringArray(forKey: orderKey) ?? [])
            .compactMap(SidebarSection.init(rawValue:))
        return saved + allCases.filter { !saved.contains($0) }
    }

    static func save(_ order: [SidebarSection]) {
        UserDefaults.standard.set(order.map(\.rawValue), forKey: orderKey)
    }
}

/// Every sidebar drag travels as plain text so it can also be dropped into the
/// editor or another app. What is being dragged is remembered here instead, so
/// a row only lights up for the drags it can actually accept.
/// The sidebar draws its own selection. Rows always hand the list a
/// background, so the list never paints its highlight over the top.
struct SidebarSelectionRow: View {
    enum State { case clicked, echo, none }

    let state: State
    @Environment(\.colorScheme) private var scheme

    private var fill: Color {
        switch state {
        case .clicked: Color.accentColor.opacity(scheme == .dark ? 0.40 : 0.28)
        case .echo: Color.secondary.opacity(scheme == .dark ? 0.24 : 0.16)
        case .none: .clear
        }
    }

    var body: some View {
        Rectangle().fill(fill)
    }
}

enum SidebarDragKind {
    case section
    case smart
    case notebook
    case item
}

@MainActor
enum SidebarDrag {
    static var kind: SidebarDragKind?
    static var payload: String?

    static func provider(_ payload: String, kind: SidebarDragKind) -> NSItemProvider {
        Self.kind = kind
        Self.payload = payload
        SidebarDropHighlight.shared.clear()
        return NSItemProvider(object: payload as NSString)
    }

    static func ended() {
        kind = nil
        payload = nil
        SidebarDropHighlight.shared.dropCompleted()
    }
}

enum DropMark: Equatable {
    case into
    case before
    case after
}

/// One mark for the whole sidebar. Rows that miss their `dropExited` cannot
/// leave a stale line behind, since only the row named here draws anything.
@Observable
@MainActor
final class SidebarDropHighlight {
    static let shared = SidebarDropHighlight()

    private var row: String?
    private var mark: DropMark?
    private var sweep: Task<Void, Never>?
    private var suppressUntil: ContinuousClock.Instant = .now

    func show(_ row: String, _ mark: DropMark) {
        guard ContinuousClock.now >= suppressUntil else { return }
        self.row = row
        self.mark = mark
        armSweep(after: .seconds(4))
    }

    func clear(_ row: String? = nil) {
        guard row == nil || row == self.row else { return }
        self.row = nil
        self.mark = nil
        sweep?.cancel()
        sweep = nil
    }

    func dropCompleted() {
        clear()
        suppressUntil = .now + .milliseconds(300)
        armSweep(after: .milliseconds(250))
    }

    private func armSweep(after delay: Duration) {
        sweep?.cancel()
        sweep = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            row = nil
            mark = nil
            sweep = nil
        }
    }

    func mark(for row: String) -> DropMark? {
        self.row == row ? mark : nil
    }
}

/// Draws the insertion line on whichever half of the row the drag is over and
/// reports where it landed.
private struct SidebarReorderTarget: ViewModifier {
    let row: String
    let kind: SidebarDragKind
    var pinnedMark: DropMark?
    var movesLive = true
    var liveHandle: (@MainActor @Sendable (String, Bool) -> Void)?
    var fileHandle: (@MainActor @Sendable ([URL], Bool) -> Void)?
    let handle: @MainActor @Sendable (String, Bool) -> Void

    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        let marked = SidebarDropHighlight.shared.mark(for: row) != nil
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { height = $0 })
            .background {
                if marked {
                    Rectangle().fill(Color.accentColor.opacity(0.18))
                }
            }
            .onDrop(
                of: fileHandle == nil
                    ? [UTType.plainText.identifier]
                    : [UTType.plainText.identifier, UTType.fileURL.identifier],
                delegate: SidebarReorderDrop(
                    row: row,
                    kind: kind,
                    pinnedMark: pinnedMark,
                    height: height,
                    movesLive: movesLive,
                    hasLiveHandle: liveHandle != nil,
                    liveHandle: { payload, after in
                        liveHandle?(payload, after)
                    },
                    hasFileHandle: fileHandle != nil,
                    fileHandle: { urls, after in fileHandle?(urls, after) },
                    handle: { payload, after in handle(payload, after) }
                )
            )
            .onDisappear { SidebarDropHighlight.shared.clear(row) }
    }
}

private struct SidebarReorderDrop: DropDelegate {
    let row: String
    let kind: SidebarDragKind
    let pinnedMark: DropMark?
    let height: CGFloat
    let movesLive: Bool
    let hasLiveHandle: Bool
    let liveHandle: @MainActor @Sendable (String, Bool) -> Void
    let hasFileHandle: Bool
    let fileHandle: @MainActor @Sendable ([URL], Bool) -> Void
    let handle: @MainActor @Sendable (String, Bool) -> Void

    private func landing(_ info: DropInfo) -> DropMark {
        pinnedMark ?? (info.location.y > height / 2 ? .after : .before)
    }

    private func isFileDrop(_ info: DropInfo) -> Bool {
        hasFileHandle && info.hasItemsConforming(to: [UTType.fileURL.identifier])
    }

    private func moveLive(_ info: DropInfo) {
        guard movesLive, let payload = SidebarDrag.payload else { return }
        withAnimation(.snappy(duration: 0.16)) {
            if hasLiveHandle {
                liveHandle(payload, landing(info) == .after)
            } else {
                handle(payload, landing(info) == .after)
            }
        }
    }

    func validateDrop(info: DropInfo) -> Bool {
        if isFileDrop(info) { return true }
        return SidebarDrag.kind == kind && info.hasItemsConforming(to: [UTType.plainText.identifier])
    }

    func dropEntered(info: DropInfo) {
        SidebarDropHighlight.shared.show(row, landing(info))
        moveLive(info)
    }

    func dropExited(info: DropInfo) {
        SidebarDropHighlight.shared.clear(row)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else {
            SidebarDropHighlight.shared.clear(row)
            return DropProposal(operation: .forbidden)
        }
        let landed = landing(info)
        let previous = SidebarDropHighlight.shared.mark(for: row)
        SidebarDropHighlight.shared.show(row, landed)
        if previous != landed { moveLive(info) }
        return DropProposal(operation: isFileDrop(info) ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let after = landing(info) == .after
        if isFileDrop(info) {
            SidebarDropHighlight.shared.dropCompleted()
            let fileHandle = fileHandle
            loadFileURLs(info.itemProviders(for: [UTType.fileURL.identifier])) { fileHandle($0, after) }
            return true
        }
        SidebarDrag.ended()
        guard let provider = info.itemProviders(for: [UTType.plainText.identifier]).first else {
            return false
        }
        loadPayload(provider) { payload in
            handle(payload, after)
            SidebarDropHighlight.shared.clear()
        }
        return true
    }
}

struct SidebarDropCleanup: DropDelegate {
    let folderUrl: String?
    let model: NotesModel

    func validateDrop(info: DropInfo) -> Bool {
        SidebarDrag.kind != nil || info.hasItemsConforming(to: [UTType.fileURL.identifier])
    }
    func dropEntered(info: DropInfo) {}
    func dropExited(info: DropInfo) { SidebarDropHighlight.shared.clear() }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        if info.hasItemsConforming(to: [UTType.fileURL.identifier]) {
            return DropProposal(operation: .copy)
        }
        guard SidebarDrag.kind != nil else {
            SidebarDropHighlight.shared.clear()
            return DropProposal(operation: .forbidden)
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [UTType.fileURL.identifier])
        if !providers.isEmpty {
            SidebarDropHighlight.shared.dropCompleted()
            loadFileURLs(providers) { model.prepareFileImport($0, into: folderUrl) }
            return true
        }
        SidebarDrag.ended()
        return false
    }
}

/// Sections are dragged by their heading row and land above whichever heading
/// they are dropped on; the tail row past the last section is what puts one
/// at the bottom.
private struct SectionDragReorder: ViewModifier {
    let section: SidebarSection
    @Binding var order: [SidebarSection]

    func body(content: Content) -> some View {
        content
            .onDrag({ SidebarDrag.provider(section.rawValue, kind: .section) }, preview: {
                DragPreviewView(name: section.title, isFolder: true)
            })
            .modifier(
                SidebarReorderTarget(
                    row: "section:\(section.rawValue)",
                    kind: .section,
                    pinnedMark: .before
                ) { payload, _ in
                    guard let dragged = SidebarSection(rawValue: payload), dragged != section else { return }
                    order = reordered(order, moving: dragged, adjacentTo: section, after: false)
                    SidebarSection.save(order)
                }
            )
    }
}

private struct SectionTailDrop: ViewModifier {
    @Binding var order: [SidebarSection]
    let model: NotesModel

    func body(content: Content) -> some View {
        content.modifier(
            SidebarReorderTarget(
                row: "section:tail",
                kind: .section,
                pinnedMark: .before,
                fileHandle: { urls, _ in model.prepareFileImport(urls, into: model.folderUrl) }
            ) { payload, _ in
                guard let dragged = SidebarSection(rawValue: payload), order.last != dragged else { return }
                var next = order
                next.removeAll { $0 == dragged }
                next.append(dragged)
                order = next
                SidebarSection.save(next)
            }
        )
    }
}

private struct SmartReorderTarget: ViewModifier {
    let id: String
    let model: NotesModel

    func body(content: Content) -> some View {
        content.modifier(
            SidebarReorderTarget(row: "smart:\(id)", kind: .smart) { payload, after in
                model.reorderSmartNotebook(id: payload, adjacentTo: id, after: after)
            }
        )
    }
}

private struct PinReorderTarget: ViewModifier {
    let url: String
    let model: NotesModel

    func body(content: Content) -> some View {
        content.modifier(
            SidebarReorderTarget(row: "pin:\(url)", kind: .item) { payload, after in
                guard let dragged = payload.components(separatedBy: "\n").first,
                      model.isPinned(dragged)
                else { return }
                model.reorderPin(dragged, adjacentTo: url, after: after)
            }
        )
    }
}

/// A notebook takes notes and folders *into* it, but another root notebook
/// lands beside it instead — the highlight says which is about to happen.
private struct FolderDropTarget: ViewModifier {
    let node: FolderNode
    let isRoot: Bool
    let model: NotesModel
    @State private var height: CGFloat = 0

    private var row: String { "folder:\(node.url)" }

    func body(content: Content) -> some View {
        if node.kind == "folder" {
            let marked = SidebarDropHighlight.shared.mark(for: row) != nil
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { height = $0 })
                .background {
                    if marked {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.18))
                            .overlay(
                                Rectangle()
                                    .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1.5)
                            )
                    }
                }
                .onDrop(
                    of: [UTType.plainText.identifier, UTType.fileURL.identifier],
                    delegate: FolderDrop(
                        row: row,
                        node: node,
                        isRoot: isRoot,
                        model: model,
                        height: height
                    )
                )
                .onDisappear { SidebarDropHighlight.shared.clear(row) }
        } else {
            content
        }
    }
}

private struct FolderDrop: DropDelegate {
    let row: String
    let node: FolderNode
    let isRoot: Bool
    let model: NotesModel
    let height: CGFloat

    private func landing(_ info: DropInfo) -> DropMark {
        guard isRoot, SidebarDrag.kind == .notebook else { return .into }
        return info.location.y > height / 2 ? .after : .before
    }

    func validateDrop(info: DropInfo) -> Bool {
        if info.hasItemsConforming(to: [UTType.fileURL.identifier]) { return true }
        return (SidebarDrag.kind == .notebook || SidebarDrag.kind == .item)
            && info.hasItemsConforming(to: [UTType.plainText.identifier])
    }

    func dropEntered(info: DropInfo) {
        let landed = landing(info)
        SidebarDropHighlight.shared.show(row, landed)
        if landed != .into, let payload = SidebarDrag.payload {
            withAnimation(.snappy(duration: 0.16)) {
                model.reorderRootFolder(payload, adjacentTo: node.url, after: landed == .after)
            }
        }
    }

    func dropExited(info: DropInfo) {
        SidebarDropHighlight.shared.clear(row)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else {
            SidebarDropHighlight.shared.clear(row)
            return DropProposal(operation: .forbidden)
        }
        let landed = landing(info)
        let previous = SidebarDropHighlight.shared.mark(for: row)
        SidebarDropHighlight.shared.show(row, landed)
        if landed != .into, previous != landed, let payload = SidebarDrag.payload {
            withAnimation(.snappy(duration: 0.16)) {
                model.reorderRootFolder(payload, adjacentTo: node.url, after: landed == .after)
            }
        }
        return DropProposal(operation: info.hasItemsConforming(to: [UTType.fileURL.identifier]) ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [UTType.fileURL.identifier])
        if !providers.isEmpty {
            SidebarDropHighlight.shared.dropCompleted()
            loadFileURLs(providers) { model.prepareFileImport($0, into: node.url) }
            return true
        }
        let landed = landing(info)
        SidebarDrag.ended()
        guard let provider = info.itemProviders(for: [UTType.plainText.identifier]).first else {
            return false
        }
        loadPayload(provider) { payload in
            if landed != .into {
                model.reorderRootFolder(payload, adjacentTo: node.url, after: landed == .after)
                SidebarDropHighlight.shared.clear()
                return
            }
            for url in payload.components(separatedBy: "\n") where url.hasPrefix("automerge:") {
                model.moveItem(url, into: node.url)
            }
            SidebarDropHighlight.shared.clear()
        }
        return true
    }
}

private struct NoteReorderDropTarget: ViewModifier {
    let node: FolderNode
    let model: NotesModel

    func body(content: Content) -> some View {
        content.modifier(
            SidebarReorderTarget(
                row: "note:\(node.url)",
                kind: .item,
                liveHandle: { payload, after in
                    for url in payload.components(separatedBy: "\n")
                    where model.node(for: url)?.parentUrl == node.parentUrl {
                        model.reorderChild(url, adjacentTo: node.url, after: after)
                    }
                },
                fileHandle: { urls, after in
                    let folderUrl = node.parentUrl
                    importDroppedFiles(urls, model: model, into: folderUrl) { imported in
                        guard let folderUrl else { return }
                        placeImported(imported, model: model, in: folderUrl, adjacentTo: node.url, after: after)
                    }
                }
            ) { payload, after in
                for url in payload.components(separatedBy: "\n") where url.hasPrefix("automerge:") {
                    if model.node(for: url)?.parentUrl == node.parentUrl {
                        model.reorderChild(url, adjacentTo: node.url, after: after)
                    } else if let parent = node.parentUrl {
                        model.moveItem(url, into: parent)
                    }
                }
            }
        )
    }
}

@MainActor
private func importDroppedFiles(
    _ urls: [URL],
    model: NotesModel,
    into folderUrl: String?,
    place: @escaping @MainActor ([String]) -> Void
) {
    guard !urls.isEmpty else { return }
    if urls.contains(where: NotesModel.canImportAsNote) {
        model.fileImportRequest = FileImportRequest(urls: urls, folderUrl: folderUrl, place: place)
    } else {
        Task { place(await model.importFiles(urls, into: folderUrl, asNotes: false)) }
    }
}

@MainActor
private func placeImported(
    _ imported: [String],
    model: NotesModel,
    in folderUrl: String,
    adjacentTo target: String,
    after: Bool
) {
    guard !imported.isEmpty else { return }
    var order = model.orderedChildren(model.node(for: folderUrl)?.children ?? [], in: folderUrl)
        .filter { $0.kind != "folder" }
        .map(\.url)
    order.removeAll { imported.contains($0) }
    let index = order.firstIndex(of: target).map { after ? $0 + 1 : $0 } ?? order.count
    order.insert(contentsOf: imported, at: index)
    model.childOrder[folderUrl] = order
}

private func loadPayload(_ provider: NSItemProvider, handle: @escaping @MainActor (String) -> Void) {
    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
        guard let payload = droppedString(from: item) else { return }
        Task { @MainActor in handle(payload) }
    }
}

private func loadFileURLs(
    _ providers: [NSItemProvider],
    urls: [URL] = [],
    handle: @escaping @MainActor ([URL]) -> Void
) {
    guard let provider = providers.first else {
        Task { @MainActor in handle(urls) }
        return
    }
    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
        var loaded = urls
        if let url = item as? URL {
            loaded.append(url)
        } else if let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) {
            loaded.append(url)
        }
        loadFileURLs(Array(providers.dropFirst()), urls: loaded, handle: handle)
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
    @State private var showingConsole = false
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
        // docUrl is always the plain origin URL. What the view actually reads
        // is the backing url: the checked-out draft's clone, pinned to the
        // scrubbed version. The embed answers repo:handle-descriptor with it,
        // so OverlayRepo swaps the live handle's backing in place — no
        // remount on scrub, and no waiting on the checkout doc to sync into
        // the webview's repo. Nested docs still come from the draft overlay.
        let draftUrl = model.checkedOutDrafts[docUrl]
        let scrubbed = historyVersion != nil
        let resolved = model.resolvedNoteUrl(docUrl)
        let backingUrl = historyVersion
            .flatMap { model.pinnedUrl(resolved, heads: $0.heads) }
            ?? (resolved == docUrl ? nil : resolved)
        Group {
            if PatchworkWeb.available {
                PatchworkBoxWebViewWrapper(
                    docUrl: docUrl,
                    toolId: appliedToolId,
                    draftUrl: draftUrl,
                    checkoutUrl: model.checkoutDocs[docUrl],
                    backingUrl: backingUrl,
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
            if PatchworkWeb.available {
                ToolbarItem {
                    Button {
                        showingConsole = true
                    } label: {
                        Label("JavaScript", systemImage: "curlybraces")
                    }
                }
            }
            #if os(macOS)
            ToolbarSpacer(.fixed)
            ToolbarItem(placement: .primaryAction) {
                PresenceFacesView(presence: model.presence)
            }
            ToolbarSpacer(.fixed)
            ToolbarItem(id: "inspector") {
                Button {
                    rightSidebarVisible?.wrappedValue.toggle()
                } label: {
                    Label("Inspector", systemImage: "info.circle")
                        .foregroundStyle(rightSidebarVisible?.wrappedValue == true ? Color.accentColor : Color.primary)
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
        .sheet(isPresented: $showingConsole) {
            PatchworkConsole(
                target: .doc(docUrl),
                docUrl: docUrl,
                onDone: { showingConsole = false }
            )
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
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .interactiveDismissDisabled(model.pads.drawing)
        }
        #endif
    }
}

struct IncomingContentSheet: View {
    let content: IncomingContent
    @Environment(NotesModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var allNotes: [FolderNode] = []

    private var displayTitle: String {
        content.displayTitle
    }

    private func collectNotes() {
        var out: [FolderNode] = []
        func walk(_ nodes: [FolderNode]) {
            for node in nodes {
                if node.isNote { out.append(node) }
                if let ch = node.children { walk(ch) }
            }
        }
        walk(model.folderTree)
        allNotes = out
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
                        Task { await model.importAsNewNote(content) }
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
            .onChange(of: model.folderTree, initial: true) { collectNotes() }
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
