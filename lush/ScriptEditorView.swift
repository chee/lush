import SwiftUI

struct ScriptEditorView: View {
    let url: String
    @Environment(NotesModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var titleText = ""
    @State private var moveTarget: MoveTarget?
    @FocusState private var titleFocused: Bool

    private var node: FolderNode? { model.node(for: url) }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Untitled Script", text: $titleText)
                .font(.title2.bold())
                .textFieldStyle(.plain)
                .focused($titleFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .onSubmit { saveTitle() }
                .onChange(of: titleFocused) { _, focused in
                    if !focused { saveTitle() }
                }
            Divider()
            if PatchworkWeb.available {
                PatchworkWebView(docUrl: url, toolId: "file")
            } else {
                ContentUnavailableView(
                    "Patchwork Unavailable",
                    systemImage: "scroll",
                    description: Text("Add PatchworkWeb.bundle to render this script.")
                )
            }
        }
        .task(id: url) {
            titleText = node?.name ?? ""
        }
        .onChange(of: model.node(for: url)?.name) { _, newName in
            if let newName, !titleFocused, newName != titleText {
                titleText = newName
            }
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    if let n = node {
                        if n.parentUrl != nil {
                            Button("Move…") { moveTarget = MoveTarget(urls: [url]) }
                        }
                        Button("Copy Script URL") { Clipboard.copy(url) }
                        if n.parentUrl != nil {
                            Divider()
                            Button("Delete", role: .destructive) {
                                model.removeEntry(parentUrl: n.parentUrl, url: url)
                                #if os(macOS)
                                model.selectedNoteUrl = nil
                                #else
                                dismiss()
                                #endif
                            }
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .disabled(node == nil)
            }
        }
        .sheet(item: $moveTarget) { target in
            MoveSheet(urls: target.urls).environment(model)
        }
    }

    private func saveTitle() {
        guard let node else { return }
        let name = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != node.name else { return }
        model.renameEntry(parentUrl: node.parentUrl, url: url, to: name)
    }
}
