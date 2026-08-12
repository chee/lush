import SwiftUI
#if os(macOS)
import AppKit
#endif

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
        Group {
            content
        }
        .tint(nil)
    }

    @ViewBuilder
    private var content: some View {
        if isPatchworkDoc {
            Button {
                model.openInPatchwork(node.url)
            } label: {
                OpenInPatchworkLabel()
            }
        }
        if node.kind == "lush" || node.kind == "rich" {
            #if os(macOS)
            Button {
                openWindow(id: "note-detail", value: node.url)
            } label: {
                Label("Open in New Window", systemImage: "macwindow.badge.plus")
            }
            Divider()
            #endif
            Button {
                model.togglePin(node.url)
            } label: {
                Label(
                    model.isPinned(node.url) ? "Unpin" : "Pin",
                    systemImage: model.isPinned(node.url) ? "pin.slash" : "pin"
                )
            }
            Button {
                model.setQuickNote(model.quickNoteUrl == node.url ? nil : node.url)
            } label: {
                Label(
                    model.quickNoteUrl == node.url ? "Unset Quick Note" : "Set as Quick Note",
                    systemImage: "bolt"
                )
            }
            if let showInFolder {
                Button(action: showInFolder) {
                    Label("Show in Folder", systemImage: "folder")
                }
            }
        }
        Divider()
        if let rename {
            Button(action: rename) {
                Label("Rename", systemImage: "pencil")
            }
        }
        if node.parentUrl != nil, let move {
            Button(action: move) {
                Label("Move…", systemImage: "arrowshape.turn.up.right")
            }
        }
        Divider()
        CopyUrlMenu(url: node.url)
        if node.parentUrl != nil {
            Divider()
            Button(role: .destructive) {
                model.removeEntry(parentUrl: node.parentUrl, url: node.url)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

struct OpenInPatchworkLabel: View {
    #if os(macOS)
    static let mark: NSImage = {
        let image = NSImage(named: "PatchworkMarkMonochrome") ?? NSImage()
        image.size = NSSize(width: 15, height: 15)
        return image
    }()
    #endif

    var body: some View {
        Label {
            Text("Open in Patchwork")
        } icon: {
            #if os(macOS)
            Image(nsImage: Self.mark)
            #else
            Image("PatchworkMarkMonochrome")
            #endif
        }
    }
}

struct CopyUrlMenu: View {
    let url: String

    var body: some View {
        Menu("Copy") {
            Button("Automerge URL") { Clipboard.copy(url) }
            Button("Patchwork URL") { Clipboard.copy(NotesModel.patchworkUrl(for: url)) }
            Button("Lush URL") { Clipboard.copy(lushLink(for: url)) }
        }
    }
}

func lushLink(for url: String) -> String {
    var components = URLComponents(string: "lush://show")
    components?.queryItems = [URLQueryItem(name: "doc", value: url)]
    return components?.url?.absoluteString ?? url
}
