import SwiftUI

/// The actions a single note offers wherever it is listed. The callers hold
/// the state the sheets need, so what they can't do arrives as nil and drops
/// out of the menu.
struct NoteContextMenu: View {
    let node: FolderNode
    var showInFolder: (() -> Void)?
    var move: (() -> Void)?
    var rename: (() -> Void)?

    @Environment(NotesModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var isPatchworkDoc: Bool {
        model.patchworkDocUrls.contains(node.url) || node.isPatchworkDoc
    }

    var body: some View {
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
            if let showInFolder {
                Button("Show in Folder", action: showInFolder)
            }
        }
        if node.parentUrl != nil, let move {
            Button("Move…", action: move)
        }
        if let rename {
            Button("Rename", action: rename)
        }
        Button("Copy Note URL") { Clipboard.copy(node.url) }
        if isPatchworkDoc {
            Button("Copy Patchwork URL") { model.copyPatchworkUrl(for: node.url) }
            Button("Open in Patchwork") { model.openInPatchwork(node.url) }
        }
        if node.parentUrl != nil {
            Button("Delete", role: .destructive) {
                model.removeEntry(parentUrl: node.parentUrl, url: node.url)
            }
        }
    }
}
