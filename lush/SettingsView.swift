import SwiftUI

struct SettingsView: View {
    var body: some View {
        #if os(macOS)
        TabView {
            Tab("Sync", systemImage: "arrow.triangle.2.circlepath") {
                SyncSettingsPane()
            }
            Tab("Editor", systemImage: "textformat") {
                EditorSettingsPane()
            }
            Tab("Patchwork", systemImage: "shippingbox") {
                PatchworkSettingsPane()
            }
            Tab("Import", systemImage: "square.and.arrow.down") {
                ImportSettingsPane()
            }
        }
        .frame(width: 540, height: 480)
        #else
        List {
            NavigationLink {
                SyncSettingsPane()
            } label: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
            NavigationLink {
                EditorSettingsPane()
            } label: {
                Label("Editor", systemImage: "textformat")
            }
            NavigationLink {
                PatchworkSettingsPane()
            } label: {
                Label("Patchwork", systemImage: "shippingbox")
            }
        }
        .navigationTitle("Settings")
        #endif
    }
}

struct SyncSettingsPane: View {
    @Environment(NotesModel.self) private var model
    @State private var folderText = ""
    @State private var copiedUrl: String?
    @State private var peerText = ""
    @State private var peerError: String?
    @State private var copiedNodeId = false
    @State private var showingClearConfirm = false

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
            Section {
                Button("Force Resync") {
                    model.forceSync()
                }
                Button("Clear Local Storage…", role: .destructive) {
                    showingClearConfirm = true
                }
                .confirmationDialog(
                    "Clear all locally cached data and quit?",
                    isPresented: $showingClearConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Clear and Quit", role: .destructive) {
                        model.clearStorage()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The app will quit and re-sync everything from the server on next launch.")
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Force Resync re-fetches all root folders from the server. Clear Local Storage deletes all cached data and quits — the app will re-sync from scratch on next launch.")
            }
            if !model.syncLog.isEmpty {
                Section("Sync Log") {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach((0..<model.syncLog.count).reversed(), id: \.self) { i in
                                Text(model.syncLog[i])
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 200)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sync")
    }

    private func folderName(_ url: String) -> String {
        model.node(for: url)?.displayName ?? "Notes"
    }
}

struct EditorSettingsPane: View {
    @Environment(NotesModel.self) private var model
    @State private var fontDesign = EditorSettings.design
    @State private var fontSize = EditorSettings.bodySize
    @State private var autoInsertLogline = EditorSettings.autoInsertLogline

    var body: some View {
        Form {
            Section {
                if let url = model.quickNoteUrl {
                    HStack {
                        Label(
                            model.node(for: url)?.displayName ?? "Note",
                            systemImage: "bolt.circle"
                        )
                        Spacer()
                        Button("Clear") { model.setQuickNote(nil) }
                    }
                } else {
                    Text("No Quick Note set.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Quick Note")
            } footer: {
                Text("The Quick Note opens from the widget and Shortcuts. Set one from a note's context menu.")
            }
            Section("Type") {
                Picker("Font", selection: $fontDesign) {
                    ForEach(EditorSettings.designs, id: \.key) { design in
                        Text(design.label).tag(design.key)
                    }
                }
                .onChange(of: fontDesign) {
                    EditorSettings.setDesign(fontDesign)
                }
                HStack {
                    Text("Size")
                    Slider(value: $fontSize, in: 11...24, step: 1)
                        .onChange(of: fontSize) {
                            EditorSettings.setBodySize(fontSize)
                        }
                    Text("\(Int(fontSize))pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Section("Logline") {
                Toggle("Add logline when context changes", isOn: $autoInsertLogline)
                    .onChange(of: autoInsertLogline) {
                        EditorSettings.setAutoInsertLogline(autoInsertLogline)
                    }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Editor")
    }
}

struct PatchworkSettingsPane: View {
    @State private var moduleText = ""
    @State private var moduleUrls = PatchworkWeb.moduleUrls

    var body: some View {
        Form {
            Section {
                ForEach(moduleUrls, id: \.self) { url in
                    HStack {
                        Text(url)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Remove") {
                            moduleUrls.removeAll { $0 == url }
                            PatchworkWeb.setModuleUrls(moduleUrls)
                        }
                    }
                }
                TextField("automerge:… module settings url", text: $moduleText)
                    .font(.body.monospaced())
                Button("Add Modules") {
                    let url = moduleText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard url.hasPrefix("automerge:"), !moduleUrls.contains(url) else { return }
                    moduleUrls.append(url)
                    PatchworkWeb.setModuleUrls(moduleUrls)
                    moduleText = ""
                }
                .disabled(
                    !moduleText.trimmingCharacters(in: .whitespacesAndNewlines)
                        .hasPrefix("automerge:")
                )
            } header: {
                Text("Modules")
            } footer: {
                Text("Paste module settings doc URLs; their datatypes and tools show up when embedding Patchwork documents. Takes effect for newly opened embeds.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Patchwork")
    }
}

#if os(macOS)
struct ImportSettingsPane: View {
    @Environment(NotesModel.self) private var model

    var body: some View {
        Form {
            Section {
                Button("Import from Apple Notes…") {
                    Task { await model.importAppleNotes() }
                }
                .disabled(model.folderUrl == nil)
                if !model.importStatus.isEmpty {
                    Text(model.importStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Apple Notes")
            } footer: {
                Text("Copies every note from Apple Notes into an “Apple Notes” folder here, keeping their folders and edit dates. Already-imported notes are skipped, so it's safe to run again. macOS will ask permission to control Notes the first time.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Import")
    }
}
#endif
