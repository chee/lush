import SwiftUI

struct SettingsView: View {
    @Environment(NotesModel.self) private var model
    @State private var folderText = ""
    @State private var copiedUrl: String?

    var body: some View {
        Form {
            Section("Sync") {
                LabeledContent("Server", value: "subduction.sync.inkandswitch.com")
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.connected ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(model.connected ? "Connected" : "Offline")
                    }
                }
            }
            Section {
                ForEach(model.rootFolderUrls, id: \.self) { url in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folderName(url))
                            Text(url)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button(copiedUrl == url ? "Copied" : "Copy") {
                            Clipboard.copy(url)
                            copiedUrl = url
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                if copiedUrl == url { copiedUrl = nil }
                            }
                        }
                        Button("Remove") {
                            model.removeRootFolder(url)
                        }
                        .disabled(model.rootFolderUrls.count == 1)
                    }
                }
            } header: {
                Text("Folders")
            } footer: {
                Text("Copy a folder URL to add it to Patchwork. Removing a folder only takes it out of the sidebar — it stays on the sync server.")
            }
            Section {
                TextField("automerge:…", text: $folderText)
                    .font(.body.monospaced())
                Button("Add Folder") {
                    let url = folderText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !url.isEmpty else { return }
                    folderText = ""
                    Task { await model.addRootFolder(url) }
                }
                .disabled(
                    folderText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            } header: {
                Text("Add a folder")
            } footer: {
                Text("Paste a Patchwork folder URL to show it in the sidebar alongside your other folders.")
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        #endif
    }

    private func folderName(_ url: String) -> String {
        guard let core = model.core else { return "Folder" }
        let name = core.noteTitle(url: url)
        return name.isEmpty ? "Notes" : name
    }
}
