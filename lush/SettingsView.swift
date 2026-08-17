import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Intents
import CoreLocation

struct SettingsView: View {
    @ScaledMetric(relativeTo: .body) private var markSize: CGFloat = 32

    var body: some View {
        #if os(macOS)
        TabView {
            Tab {
                PatchworkSettingsPane()
            } label: {
                Label {
                    Text("Patchwork")
                } icon: {
                    // the tab bar sizes the icon itself, so the margin the mark
                    // lacks and an SF Symbol has is baked into the svg
                    Image("PatchworkMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                }
            }
            Tab("Editor", systemImage: "textformat") {
                EditorSettingsPane()
            }
            Tab("Machine Learning", systemImage: "sparkles.tv") {
                MachineLearningSettingsPane()
            }
            Tab("System", systemImage: "apple.logo") {
                SystemSettingsPane()
            }
        }
        .frame(width: 620, height: 620)
        #else
        List {
            NavigationLink {
                PatchworkSettingsPane()
            } label: {
                Label {
                    Text("Patchwork")
                } icon: {
                    Image("PatchworkMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: markSize, height: markSize)
                }
            }
            NavigationLink {
                EditorSettingsPane()
            } label: {
                Label("Editor", systemImage: "textformat")
            }
            NavigationLink {
                MachineLearningSettingsPane()
            } label: {
                Label("Machine Learning", systemImage: "sparkles.tv")
            }
            NavigationLink {
                SystemSettingsPane()
            } label: {
                Label("System", systemImage: "apple.logo")
            }
        }
        .navigationTitle("Settings")
        #endif
    }
}

/// A pane split into segments, so related settings stay together without
/// growing the tab bar.
struct SettingsSubtabs<Content: View>: View {
    let titles: [String]
    let content: (String) -> Content
    @State private var selection: String

    init(_ titles: [String], @ViewBuilder content: @escaping (String) -> Content) {
        self.titles = titles
        self.content = content
        _selection = State(initialValue: titles[0])
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $selection) {
                ForEach(titles, id: \.self) { title in
                    Text(title).tag(title)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 12)
            content(selection)
        }
        .background(Color(PColor.pGroupedBackground))
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
    @State private var peerError: String?
    @State private var addingPeer = false
    @State private var showingClearConfirm = false
    @State private var compacting = false
    @State private var compactionResult: String?
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
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            CopyButton(value: httpUrl)
                        }
                    }
                }
            }
            #if !os(macOS)
            Section("Background") {
                Text("Lush syncs in the background when iOS grants it time — more often the more you use the app. Background App Refresh must be on in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif
            Section {
                Toggle("Sync directly with peers", isOn: Binding(
                    get: { model.irohEnabled },
                    set: { model.setIrohEnabled($0) }
                ))
                .disabled(model.changingIroh || model.core == nil)
                if let irohError = model.irohError {
                    Text(irohError)
                        .uiFont(.caption)
                        .foregroundStyle(.red)
                }
                if let code = model.core?.irohFriendCode() {
                    HStack {
                        DocumentLabel(title: "This device", url: code, symbol: "laptopcomputer")
                        Spacer()
                        CopyButton(value: code)
                    }
                    ForEach(model.irohPeers.filter(\.added), id: \.nodeId) { peer in
                        HStack {
                            DocumentLabel(title: shortNodeId(peer.nodeId), url: peer.code, symbol: "person.crop.circle")
                            Spacer()
                            Button("Remove", role: .destructive) {
                                model.core?.forgetIrohPeer(nodeId: peer.nodeId)
                                model.refreshPeers()
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    ForEach(model.irohPeers.filter { !$0.added }, id: \.nodeId) { peer in
                        HStack {
                            DocumentLabel(title: shortNodeId(peer.nodeId), url: "wants to sync with you", symbol: "person.crop.circle.badge.questionmark")
                            Spacer()
                            Button("Add") { add(peer.code) }
                                .buttonStyle(.borderless)
                            Button("Ignore") {
                                model.core?.forgetIrohPeer(nodeId: peer.nodeId)
                                model.refreshPeers()
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("Add Peer…") { addingPeer = true }
                    if let peerError {
                        Text(peerError)
                            .uiFont(.caption)
                            .foregroundStyle(.red)
                    }
                } else if model.irohEnabled {
                    Text("Starting the iroh endpoint…")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Peers (iroh)")
            } footer: {
                Text("Off until you turn it on — binding the endpoint reaches for a relay, and a slow one would hold up launch. Once it's on, share this device's friend code and add a friend's; the rust subduction cores then sync directly via iroh. The code is two public keys — where to dial, and who should answer.")
            }
            Section {
                Button("Force Resync") {
                    model.forceSync()
                }
                Button(compacting ? "Reclaiming…" : "Reclaim Loose Commits") {
                    compacting = true
                    Task {
                        compactionResult = await model.reclaimLooseCommits()
                        compacting = false
                    }
                }
                .disabled(compacting)
                if let compactionResult {
                    LabeledContent("Last Pass", value: compactionResult)
                }
                Button("Clear Local Storage…", role: .destructive) {
                    showingClearConfirm = true
                }
                .confirmationDialog(
                    "Clear all locally cached data and quit?",
                    isPresented: $showingClearConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Clear, Keep Identity") {
                        model.clearStorage(keepingIdentity: true)
                    }
                    Button("Clear Everything", role: .destructive) {
                        model.clearStorage()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The app will quit and re-sync everything from the server on next launch. Clearing everything also erases this device's keys and peers — your friend code changes, and anyone holding the old one can't reach you.")
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Reclaim Loose Commits drops commits that a fragment already covers, this should happen automatically but i am not good at computer programming. Force Resync re-fetches all notebooks from the server. Clear Local Storage deletes all cached data and quits — the app will re-sync from scratch on next launch. Keeping your identity spares the two keys and the peer list, so your friend codes still works. You'll still be logged out tho")
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
        .task { model.refreshPeers() }
        .sheet(isPresented: $addingPeer) {
            AddItemSheet(
                title: "Add Peer",
                placeholder: "friend code",
                prompt: "Paste a friend's code to sync with them directly."
            ) { code in
                add(code)
            }
        }
    }

    private func add(_ code: String) {
        do {
            try model.core?.addIrohPeer(code: code)
            peerError = nil
        } catch {
            peerError = error.localizedDescription
        }
        model.refreshPeers()
    }

    private func shortNodeId(_ nodeId: String) -> String {
        nodeId.count > 16 ? "\(nodeId.prefix(8))…\(nodeId.suffix(4))" : nodeId
    }

    private func folderName(_ url: String) -> String {
        model.node(for: url)?.displayName ?? "Notes"
    }
}

struct EditorSettingsPane: View {
    var body: some View {
        SettingsSubtabs(sections) { section in
            switch section {
            case "Page": PageSettingsPane()
            case "Logline": LoglineSettingsPane()
            default: FontsSettingsPane()
            }
        }
        .navigationTitle("Editor")
    }

    private var sections: [String] {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .pad else { return ["Fonts", "Logline"] }
        #endif
        return ["Fonts", "Page", "Logline"]
    }
}

struct CalendarSettingsPane: View {
    @AppStorage(Agenda.dayInIconKey) private var calendarIconShowsDay = false

    var body: some View {
        Form {
            Section {
                Toggle("Show today's date in the calendar icon", isOn: $calendarIconShowsDay)
            } footer: {
                Text("Events and reminders for the next two weeks show in the Calendar view. Double-click one to write a note about it.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Calendar")
    }
}

struct FontsSettingsPane: View {
    @State private var textSize = EditorSettings.textSize

    var body: some View {
        Form {
            Section("Text Size") {
                Picker("Text Size", selection: $textSize) {
                    ForEach(EditorTextSize.allCases) { size in
                        Text(size.label).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: textSize) {
                    EditorSettings.setTextSize(textSize)
                }
            }
            FontSettingsSections()
        }
        .formStyle(.grouped)
        .navigationTitle("Fonts")
    }
}

struct PageSettingsPane: View {
    @AppStorage(EditorSettings.minimapKey) private var minimapVisible = false
    @State private var limitWidth = EditorSettings.maxNoteCharacters > 0
    @State private var characters = EditorSettings.maxNoteCharacters > 0
        ? EditorSettings.maxNoteCharacters
        : 72

    var body: some View {
        Form {
            Section {
                Toggle("Limit note width", isOn: $limitWidth)
                    .onChange(of: limitWidth) {
                        EditorSettings.setMaxNoteCharacters(limitWidth ? characters : 0)
                    }
                if limitWidth {
                    Stepper(value: $characters, in: 20...160, step: 4) {
                        LabeledContent("Measure", value: "\(characters) characters")
                    }
                    .onChange(of: characters) {
                        EditorSettings.setMaxNoteCharacters(characters)
                    }
                }
            } header: {
                Text("Width")
            } footer: {
                Text("A note stops growing at the measure and centres itself. The measure is in characters of the body font, so it follows the base size.")
            }

            Section {
                Toggle("Show minimap", isOn: Binding(
                    get: { minimapVisible },
                    set: { EditorSettings.setMinimapVisible($0) }
                ))
            } header: {
                Text("Minimap")
            } footer: {
                Text("A scaled outline of the note down the right edge. Click or drag it to jump.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Page")
    }
}

struct SystemSettingsPane: View {
    var body: some View {
        SettingsSubtabs(["Permissions", "Import", "Calendar"]) { section in
            switch section {
            case "Import": ImportSettingsPane()
            case "Calendar": CalendarSettingsPane()
            default: PermissionsSettingsPane()
            }
        }
        .navigationTitle("System")
    }
}

struct ImportSettingsPane: View {
    @AppStorage(NotesModel.importAsNotesKey) private var importTextFilesAsNotes = true

    var body: some View {
        Form {
            Section {
                Picker("Markdown, text and RTF files", selection: $importTextFilesAsNotes) {
                    Text("Become Lush notes").tag(true)
                    Text("Stay as files").tag(false)
                }
            } header: {
                Text("Import")
            } footer: {
                Text("Applies to the share extension and shortcuts. Dragging a file in asks each time.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Import")
    }
}

struct LoglineSettingsPane: View {
    @Environment(ContextTracker.self) private var contextTracker
    @State private var autoInsertLogline = EditorSettings.autoInsertLogline
    @State private var placesEnabled = SavedPlaces.enabled
    @State private var weatherEnabled = ContextTracker.weatherEnabled
    @State private var places = SavedPlaces.all
    @State private var namingHere = false
    @State private var contactPickerPresented = false
    @State private var mapPickerPresented = false
    @State private var importingMine = false
    @State private var importStatus: String?

    var body: some View {
        Form {
            Section {
                Toggle("Add logline when context changes", isOn: $autoInsertLogline)
                    .onChange(of: autoInsertLogline) {
                        EditorSettings.setAutoInsertLogline(autoInsertLogline)
                    }
            }
            Section {
                Toggle("Include Location in Loglines", isOn: $placesEnabled)
                    .onChange(of: placesEnabled) {
                        contextTracker.setPlacesEnabled(placesEnabled)
                    }
                Toggle("Include Weather in Loglines", isOn: $weatherEnabled)
                    .onChange(of: weatherEnabled) {
                        contextTracker.setWeatherEnabled(weatherEnabled)
                    }
                if placesEnabled {
                    ForEach($places) { $place in
                        HStack {
                            Label {
                                TextField("Name", text: $place.name)
                                    .textFieldStyle(.plain)
                                    .onSubmit { savePlaces() }
                            } icon: {
                                Image(systemName: "mappin.and.ellipse")
                                    .foregroundStyle(.secondary)
                            }
                            RowMenu {
                                Button("Remove", role: .destructive) {
                                    places.removeAll { $0.id == place.id }
                                    savePlaces()
                                }
                            }
                        }
                    }
                    Menu("Add Place…") {
                        Button("Where I Am Now…") { namingHere = true }
                            .disabled(currentCoordinate == nil)
                        Button("On a Map…") { mapPickerPresented = true }
                        Button("From Contacts…") { contactPickerPresented = true }
                        #if os(macOS)
                        Button("Home & Work from My Card") { importMyAddresses() }
                            .disabled(importingMine)
                        #endif
                    }
                    .fixedSize()
                    if importingMine {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Looking up addresses…")
                                .uiFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let importStatus {
                        Text(importStatus)
                            .uiFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Location & Weather")
            } footer: {
                Text("Enabling Location or Weather asks for location access when context is next collected. A logline near a saved place uses its name — \"Home, London, England\" instead of the street. Addresses from Contacts are looked up once; only the coordinates are kept.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Logline")
        .task {
            // the context is only collected when a logline asks for it, and
            // this pane is asking: "Where I Am Now" needs a fix to offer
            guard ContextTracker.stampsContext else { return }
            await contextTracker.refresh()
        }
        .sheet(isPresented: $namingHere) {
            AddItemSheet(
                title: "Add Place",
                placeholder: "Name",
                prompt: "Saves where you are now under a name.",
                monospaced: false,
                add: addPlace
            )
        }
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

    private func addPlace(_ name: String) {
        guard let here = currentCoordinate else { return }
        add([SavedPlace(name: name, latitude: here.latitude, longitude: here.longitude)])
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
    var body: some View {
        SettingsSubtabs(["Account", "Packages", "Sync"]) { section in
            switch section {
            case "Packages": PackagesSettingsPane()
            case "Sync": SyncSettingsPane()
            default: AccountSettingsPane()
            }
        }
        .navigationTitle("Patchwork")
    }
}

/// A document url under its name, sized like a subtitle rather than a wall of
/// monospace.
struct DocumentLabel: View {
    var title: String?
    let url: String
    let symbol: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                if let title {
                    Text(title)
                }
                Text(url)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
        }
    }
}

struct CopyButton: View {
    let value: String
    @State private var copied = false

    var body: some View {
        Button {
            Clipboard.copy(value)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

/// Adding to a list happens in a sheet, so a list row is always a thing you
/// have, never a place to type.
struct AddItemSheet: View {
    let title: String
    let placeholder: String
    var prompt: String?
    var monospaced = true
    var secure = false
    var accepts: (String) -> Bool = { !$0.isEmpty }
    let add: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            if let prompt {
                Text(prompt)
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
            }
            field
                .textFieldStyle(.roundedBorder)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textContentType(secure ? .password : nil)
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!accepts(trimmed))
            }
        }
        #if os(macOS)
        .padding(20)
        .frame(width: 440)
        #else
        .padding(28)
        #endif
    }

    @ViewBuilder private var field: some View {
        if secure {
            SecureField(placeholder, text: $text)
        } else {
            TextField(placeholder, text: $text)
        }
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard accepts(trimmed) else { return }
        add(trimmed)
        dismiss()
    }
}

struct RowMenu<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
    }
}

struct AccountSettingsPane: View {
    @Environment(NotesModel.self) private var model
    @State private var loggingInSheet = false
    @State private var addingFolder = false

    private var loggingIn: Bool { model.loggingInUrl != nil }

    var body: some View {
        Form {
            Section {
                ForEach(model.accountUrls, id: \.self) { url in
                    accountRow(url)
                }
                Button(loggingIn ? "Logging In…" : "Add Account…") { loggingInSheet = true }
                    .disabled(loggingIn)
                if let error = model.loginError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Log in with a Patchwork account doc to sync your notebooks and settings")
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
            Section {
                ForEach(model.rootFolderUrls, id: \.self) { url in
                    HStack {
                        Label(
                            model.node(for: url)?.displayName ?? "Notebook",
                            systemImage: model.inboxUrl == url ? "tray" : "folder"
                        )
                        Spacer()
                        if model.inboxUrl == url {
                            Text("Inbox")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                        RowMenu {
                            if model.loggedIn, model.inboxUrl != url {
                                Button("Make Inbox") { model.setInbox(url) }
                            }
                            Button("Copy URL") { Clipboard.copy(url) }
                            Button("Remove", role: .destructive) {
                                model.removeRootFolder(url)
                            }
                            .disabled(model.rootFolderUrls.count == 1)
                        }
                    }
                }
                Button("Add Notebook…") { addingFolder = true }
            } header: {
                Text("Notebooks")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Account")
        .sheet(isPresented: $loggingInSheet) {
            AddItemSheet(
                title: "Log In",
                placeholder: "account:name/… or automerge:…",
                prompt: "Paste your Patchwork account url.",
                secure: true,
                accepts: { NotesModel.normalizedAccountUrl($0) != nil },
                add: logIn
            )
        }
        .sheet(isPresented: $addingFolder) {
            AddItemSheet(
                title: "Add Notebook",
                placeholder: "automerge:…",
                prompt: "Paste a Patchwork folder url."
            ) { url in
                Task { await model.addRootFolder(url) }
            }
        }
    }

    @ViewBuilder private func accountRow(_ url: String) -> some View {
        let active = model.accountUrl == url
        HStack(spacing: 10) {
            if active, let data = model.contactAvatarData, let image = PImage(data: data) {
                Image(pImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.largeTitle)
                    .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.accountName(url) ?? "Account")
                Text(url)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if active {
                Button("Log Out") { model.logOut() }
            } else {
                Button(model.loggingInUrl == url ? "Switching…" : "Switch") { logIn(url) }
                    .disabled(loggingIn)
            }
            RowMenu {
                Button("Copy Account URL") { Clipboard.copy(url) }
                Button("Forget", role: .destructive) { model.forgetAccount(url) }
            }
        }
    }

    private func logIn(_ url: String) {
        Task { _ = await model.logIn(accountUrl: url) }
    }
}

struct PackagesSettingsPane: View {
    @Environment(NotesModel.self) private var model
    @State private var adding = false

    private var moduleUrls: [String] { model.packageListUrls }

    var body: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("System")
                        Text("Built into Lush")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "shippingbox")
                        .foregroundStyle(.secondary)
                }
                if let url = model.accountModuleSettingsUrl {
                    HStack {
                        DocumentLabel(title: "User", url: url, symbol: "shippingbox")
                        Spacer()
                        RowMenu {
                            Button("Copy URL") { Clipboard.copy(url) }
                        }
                    }
                }
                ForEach(moduleUrls, id: \.self) { url in
                    HStack {
                        DocumentLabel(url: url, symbol: "shippingbox")
                        Spacer()
                        RowMenu {
                            Button("Copy URL") { Clipboard.copy(url) }
                            Button("Remove", role: .destructive) {
                                model.setPackageLists(moduleUrls.filter { $0 != url })
                            }
                        }
                    }
                }
                Button("Add Package List…") { adding = true }
            } header: {
                Text("Package Lists")
            } 
        }
        .formStyle(.grouped)
        .navigationTitle("Packages")
        .sheet(isPresented: $adding) {
            AddItemSheet(
                title: "Add Package List",
                placeholder: "automerge:…",
                prompt: "Paste the url of a package list doc.",
                accepts: { $0.hasPrefix("automerge:") && !moduleUrls.contains($0) }
            ) { url in
                model.setPackageLists(moduleUrls + [url])
            }
        }
    }
}

struct FocusSettingsSections: View {
    @Environment(NotesModel.self) private var model

    private var focus: FocusModes { model.focus }

    var body: some View {
        Group {
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
                Button("Open Focus Settings") { openFocusSettings() }
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
    }

    private static var focusSettingsPath: String {
        #if os(macOS)
        "System Settings › Focus › a Focus"
        #else
        "Settings › Focus › a Focus"
        #endif
    }

    private func openFocusSettings() {
        #if os(macOS)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
        #else
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }

    private func name(_ url: String?) -> String? {
        guard let url else { return nil }
        return model.node(for: url)?.displayName ?? "Untitled"
    }
}
