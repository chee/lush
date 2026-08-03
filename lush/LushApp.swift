import SwiftUI
#if os(macOS)
import AppKit

private extension NSResponder {
    @objc(pasteAsPlainText:) func pasteAsPlainTextCommand(_ sender: Any?) {}
}
#endif

struct EditorControllerFocusKey: FocusedValueKey {
    typealias Value = EditorController
}

extension FocusedValues {
    var editorController: EditorController? {
        get { self[EditorControllerFocusKey.self] }
        set { self[EditorControllerFocusKey.self] = newValue }
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
            Button("Insert Dateline") { editor?.insertDateline() }
                .keyboardShortcut("d", modifiers: [.command, .option])
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
    @State private var model = NotesModel()
    @State private var contextTracker = ContextTracker()

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
        }
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
