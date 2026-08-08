import SwiftUI

struct NewItemMenuItems: View {
    let model: NotesModel
    var folderUrl: String? = nil
    var snap: ContextSnapshot? = nil
    var shortcuts = false
    var onCreate: (String) -> Void = { _ in }

    private var target: String? { folderUrl ?? model.folderUrl }

    var body: some View {
        Button("Note") {
            Task {
                let url: String?
                if let target {
                    url = await model.createNote(inFolder: target, snap: snap)
                } else {
                    url = await model.createNote(snap: snap)
                }
                if let url { onCreate(url) }
            }
        }
        .keyboardShortcut(shortcuts ? KeyboardShortcut("n", modifiers: .command) : nil)
        Button("Folder") {
            if let target {
                model.createSubfolder(in: target)
            } else {
                model.createFolder()
            }
        }
        Button("Script") {
            if let target {
                model.createScript(in: target)
            } else {
                model.createScript()
            }
        }
        .keyboardShortcut(shortcuts ? KeyboardShortcut("n", modifiers: [.command, .shift]) : nil)
        if PatchworkWeb.available {
            Button("Patchwork Doc…") {
                AppRouter.shared.pending = .createPatchwork(
                    preferredType: nil,
                    toolId: nil,
                    folderUrl: folderUrl ?? model.folderUrl
                )
            }
        }
    }
}
