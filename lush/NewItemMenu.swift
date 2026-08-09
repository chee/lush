import SwiftUI

struct NewItemMenuItems: View {
    let model: NotesModel
    var folderUrl: String? = nil
    var snap: ContextSnapshot? = nil
    var shortcuts = false
    var onCreate: (String) -> Void = { _ in }

    private var target: String? { folderUrl ?? model.folderUrl }

    var body: some View {
        Group {
            content
        }
        .tint(.primary)
    }

    @ViewBuilder
    private var content: some View {
        Button {
            Task {
                let url: String?
                if let target {
                    url = await model.createNote(inFolder: target, snap: snap)
                } else {
                    url = await model.createNote(snap: snap)
                }
                if let url { onCreate(url) }
            }
        } label: {
            Label("Note", systemImage: "square.and.pencil")
        }
        .keyboardShortcut(shortcuts ? KeyboardShortcut("n", modifiers: .command) : nil)
        Button {
            if let target {
                model.createScript(in: target)
            } else {
                model.createScript()
            }
        } label: {
            Label("Script", systemImage: "curlybraces")
        }
        .keyboardShortcut(shortcuts ? KeyboardShortcut("n", modifiers: [.command, .shift]) : nil)
        Button {
            if let target {
                model.createSubfolder(in: target)
            } else {
                model.createFolder()
            }
        } label: {
            Label("Folder", systemImage: "folder.badge.plus")
        }
        if PatchworkWeb.available {
            Button {
                AppRouter.shared.pending = .createPatchwork(
                    preferredType: nil,
                    toolId: nil,
                    folderUrl: folderUrl ?? model.folderUrl
                )
            } label: {
                Label("Patchwork Doc…", systemImage: "shippingbox")
            }
        }
        Divider()
        Button {
            Task { await model.createNotebook() }
        } label: {
            Label("Notebook", systemImage: "book.closed")
        }
        Button {
            AppRouter.shared.pending = .newSmartNotebook
        } label: {
            Label("Smart Notebook…", systemImage: "folder.badge.gearshape")
        }
    }
}
