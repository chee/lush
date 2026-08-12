import SwiftUI

struct FileImportRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
    let folderUrl: String?
    var place: (@MainActor ([String]) -> Void)? = nil
}

struct FileImportChoiceSheet: View {
    let request: FileImportRequest
    @Environment(NotesModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var readable: [URL] { request.urls.filter(NotesModel.canImportAsNote) }
    private var others: [URL] { request.urls.filter { !NotesModel.canImportAsNote($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(readable.count == 1
                 ? "How should \(readable[0].lastPathComponent) come in?"
                 : "How should these \(readable.count) text files come in?")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(readable, id: \.self) { url in
                    Text(url.lastPathComponent)
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                }
                if !others.isEmpty {
                    Text("\(others.count) other file\(others.count == 1 ? "" : "s") will be kept as files.")
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Keep as Files") { finish(asNotes: false) }
                Button("Import as Notes") { finish(asNotes: true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 380)
    }

    private func finish(asNotes: Bool) {
        let request = request
        let model = model
        Task {
            let imported = await model.importFiles(request.urls, into: request.folderUrl, asNotes: asNotes)
            request.place?(imported)
        }
        dismiss()
    }
}
