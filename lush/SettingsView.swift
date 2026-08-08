import SwiftUI
#if os(macOS)
import AppKit
#endif
import Intents
import CoreLocation

struct SettingsView: View {
    var body: some View {
        #if os(macOS)
        TabView {
            Tab("Patchwork", systemImage: "shippingbox") {
                PatchworkSettingsPane()
            }
            Tab("Editor", systemImage: "textformat") {
                EditorSettingsPane()
            }
            Tab("Focus", systemImage: "moon") {
                FocusSettingsPane()
            }
            Tab("Permissions", systemImage: "hand.raised") {
                PermissionsSettingsPane()
            }
            Tab("Machine Learning", systemImage: "sparkles.tv") {
                MachineLearningSettingsPane()
            }
            Tab("Sync", systemImage: "arrow.triangle.2.circlepath") {
                SyncSettingsPane()
            }
        }
        .frame(width: 620, height: 620)
        #else
        List {
            NavigationLink {
                PatchworkSettingsPane()
            } label: {
                Label("Patchwork", systemImage: "shippingbox")
            }
            NavigationLink {
                EditorSettingsPane()
            } label: {
                Label("Editor", systemImage: "textformat")
            }
            NavigationLink {
                FocusSettingsPane()
            } label: {
                Label("Focus", systemImage: "moon")
            }
            NavigationLink {
                PermissionsSettingsPane()
            } label: {
                Label("Permissions", systemImage: "hand.raised")
            }
            NavigationLink {
                MachineLearningSettingsPane()
            } label: {
                Label("Machine Learning", systemImage: "sparkles.tv")
            }
            NavigationLink {
                SyncSettingsPane()
            } label: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .navigationTitle("Settings")
        #endif
    }
}

#if os(macOS)
struct AgentSettingsSection: View {
    @State private var status: String?

    var body: some View {
        Section {
            HStack {
                Button("Install for Claude") { install(in: ".claude") }
                Button("Install for Codex") { install(in: ".codex") }
            }
            Text("~/Library/Application Support/Lush/agent.json")
                .font(.caption.monospaced())
                .textSelection(.enabled)
            if let status {
                Text(status)
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Agents")
        } footer: {
            Text("Installs a skill that lets local agents search, read, create, and edit documents while Lush is running. The bearer token changes whenever Lush starts and is readable only by this account.")
        }
    }

    private func install(in agentDirectory: String) {
        guard let picked = agentHome(agentDirectory) else { return }
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        do {
            let resources = [
                ("SKILL", "md", "SKILL.md"),
                ("openai", "yaml", "agents/openai.yaml"),
                ("lush_docs", "py", "scripts/lush_docs.py"),
                ("api", "md", "references/api.md"),
            ]
            let sources = resources.compactMap { resource in
                Bundle.main.url(forResource: resource.0, withExtension: resource.1)
                    .map { ($0, resource.2) }
            }
            guard sources.count == resources.count else {
                status = "The bundled skill could not be found."
                return
            }
            let root = picked.lastPathComponent == agentDirectory
                ? picked
                : picked.appendingPathComponent(agentDirectory, isDirectory: true)
            let skills = root.appendingPathComponent("skills", isDirectory: true)
            let destination = skills.appendingPathComponent("lush-docs", isDirectory: true)
            try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
            let staging = skills.appendingPathComponent(".lush-docs-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            for (source, relativePath) in sources {
                let target = staging.appendingPathComponent(relativePath)
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: source, to: target)
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
            status = "Installed lush-docs in \(destination.path)."
        } catch {
            status = error.localizedDescription
        }
    }

    private func agentHome(_ agentDirectory: String) -> URL? {
        let key = "agentSkillsHome\(agentDirectory)"
        if let data = UserDefaults.standard.data(forKey: key) {
            var stale = false
            let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                bookmarkDataIsStale: &stale
            )
            if let url, !stale { return url }
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = realHome
        panel.prompt = "Install"
        panel.message = "Choose your \(agentDirectory) folder, or your home folder."
        guard panel.runModal() == .OK, let picked = panel.url else { return nil }
        let bookmark = try? picked.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        if let bookmark { UserDefaults.standard.set(bookmark, forKey: key) }
        return picked
    }

    private var realHome: URL {
        guard let passwd = getpwuid(getuid()) else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithFileSystemRepresentation: passwd.pointee.pw_dir, isDirectory: true, relativeTo: nil)
    }
}
#endif

struct SyncSettingsPane: View {
    @Environment(NotesModel.self) private var model
    @State private var folderText = ""
    @State private var copiedUrl: String?
    @State private var peerText = ""
    @State private var peerError: String?
    @State private var copiedNodeId = false
    @State private var copiedLocalPort = false
    @State private var showingClearConfirm = false
    @State private var backgroundSync = LushShared.helperEnabled
    @State private var backgroundMenuBar = LushShared.helperShowsMenuBar

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
            #if os(macOS)
            Section("Background") {
                Toggle("Keep syncing when Lush is closed", isOn: $backgroundSync)
                    .onChange(of: backgroundSync) { _, enabled in
                        HelperControl.setEnabled(enabled)
                        if !enabled { backgroundMenuBar = false }
                    }
                Toggle("Show menu bar item when Lush is closed", isOn: $backgroundMenuBar)
                    .onChange(of: backgroundMenuBar) { _, shown in
                        LushShared.helperShowsMenuBar = shown
                    }
                    .disabled(!backgroundSync)
                Text("A small helper keeps your notes syncing after you quit Lush. It hands the core back the moment Lush opens again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #else
            Section("Background") {
                Text("Lush syncs in the background when iOS grants it time — more often the more you use the app. Background App Refresh must be on in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif
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
                            .uiFont(.caption)
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
    @Environment(ContextTracker.self) private var contextTracker
    @State private var fontSize = EditorSettings.bodySize
    @State private var limitWidth = EditorSettings.maxNoteWidth > 0
    @State private var maxWidth = EditorSettings.maxNoteWidth > 0 ? EditorSettings.maxNoteWidth : 700
    @State private var autoInsertLogline = EditorSettings.autoInsertLogline
    @State private var places = SavedPlaces.all
    @State private var placeName = ""
    @State private var contactPickerPresented = false
    @State private var mapPickerPresented = false
    @State private var importingMine = false
    @State private var importStatus: String?
    @AppStorage(NotesModel.importAsNotesKey) private var importTextFilesAsNotes = true
    @AppStorage(Agenda.dayInIconKey) private var calendarIconShowsDay = false

    var body: some View {
        Form {
            FontSettingsSections()
            Section("Base Size") {
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
            Section("Width") {
                Toggle("Limit note width", isOn: $limitWidth)
                    .onChange(of: limitWidth) {
                        EditorSettings.setMaxNoteWidth(limitWidth ? maxWidth : 0)
                    }
                if limitWidth {
                    HStack {
                        Text("Maximum")
                        Slider(value: $maxWidth, in: 320...1200, step: 20)
                            .onChange(of: maxWidth) {
                                EditorSettings.setMaxNoteWidth(maxWidth)
                            }
                        Text("\(Int(maxWidth))pt")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Calendar") {
                Toggle("Show today's date in the calendar icon", isOn: $calendarIconShowsDay)
            }
            Section("Import") {
                Picker("Markdown, text and RTF files", selection: $importTextFilesAsNotes) {
                    Text("Become Lush notes").tag(true)
                    Text("Stay as files").tag(false)
                }
                Text("Applies to the share extension and shortcuts. Dragging a file in asks each time.")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Add logline when context changes", isOn: $autoInsertLogline)
                    .onChange(of: autoInsertLogline) {
                        EditorSettings.setAutoInsertLogline(autoInsertLogline)
                    }
                ForEach($places) { $place in
                    HStack {
                        Image(systemName: "mappin.and.ellipse")
                            .foregroundStyle(.secondary)
                        TextField("Name", text: $place.name)
                            .textFieldStyle(.plain)
                            .onSubmit { savePlaces() }
                        Spacer()
                        Button("Remove") {
                            places.removeAll { $0.id == place.id }
                            savePlaces()
                        }
                    }
                }
                HStack {
                    TextField("Name", text: $placeName)
                    Button("Add Here") { addPlace() }
                        .disabled(placeName.trimmingCharacters(in: .whitespaces).isEmpty
                            || contextTracker.snapshot.latitude == nil)
                }
                HStack {
                    #if os(macOS)
                    Button("Import Home & Work") { importMyAddresses() }
                        .disabled(importingMine)
                    #endif
                    Button("From Contacts…") { contactPickerPresented = true }
                    Button("On a Map…") { mapPickerPresented = true }
                    if importingMine {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if let importStatus {
                    Text(importStatus)
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Logline")
            } footer: {
                Text("A logline near a saved place uses its name — \"Home, London, England\" instead of the street. Addresses from Contacts are looked up once; only the coordinates are kept.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Editor")
        .sheet(isPresented: $contactPickerPresented) {
            ContactPlacePicker { found in
                add(found)
                importStatus = found.isEmpty
                    ? "None of those addresses could be found on the map."
                    : "Added \(found.count) place\(found.count == 1 ? "" : "s") from Contacts."
            }
        }
        .sheet(isPresented: $mapPickerPresented) {
            MapPlacePicker(start: currentCoordinate) { place in
                add([place])
                importStatus = nil
            }
        }
    }

    private var currentCoordinate: CLLocationCoordinate2D? {
        let snap = contextTracker.snapshot
        guard let lat = snap.latitude, let lon = snap.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func addPlace() {
        guard let here = currentCoordinate else { return }
        add([SavedPlace(
            name: placeName.trimmingCharacters(in: .whitespaces),
            latitude: here.latitude,
            longitude: here.longitude
        )])
        placeName = ""
    }

    private func add(_ found: [SavedPlace]) {
        places.append(contentsOf: found)
        savePlaces()
    }

    private func savePlaces() {
        SavedPlaces.save(places)
        contextTracker.refreshPlaceName()
    }

    #if os(macOS)
    private func importMyAddresses() {
        importingMine = true
        importStatus = nil
        Task {
            guard await ContactPlaces.requestAccess() else {
                importingMine = false
                importStatus = "Lush has no access to your contacts. Turn it on in Permissions."
                return
            }
            let mine = (try? ContactPlaces.mine()) ?? []
            guard !mine.isEmpty else {
                importingMine = false
                importStatus = "Your own contact card has no home or work address."
                return
            }
            let existing = Set(places.map(\.name))
            let found = await ContactPlaces.geocode(mine.filter { !existing.contains($0.placeName) })
            add(found)
            importingMine = false
            importStatus = found.isEmpty
                ? "Nothing new to add."
                : "Added \(found.map(\.name).joined(separator: " and "))."
        }
    }
    #endif
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
            Section {
                if let url = model.effectiveQuickNoteUrl {
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
        }
        .formStyle(.grouped)
        .navigationTitle("Patchwork")
    }
}


struct FocusSettingsPane: View {
    @Environment(NotesModel.self) private var model

    private var focus: FocusModes { model.focus }

    var body: some View {
        Form {
            Section {
                if let state = focus.state {
                    if state.shownFolderUrls.isEmpty {
                        LabeledContent("Folders", value: "All")
                    } else {
                        LabeledContent("Folders") {
                            VStack(alignment: .trailing, spacing: 2) {
                                ForEach(state.shownFolderUrls, id: \.self) { url in
                                    Text(model.node(for: url)?.displayName ?? "Folder")
                                }
                            }
                        }
                    }
                    LabeledContent("Inbox", value: name(state.inboxUrl) ?? "Default")
                    LabeledContent("Quick Note", value: name(state.quickNoteUrl) ?? "Default")
                } else {
                    Text("No Focus is filtering Lush.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Current Focus")
            } footer: {
                Text("Set this up under \(Self.focusSettingsPath) › Focus Filters › Lush: pick the folders to show and, if you want, a different inbox and Quick Note. It applies while that Focus is on and stops when it ends. Anything left unset keeps the normal setting, and hidden folders stay searchable.")
            }
            Section {
                switch focus.focusStatusAuthorization {
                case .authorized:
                    Label("Lush follows Focus changes as they happen.", systemImage: "checkmark.circle")
                case .denied, .restricted:
                    Text("Focus access is off, so a Focus that starts or ends while Lush is in the background is picked up next time Lush comes to the front.")
                        .foregroundStyle(.secondary)
                default:
                    Button("Allow Focus Access") {
                        Task { await focus.requestFocusStatusAuthorization() }
                    }
                }
            } header: {
                Text("Focus Access")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Focus")
    }

    private static var focusSettingsPath: String {
        #if os(macOS)
        "System Settings › Focus › a Focus"
        #else
        "Settings › Focus › a Focus"
        #endif
    }

    private func name(_ url: String?) -> String? {
        guard let url else { return nil }
        return model.node(for: url)?.displayName ?? "Untitled"
    }
}
