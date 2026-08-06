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
    @State private var copiedLocalPort = false
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
                if let httpUrl = model.core?.localHttpUrl() {
                    LabeledContent("Local (HTTP)") {
                        HStack(spacing: 8) {
                            Text(httpUrl)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Button(copiedLocalPort ? "Copied" : "Copy") {
                                Clipboard.copy(httpUrl)
                                copiedLocalPort = true
                                Task {
                                    try? await Task.sleep(for: .seconds(2))
                                    copiedLocalPort = false
                                }
                            }
                        }
                    }
                }
            }
            Section {
                if let nodeId = model.core?.irohNodeId() {
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
                    TextField("friend's node id", text: $peerText)
                        .font(.body.monospaced())
                    Button("Add Peer") {
                        let nodeId = peerText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !nodeId.isEmpty else { return }
                        do {
                            try model.core?.addIrohPeer(nodeId: nodeId)
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
                    Text("iroh endpoint not running.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Peers (iroh)")
            } footer: {
                Text("Share this device's node id and add a friend's; the rust subduction cores then sync directly via iroh.")
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
    @Environment(ContextTracker.self) private var contextTracker
    @State private var fontDesign = EditorSettings.design
    @State private var fontSize = EditorSettings.bodySize
    @State private var autoInsertLogline = EditorSettings.autoInsertLogline
    @State private var places = SavedPlaces.all
    @State private var placeName = ""

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
            Section {
                ForEach(places) { place in
                    HStack {
                        Label(place.name, systemImage: "mappin.and.ellipse")
                        Spacer()
                        Button("Remove") {
                            places.removeAll { $0.id == place.id }
                            SavedPlaces.save(places)
                            contextTracker.refreshPlaceName()
                        }
                    }
                }
                HStack {
                    TextField("Name", text: $placeName)
                    Button("Add Here") { addPlace() }
                        .disabled(placeName.trimmingCharacters(in: .whitespaces).isEmpty
                            || contextTracker.snapshot.latitude == nil)
                }
            } header: {
                Text("Places")
            } footer: {
                Text("A logline within 150m of a saved place uses its name — \"Home, London, England\" instead of the street.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Editor")
    }

    private func addPlace() {
        let snap = contextTracker.snapshot
        guard let lat = snap.latitude, let lon = snap.longitude else { return }
        places.append(SavedPlace(
            name: placeName.trimmingCharacters(in: .whitespaces),
            latitude: lat,
            longitude: lon
        ))
        SavedPlaces.save(places)
        placeName = ""
        contextTracker.refreshPlaceName()
    }
}

struct PatchworkSettingsPane: View {
    @Environment(NotesModel.self) private var model
    @State private var moduleText = ""
    @State private var moduleUrls = PatchworkWeb.moduleUrls
    @State private var accountText = ""
    @State private var folderText = ""
    @State private var loggingIn = false

    var body: some View {
        Form {
            Section {
                if model.loggedIn {
                    HStack(spacing: 8) {
                        if let data = model.contactAvatarData, let image = PImage(data: data) {
                            Image(pImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 28, height: 28)
                                .clipShape(Circle())
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.contactName ?? "Logged in")
                            Text(model.accountUrl ?? "")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button("Log Out") { model.logOut() }
                    }
                } else {
                    TextField("account:… or automerge:… account url", text: $accountText)
                        .font(.body.monospaced())
                    Button(loggingIn ? "Logging in…" : "Log In") {
                        let url = accountText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard NotesModel.normalizedAccountUrl(url) != nil else { return }
                        loggingIn = true
                        Task {
                            if await model.logIn(accountUrl: url) {
                                accountText = ""
                            }
                            loggingIn = false
                        }
                    }
                    .disabled(
                        loggingIn
                            || NotesModel.normalizedAccountUrl(accountText) == nil
                    )
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Log in with a Patchwork account doc. Your folders and inbox sync across devices through the account's lush config doc.")
            }
            Section {
                ForEach(model.rootFolderUrls, id: \.self) { url in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.node(for: url)?.displayName ?? "Folder")
                            Text(url)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        if model.loggedIn {
                            Button(model.inboxUrl == url ? "Inbox ✓" : "Make Inbox") {
                                model.setInbox(url)
                            }
                            .disabled(model.inboxUrl == url)
                        }
                        Button("Remove") {
                            model.removeRootFolder(url)
                        }
                        .disabled(model.rootFolderUrls.count == 1)
                    }
                }
                TextField("automerge:… folder url", text: $folderText)
                    .font(.body.monospaced())
                Button("Add Folder") {
                    let url = folderText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !url.isEmpty else { return }
                    folderText = ""
                    Task { await model.addRootFolder(url) }
                }
                .disabled(folderText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Folders")
            } footer: {
                Text("The folders shown in the sidebar. New notes from the widget or shortcuts land in the inbox folder. When logged in this list lives in your account's lush config and syncs across devices.")
            }
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
