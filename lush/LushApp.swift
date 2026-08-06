import SwiftUI
import AppIntents
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = LushServicesProvider.shared
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

    @objc private func newDockNote(_ sender: Any?) {
        AppRouter.shared.pending = .newNote
        NSApp.activate()
    }

    @objc private func openDockQuickNote(_ sender: Any?) {
        AppRouter.shared.pending = .quickNote
        NSApp.activate()
    }

    @objc private func openDockQuickCapture(_ sender: Any?) {
        AppRouter.shared.pending = .capture
        NSApp.activate()
    }

    @objc private func openDockRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        AppRouter.shared.pending = .note(url)
        NSApp.activate()
    }

    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
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
            Button("New Note") { model.createNote() }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Script") { model.createScript() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Copy Folder URL") { model.copyFolderUrl() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
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
            Button("Superscript") { editor?.toggleSuperscript() }
                .keyboardShortcut("+", modifiers: [.command, .control])
            Button("Subscript") { editor?.toggleSubscript() }
                .keyboardShortcut("-", modifiers: [.command, .control])
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
            Button("Code Block") { editor?.applyStyle("code-block") }
                .keyboardShortcut("m", modifiers: [.command, .shift])
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

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find") {
                searchActions?.focusNoteSearch()
            }
            .keyboardShortcut("f")

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
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(contextTracker)
                .task {
                    async let server: Void = LocalSyncServer.startIfNeeded()
                    await model.start()
                    await server
                    contextTracker.start()
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            EditCommands()
            SearchCommands()
            FormatCommands()
            FolderCommands(model: model)
        }

        WindowGroup(id: "note-detail", for: String.self) { $noteUrl in
            if let url = noteUrl {
                NoteDetail(noteUrl: url)
                    .environment(model)
                    .environment(contextTracker)
                    .task {
                        async let server: Void = LocalSyncServer.startIfNeeded()
                        await model.start()
                        await server
                        contextTracker.start()
                    }
            }
        }
        .windowToolbarStyle(.unified(showsTitle: false))

        Settings {
            SettingsView()
                .environment(model)
                .environment(contextTracker)
        }

        WindowGroup("Quick Capture", id: "quick-capture") {
            QuickCaptureView()
                .environment(model)
        }
        .defaultSize(width: 340, height: 190)
        .windowResizability(.contentSize)

        MenuBarExtra("Lush", systemImage: "text.badge.plus") {
            QuickCaptureView()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
        #else
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(contextTracker)
                .task {
                    async let server: Void = LocalSyncServer.startIfNeeded()
                    await model.start()
                    await server
                    contextTracker.start()
                }
        }
        .commands {
            FormatCommands()
            FolderCommands(model: model)
        }
        #endif
    }
}
