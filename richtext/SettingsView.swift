import SwiftUI

struct SettingsView: View {
    @Environment(NotesModel.self) private var model
    @State private var folderText = ""
    @State private var copiedUrl: String?
    @State private var peerText = ""
    @State private var peerError: String?
    @State private var copiedNodeId = false

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
            Section {
                if let nodeId = LocalSyncServer.irohNodeId {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("This device")
                            Text(nodeId)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button(copiedNodeId ? "Copied" : "Copy") {
                            Clipboard.copy(nodeId)
                            copiedNodeId = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                copiedNodeId = false
                            }
                        }
                    }
                    ForEach(LocalSyncServer.friends, id: \.self) { friend in
                        Text(friend)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    TextField("friend's node id", text: $peerText)
                        .font(.body.monospaced())
                    Button("Add Peer") {
                        let nodeId = peerText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !nodeId.isEmpty else { return }
                        do {
                            try LocalSyncServer.addFriend(nodeId)
                            peerText = ""
                            peerError = nil
                        } catch {
                            peerError = error.localizedDescription
                        }
                    }
                    .disabled(
                        peerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    if let peerError {
                        Text(peerError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } else {
                    Text("The local sync server isn't running.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Peers (iroh)")
            } footer: {
                Text("Share this device's node id and add a friend's; their patchwork embeds then sync device-to-device.")
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
