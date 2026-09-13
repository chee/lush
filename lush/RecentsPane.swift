#if os(macOS)
import SwiftUI

/// The same newest-first list the phone shows under Pinned, as a detail pane.
struct RecentsPane: View {
    let open: (String) -> Void

    @Environment(NotesModel.self) private var model
    @State private var moveTarget: MoveTarget?

    var body: some View {
        Group {
            if model.recents.isEmpty {
                ContentUnavailableView(
                    "No Recents",
                    systemImage: "clock",
                    description: Text("Notes show up here as you change them.")
                )
            } else {
                list
            }
        }
        .navigationTitle("Recents")
        .task { await model.refreshRecents() }
        .onChange(of: model.folderTree) { Task { await model.refreshRecents() } }
        .onChange(of: model.notes) { Task { await model.refreshRecents() } }
        .sheet(item: $moveTarget) { target in
            MoveSheet(urls: target.urls)
                .environment(model)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.recents) { entry in
                    row(entry)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func row(_ entry: RecentEntry) -> some View {
        HStack(alignment: .firstTextBaseline) {
            NoteRowView(node: entry.node, showFolder: true)
            Spacer(minLength: 12)
            Text(entry.modified, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { open(entry.node.url) }
        .contextMenu {
            NoteContextMenu(
                node: entry.node,
                move: { moveTarget = MoveTarget(urls: [entry.node.url]) }
            )
        }
        .pointerStyle(.link)
    }
}
#endif
