import SwiftUI

#if os(macOS)
struct QuickCaptureView: View {
    @Environment(NotesModel.self) private var model
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Quick note", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
                .onSubmit { submit() }

            HStack {
                Button("Add") { submit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Open Quick Note") {
                    AppRouter.shared.pending = .quickNote
                }
                Spacer()
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Button("New Note") { AppRouter.shared.pending = .newNote }
                    Button("Dictionary") {
                        AppRouter.shared.pending = .createPatchwork(preferredType: "dictionary", toolId: nil, folderUrl: nil)
                    }
                }
                GridRow {
                    Button("File") {
                        Task { _ = await model.createFileForShortcut(inFolder: nil) }
                    }
                    Button("Patchwork…") {
                        AppRouter.shared.pending = .createPatchwork(preferredType: nil, toolId: nil, folderUrl: nil)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320)
        .task { await model.start() }
    }

    private func submit() {
        let snippet = text
        text = ""
        Task { _ = await model.appendToQuickNote(snippet) }
    }
}
#endif
