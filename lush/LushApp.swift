import SwiftUI
import AppIntents
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import AppKit
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif

private extension NSResponder {
    @objc(pasteAsPlainText:) func pasteAsPlainTextCommand(_ sender: Any?) {}
}

@MainActor
final class LushAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        LushShared.migrateDefaults()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = LushServicesProvider.shared
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        NSApp.setActivationPolicy(.accessory)
        NSApp.hide(nil)
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    static func reallyQuit() {
        NotesModel.shared.activeEditor?.core?.pushNow()
        NotesModel.shared.presence.leave()
        NotesModel.shared.core?.shutdown()
        NSApp.setActivationPolicy(.accessory)
        exit(0)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await NotesModel.shared.focus.reconcileWithSystemFocus() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotesModel.shared.activeEditor?.core?.pushNow()
        NotesModel.shared.presence.leave()
        NotesModel.shared.core?.shutdown()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "New Note",
            action: #selector(newDockNote(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Open Quick Note",
            action: #selector(openDockQuickNote(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Quick Capture",
            action: #selector(openDockQuickCapture(_:)),
            keyEquivalent: ""
        ))

        let recents = Array(NotesModel.shared.recents.prefix(8))
        if !recents.isEmpty {
            menu.addItem(.separator())
            for recent in recents {
                let item = NSMenuItem(
                    title: recent.node.displayName.isEmpty ? "Untitled" : recent.node.displayName,
                    action: #selector(openDockRecent(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = recent.node.url
                menu.addItem(item)
            }
        }
        return menu
    }

    /// With a main window up, set the pending action and activate. With none,
    /// pending would sit unprocessed — open the app's own lush:// url instead,
    /// which makes SwiftUI create a window to deliver it.
    private func route(_ action: AppRouter.Action, fallback url: URL?) {
        let hasMainWindow = NSApp.windows.contains {
            $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true
        }
        if hasMainWindow || url == nil {
            AppRouter.shared.pending = action
            NSApp.activate()
        } else if let url {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func newDockNote(_ sender: Any?) {
        route(.newNote, fallback: URL(string: "lush://new"))
    }

    @objc private func openDockQuickNote(_ sender: Any?) {
        route(.quickNote, fallback: URL(string: "lush://show?doc=quick"))
    }

    @objc private func openDockQuickCapture(_ sender: Any?) {
        route(.capture, fallback: URL(string: "lush://capture"))
    }

    @objc private func openDockRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        var components = URLComponents(string: "lush://show")
        components?.queryItems = [URLQueryItem(name: "doc", value: url)]
        route(.note(url), fallback: components?.url)
    }

    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        if LushHandoff.handle(userActivity) {
            application.activate()
            return true
        }
        #if canImport(CoreSpotlight)
        guard userActivity.activityType == CSSearchableItemActionType,
              let url = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String
        else { return false }
        AppRouter.shared.pending = .note(url)
        application.activate()
        return true
        #else
        return false
        #endif
    }
}
#endif

struct EditorControllerFocusKey: FocusedValueKey {
    typealias Value = EditorController
}

struct NoteSearchActions {
    let focusNoteSearch: () -> Void
    let focusNotesSearch: () -> Void
}

struct NoteSearchActionsFocusKey: FocusedValueKey {
    typealias Value = NoteSearchActions
}

extension FocusedValues {
    var editorController: EditorController? {
        get { self[EditorControllerFocusKey.self] }
        set { self[EditorControllerFocusKey.self] = newValue }
    }

    var noteSearchActions: NoteSearchActions? {
        get { self[NoteSearchActionsFocusKey.self] }
        set { self[NoteSearchActionsFocusKey.self] = newValue }
    }
}

struct FolderCommands: Commands {
    let model: NotesModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Menu("New") {
                NewItemMenuItems(model: model, shortcuts: true)
            }
            Divider()
            Button("Copy Folder URL") { model.copyFolderUrl() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            #if os(macOS)
            Divider()
            Menu("Import") {
                Button("File from Your Computer…") {
                    model.showingFileImporter = true
                }
                .disabled(model.folderUrl == nil)
                Button("From Apple Notes…") {
                    Task { await model.importAppleNotes() }
                }
                .disabled(model.folderUrl == nil)
                if !model.importStatus.isEmpty {
                    Divider()
                    Text(model.importStatus)
                }
            }
            #endif
        }
    }
}

struct ViewCommands: Commands {
    @AppStorage(EditorSettings.zenModeKey) private var zenMode = false
    @AppStorage(EditorSettings.typewriterModeKey) private var typewriterMode = false
    @AppStorage(EditorSettings.minimapKey) private var minimapVisible = false

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Toggle("Zen Mode", isOn: $zenMode)
                .keyboardShortcut("z", modifiers: [.command, .control])
            Toggle("Typewriter Mode", isOn: Binding(
                get: { typewriterMode },
                set: { EditorSettings.setTypewriterMode($0) }
            ))
            .keyboardShortcut("t", modifiers: [.command, .control])
            Toggle("Show Minimap", isOn: Binding(
                get: { minimapVisible },
                set: { EditorSettings.setMinimapVisible($0) }
            ))
            Divider()
        }
    }
}

struct FormatCommands: Commands {
    @FocusedValue(\.editorController) private var editor

    var body: some Commands {
        CommandMenu("Format") {
            Button("Bold") { editor?.toggleStrong() }
                .keyboardShortcut("b")
            Button("Italic") { editor?.toggleEm() }
                .keyboardShortcut("i")
            Button("Inline Code") { editor?.toggleCode() }
                .keyboardShortcut("e")
            Button("Underline") { editor?.toggleUnderline() }
                .keyboardShortcut("u")
            Button("Strikethrough") { editor?.toggleStrikethrough() }
                .keyboardShortcut("/")
            Button("Link…") { editor?.editLink() }
                .keyboardShortcut("k")
            Button("Remove Link") { editor?.applyLink(nil) }
                .disabled(editor?.linkActive == nil)
            Button("Superscript") { editor?.toggleSuperscript() }
                .keyboardShortcut("+", modifiers: [.command, .control])
            Button("Subscript") { editor?.toggleSubscript() }
                .keyboardShortcut("-", modifiers: [.command, .control])
            Menu("Font") {
                ForEach(RichText.fontRoles, id: \.key) { role in
                    Button(role.label) {
                        editor?.applyFontRole(editor?.fontRoleActive == role.key ? nil : role.key)
                    }
                }
                Divider()
                Button("Default") { editor?.applyFontRole(nil) }
            }
            Menu("Highlight") {
                ForEach(Highlight.names, id: \.self) { name in
                    Button(name.capitalized) { editor?.applyHighlight(name) }
                }
                Divider()
                Button("None") { editor?.applyHighlight(nil) }
            }
            Divider()
            Button("Title") { editor?.applyStyle("heading1") }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Heading") { editor?.applyStyle("heading2") }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Subheading") { editor?.applyStyle("heading3") }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            Button("Body") { editor?.applyStyle("paragraph") }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
            Button("Bulleted List") { editor?.applyStyle("unordered-list-item") }
                .keyboardShortcut("8", modifiers: [.command, .shift])
            Button("Numbered List") { editor?.applyStyle("ordered-list-item") }
                .keyboardShortcut("7", modifiers: [.command, .shift])
            Button("To-do List") { editor?.applyStyle("todo-list-item") }
                .keyboardShortcut("0", modifiers: [.command, .shift])
            Button("Block Quote") { editor?.applyStyle("blockquote") }
                .keyboardShortcut("9", modifiers: [.command, .shift])
            Divider()
            Button("Move Item Up") { editor?.moveItemUp() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])
            Button("Move Item Down") { editor?.moveItemDown() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])
            Button("Move Checked to Bottom") { editor?.moveCheckedToBottom() }
            Button(editor?.checkedItemsHidden == true ? "Show Checked Items" : "Hide Checked Items") {
                editor?.toggleHideChecked()
            }
            Button("Delete Checked Items") { editor?.deleteChecked() }
            Button("Code Block") { editor?.applyStyle("code-block") }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Menu("Code Language") {
                ForEach(CodeLanguage.all) { language in
                    Button(language.name) { editor?.applyCodeLanguage(language) }
                }
            }
            Divider()
            Button("Fold Section") {
                editor?.core?.toggleFoldAtSelection()
            }
            .keyboardShortcut("-", modifiers: [.command, .option])
            Button("Send to Note Scratchpad") {
                editor?.core?.sendSelectionToPad(pocket: false)
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            Button("Send to Pocket Pad") {
                editor?.core?.sendSelectionToPad(pocket: true)
            }
            .keyboardShortcut("s", modifiers: [.command, .control, .option])
            Divider()
            Button("Attach Image…") { editor?.attachImageFromPanel() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Attach File…") { editor?.attachFileFromPanel() }
                .keyboardShortcut("a", modifiers: [.command, .option])
            Button("Record Audio") { editor?.recorderVisible.toggle() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Insert Logline") { editor?.insertLogline() }
                .keyboardShortcut("l", modifiers: [.command])
            Button("Insert Table") { editor?.insertTable() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button("Insert Columns") { editor?.insertColumns() }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Button("Insert HTML Block") { editor?.insertHtmlBlock() }
                .keyboardShortcut("h", modifiers: [.command, .option])
        }
    }
}

#if os(macOS)
struct SearchCommands: Commands {
    @FocusedValue(\.noteSearchActions) private var searchActions
    @FocusedValue(\.editorController) private var editor

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find in Note") {
                editor?.openFind()
            }
            .keyboardShortcut("f")

            Button("Select Next Occurrence") {
                editor?.core?.selectNextOccurrence()
            }
            .keyboardShortcut("d")

            Button("Find Next") {
                editor?.findNext()
            }
            .keyboardShortcut("g")

            Button("Find Previous") {
                editor?.findPrevious()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])

            Button("Search Notes") {
                searchActions?.focusNotesSearch()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        }
    }
}

struct EditCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Paste and Match Style") {
                NSApp.sendAction(#selector(NSResponder.pasteAsPlainTextCommand(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("v", modifiers: [.command, .option, .shift])
        }
    }
}
#endif

@main
struct LushApp: App {
    @State private var model = NotesModel.shared
    @State private var contextTracker = ContextTracker()
    #if os(macOS)
    @NSApplicationDelegateAdaptor(LushAppDelegate.self) private var appDelegate
    #endif

    init() {
        LushShortcuts.updateAppShortcutParameters()
        InterfaceFont.applyNavigationBarAppearance(family: InterfaceFont.family)
        #if os(iOS) || os(visionOS)
        BackgroundSync.register()
        #endif
        // Ahead of the scene's .task, which doesn't run until the first views
        // are built — a second of main-thread work the core could have spent
        // opening storage on another thread. The .task callers await the same
        // startTask, so this only moves the start earlier.
        NotesModel.shared.prewarm()
        Task { @MainActor in await NotesModel.shared.start() }
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup(id: "main") {
            ContentView()
                .environment(model)
                .environment(contextTracker)
                .interfaceFont()
                .task {
                    async let server: Void = LocalSyncServer.startIfNeeded()
                    await model.start()
                    await server
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            EditCommands()
            SearchCommands()
            ViewCommands()
            FormatCommands()
            FolderCommands(model: model)
        }

        WindowGroup(id: "note-detail", for: String.self) { $noteUrl in
            if let url = noteUrl {
                NoteDetail(noteUrl: url)
                    .environment(model)
                    .environment(contextTracker)
                    .interfaceFont()
                    .task {
                        async let server: Void = LocalSyncServer.startIfNeeded()
                        await model.start()
                        await server
                    }
            }
        }
        .windowToolbarStyle(.unified(showsTitle: false))

        Settings {
            SettingsView()
                .environment(model)
                .environment(contextTracker)
                .interfaceFont()
        }

        WindowGroup("Quick Capture", id: "quick-capture") {
            QuickCaptureView()
                .environment(model)
                .interfaceFont()
        }
        .defaultSize(width: 340, height: 190)
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarCaptureView()
                .environment(model)
                .interfaceFont()
        } label: {
            LushMenuBarIcon()
                .accessibilityLabel("Lush")
        }
        .menuBarExtraStyle(.window)
        #else
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(contextTracker)
                .interfaceFont()
                .task {
                    async let server: Void = LocalSyncServer.startIfNeeded()
                    await model.start()
                    await server
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didBecomeActiveNotification
                    )
                ) { _ in
                    Task { await NotesModel.shared.focus.reconcileWithSystemFocus() }
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didEnterBackgroundNotification
                    )
                ) { _ in
                    BackgroundSync.didEnterBackground()
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)
                ) { _ in
                    NotesModel.shared.activeEditor?.core?.pushNow()
                    NotesModel.shared.presence.leave()
                    NotesModel.shared.core?.shutdown()
                }
        }
        .commands {
            FormatCommands()
            FolderCommands(model: model)
        }
        #endif
    }
}
