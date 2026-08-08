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
            Tab("Machine Learning", systemImage: "sparkles.tv") {
                MachineLearningSettingsPane()
            }
            Tab("Agents", systemImage: "terminal") {
                AgentSettingsPane()
            }
            Tab("Patchwork", systemImage: "shippingbox") {
                PatchworkSettingsPane()
            }
            Tab("Import", systemImage: "square.and.arrow.down") {
                ImportSettingsPane()
            }
        }
        .frame(width: 620, height: 620)
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
                MachineLearningSettingsPane()
            } label: {
                Label("Machine Learning", systemImage: "sparkles.tv")
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

#if os(macOS)
struct AgentSettingsPane: View {
    @State private var status: String?

    var body: some View {
        Form {
            Section("Lush Documents") {
                Text("Local agents can search, read, create, and edit documents while Lush is running.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Install for Claude") { install(in: ".claude") }
                    Button("Install for Codex") { install(in: ".codex") }
                }
                if let status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Connection") {
                Text("~/Library/Application Support/Lush/agent.json")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text("The bearer token changes whenever Lush starts and is readable only by this account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Agents")
    }

    private func install(in agentDirectory: String) {
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
            let home = FileManager.default.homeDirectoryForCurrentUser
            let skills = home.appendingPathComponent(agentDirectory, isDirectory: true)
                .appendingPathComponent("skills", isDirectory: true)
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
            status = "Installed lush-docs for \(agentDirectory == ".claude" ? "Claude" : "Codex")."
        } catch {
            status = error.localizedDescription
        }
    }
}
#endif

struct MachineLearningSettingsPane: View {
    @State private var selectedOperation: LocalModelOperation = .attachmentSummary

    var body: some View {
        VStack(spacing: 0) {
            Picker("Operation", selection: $selectedOperation) {
                ForEach(LocalModelOperation.allCases) { operation in
                    Label(operation.shortLabel, systemImage: operation.symbolName)
                        .tag(operation)
                }
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top])

            HStack(spacing: 8) {
                Image(systemName: selectedOperation.symbolName)
                    .foregroundStyle(.tint)
                Text(selectedOperation.label)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("Configured separately")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal)
            .padding(.top, 10)

            Form {
                LocalModelOperationSettingsView(operation: selectedOperation)
                    .id(selectedOperation)
            }
            .formStyle(.grouped)
        }
        .navigationTitle("Machine Learning")
    }
}

struct LocalModelOperationSettingsView: View {
    let operation: LocalModelOperation
    @State private var backend: LocalModelBackend
    @State private var config: RemoteModelConfig
    @State private var cloudConfig: CloudModelConfig
    @State private var apiKey = ""
    @State private var generationSettings: LocalGenerationSettings
    @State private var systemPrompt: String
    @State private var presetFilter = ""
    @State private var status: String?
    @State private var statusIsError = false
    @State private var credentialStored: Bool
    @State private var isSigningIn = false
    @State private var promptExpanded = false
    @State private var modelPickerPresented = false
    @State private var modelFilter = ""
    @State private var openRouterModels: [OpenRouterModel] = []
    @State private var modelCatalogError: String?
    @State private var isLoadingModels = false

    init(operation: LocalModelOperation) {
        self.operation = operation
        let backend = LocalModelSettings.backend(for: operation)
        _backend = State(initialValue: backend)
        _config = State(initialValue: LocalModelSettings.remoteModelConfig(for: operation))
        _cloudConfig = State(initialValue: LocalModelSettings.cloudModelConfig(for: operation, backend: backend))
        _generationSettings = State(initialValue: LocalModelSettings.generationSettings(for: operation))
        _systemPrompt = State(initialValue: LocalModelSettings.systemPrompt(for: operation))
        _credentialStored = State(initialValue: !ModelCredentialStore.apiKey(for: backend).isEmpty)
    }

    var body: some View {
        Section {
            Picker("Provider", selection: $backend) {
                ForEach(LocalModelBackend.allCases) { backend in
                    Text(backend.label).tag(backend)
                }
            }
            .onChange(of: backend) {
                LocalModelSettings.setBackend(backend, for: operation)
                cloudConfig = LocalModelSettings.cloudModelConfig(for: operation, backend: backend)
                apiKey = ""
                credentialStored = !ModelCredentialStore.apiKey(for: backend).isEmpty
                status = nil
                statusIsError = false
            }

            if backend.isCloud {
                LabeledContent("Connection") {
                    Label(
                        connectionLabel,
                        systemImage: credentialStored ? "checkmark.circle.fill" : "circle.dashed"
                    )
                    .foregroundStyle(credentialStored ? Color.green : Color.secondary)
                }
            }
        } header: {
            Text("Provider")
        } footer: {
            Text(providerDescription)
        }

        if backend == .mlx {
            Section("Local model") {
                DisclosureGroup("Suggested models") {
                    TextField("Filter suggested models", text: $presetFilter)
                        .autocorrectionDisabled()
                    let presets = filteredPresets
                    if presets.isEmpty {
                        Text("No matching suggestions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(presets) { preset in
                            Button {
                                config = preset.config
                                status = preset.note
                                statusIsError = false
                                LocalModelSettings.setRemoteModelConfig(config, for: operation)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.label)
                                    Text(preset.note)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                TextField("Repository", text: $config.repo, prompt: Text("owner/model"))
                    .autocorrectionDisabled()
                    .onChange(of: config.repo) { saveConfig() }
                TextField("Revision", text: $config.revision, prompt: Text("main"))
                    .autocorrectionDisabled()
                    .onChange(of: config.revision) { saveConfig() }
                if let status {
                    statusMessage(status)
                }
            }
        }

        if backend.isCloud {
            Section("Model") {
                HStack {
                    TextField("Model ID", text: $cloudConfig.model, prompt: Text(modelPlaceholder))
                        .autocorrectionDisabled()
                        .onChange(of: cloudConfig.model) { saveCloudConfig() }
                    if backend == .openRouter {
                        Button {
                            modelPickerPresented.toggle()
                            if openRouterModels.isEmpty {
                                refreshModels()
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                        }
                        .help("Choose an OpenRouter model")
                        .popover(isPresented: $modelPickerPresented, arrowEdge: .trailing) {
                            openRouterModelPicker
                        }
                    }
                }

                if backend == .compatible {
                    TextField(
                        "Endpoint",
                        text: $cloudConfig.endpoint,
                        prompt: Text("https://provider.example/v1/chat/completions")
                    )
                    .autocorrectionDisabled()
                    .onChange(of: cloudConfig.endpoint) { saveCloudConfig() }
                }
            }

            Section {
                if backend == .openRouter {
                    Button {
                        signInWithOpenRouter()
                    } label: {
                        HStack {
                            if isSigningIn {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "person.crop.circle.badge.checkmark")
                            }
                            Text(isSigningIn ? "Waiting for OpenRouter…" : "Connect OpenRouter")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSigningIn)
                }

                HStack {
                    SecureField(
                        credentialStored ? "Enter a replacement key" : backend.credentialLabel,
                        text: $apiKey
                    )
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    Button(credentialStored ? "Replace" : "Save") { saveAPIKey() }
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if credentialStored {
                    Button("Disconnect", role: .destructive) { removeAPIKey() }
                }

                if let status {
                    statusMessage(status)
                }
            } header: {
                Text("Credentials")
            } footer: {
                Text("Stored in Keychain and shared by every task using this provider.")
            }
        }

        Section("Generation") {
            LabeledContent("Temperature") {
                HStack(spacing: 12) {
                    Slider(value: $generationSettings.temperature, in: 0...1, step: 0.05)
                        .frame(minWidth: 180)
                        .onChange(of: generationSettings.temperature) {
                            saveGenerationSettings()
                        }
                    Text(generationSettings.temperature.formatted(.number.precision(.fractionLength(2))))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Stepper(
                "Response limit: \(generationSettings.maximumResponseTokens) tokens",
                value: $generationSettings.maximumResponseTokens,
                in: 64...4096,
                step: 64
            )
            .onChange(of: generationSettings.maximumResponseTokens) {
                saveGenerationSettings()
            }
        }

        Section {
            DisclosureGroup("System prompt", isExpanded: $promptExpanded) {
                TextEditor(text: $systemPrompt)
                    .font(.caption.monospaced())
                    .frame(minHeight: 140)
                    .onChange(of: systemPrompt) {
                        saveSystemPrompt()
                    }
                HStack {
                    Spacer()
                    Button("Restore Default") {
                        systemPrompt = operation.defaultSystemPrompt
                        LocalModelSettings.resetSystemPrompt(for: operation)
                    }
                }
            }
        } footer: {
            Text("Advanced instructions sent with every request for this task.")
        }
    }

    private var openRouterModelPicker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter models", text: $modelFilter)
                    .textFieldStyle(.plain)
                Button {
                    refreshModels()
                } label: {
                    if isLoadingModels {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .disabled(isLoadingModels)
                .help("Refresh models")
            }
            .padding(12)

            Divider()

            if let modelCatalogError, openRouterModels.isEmpty {
                ContentUnavailableView(
                    "Models unavailable",
                    systemImage: "wifi.exclamationmark",
                    description: Text(modelCatalogError)
                )
            } else if isLoadingModels && openRouterModels.isEmpty {
                ProgressView("Loading models…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredOpenRouterModels.isEmpty {
                ContentUnavailableView.search(text: modelFilter)
            } else {
                List(filteredOpenRouterModels) { model in
                    Button {
                        cloudConfig.model = model.id
                        saveCloudConfig()
                        modelPickerPresented = false
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(model.name)
                                    .lineLimit(1)
                                Spacer()
                                if cloudConfig.model == model.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            Text(model.id)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if let contextLength = model.contextLength {
                                Text("\(contextLength.formatted()) context")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }

            if let modelCatalogError, !openRouterModels.isEmpty {
                Divider()
                Label(modelCatalogError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(10)
            }
        }
        .frame(width: 430, height: 430)
    }

    private var filteredOpenRouterModels: [OpenRouterModel] {
        let models = operation == .imageCaption
            ? openRouterModels.filter { $0.architecture?.inputModalities?.contains("image") != false }
            : openRouterModels
        let query = modelFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return models }
        return models.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
                || ($0.description?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func refreshModels() {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        modelCatalogError = nil
        Task {
            do {
                openRouterModels = try await OpenRouterModelCatalog.fetch()
            } catch {
                modelCatalogError = error.localizedDescription
            }
            isLoadingModels = false
        }
    }

    @ViewBuilder
    private func statusMessage(_ message: String) -> some View {
        Label(message, systemImage: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(statusIsError ? Color.red : Color.secondary)
    }

    private var connectionLabel: String {
        if isSigningIn { return "Connecting…" }
        return credentialStored ? "Connected" : "Not connected"
    }

    private var modelPlaceholder: String {
        switch backend {
        case .openRouter: "openrouter/auto"
        case .openAI: "gpt-5.6"
        case .anthropic: "claude-sonnet-4"
        case .compatible: "provider/model"
        case .appleIntelligence, .mlx: ""
        }
    }

    private var providerDescription: String {
        switch backend {
        case .appleIntelligence:
            "Runs on this Mac using Apple Intelligence. No account or API key required."
        case .mlx:
            "Runs an MLX model locally. Models download from Hugging Face when first used."
        case .openRouter:
            "One OpenRouter connection provides Claude, OpenAI, Gemini, and other hosted models."
        case .openAI:
            "Uses OpenAI developer API billing. A ChatGPT subscription does not include API usage."
        case .anthropic:
            "Uses Anthropic developer API billing. A Claude subscription does not include API usage."
        case .compatible:
            "Uses an OpenAI-compatible chat-completions endpoint."
        }
    }

    private var filteredPresets: [HuggingFaceModelPreset] {
        let presets = HuggingFaceModelPreset.presets(for: operation)
        let query = presetFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return presets }
        return presets.filter { preset in
            preset.label.lowercased().contains(query)
                || preset.note.lowercased().contains(query)
                || preset.config.repo.lowercased().contains(query)
                || preset.config.filename.lowercased().contains(query)
        }
    }

    private func saveConfig() {
        LocalModelSettings.setRemoteModelConfig(config, for: operation)
    }

    private func saveGenerationSettings() {
        LocalModelSettings.setGenerationSettings(generationSettings, for: operation)
    }

    private func saveCloudConfig() {
        LocalModelSettings.setCloudModelConfig(cloudConfig, for: operation, backend: backend)
    }

    private func saveAPIKey() {
        do {
            try ModelCredentialStore.setAPIKey(apiKey, for: backend)
            apiKey = ""
            credentialStored = true
            status = "Connected with API key."
            statusIsError = false
        } catch {
            status = error.localizedDescription
            statusIsError = true
        }
    }

    private func removeAPIKey() {
        do {
            try ModelCredentialStore.setAPIKey("", for: backend)
            apiKey = ""
            credentialStored = false
            status = "Disconnected."
            statusIsError = false
        } catch {
            status = error.localizedDescription
            statusIsError = true
        }
    }

    private func signInWithOpenRouter() {
        isSigningIn = true
        status = nil
        statusIsError = false
        Task {
            do {
                let key = try await OpenRouterAuthentication.shared.signIn()
                try ModelCredentialStore.setAPIKey(key, for: .openRouter)
                apiKey = ""
                credentialStored = true
                status = "OpenRouter connected."
            } catch {
                status = error.localizedDescription
                statusIsError = true
            }
            isSigningIn = false
        }
    }

    private func saveSystemPrompt() {
        LocalModelSettings.setSystemPrompt(systemPrompt, for: operation)
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
    @State private var sansFamily = EditorSettings.family(for: "sans")
    @State private var serifFamily = EditorSettings.family(for: "serif")
    @State private var monoFamily = EditorSettings.family(for: "mono")
    @State private var handFamily = EditorSettings.family(for: "hand")
    @State private var fontSize = EditorSettings.bodySize
    @State private var autoInsertLogline = EditorSettings.autoInsertLogline
    @State private var typewriterMode = EditorSettings.typewriterMode
    @State private var minimapVisible = EditorSettings.minimapVisible
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
                familyPicker("Sans", selection: $sansFamily, key: "sans")
                familyPicker("Serif", selection: $serifFamily, key: "serif")
                familyPicker("Mono", selection: $monoFamily, key: "mono")
                familyPicker("Hand", selection: $handFamily, key: "hand")
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
                Toggle("Typewriter mode (center caret, dim other paragraphs)", isOn: $typewriterMode)
                    .onChange(of: typewriterMode) {
                        EditorSettings.setTypewriterMode(typewriterMode)
                    }
                Toggle("Show minimap", isOn: $minimapVisible)
                    .onChange(of: minimapVisible) {
                        EditorSettings.setMinimapVisible(minimapVisible)
                    }
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

    private func familyPicker(_ title: String, selection: Binding<String>, key: String) -> some View {
        Picker(title, selection: selection) {
            Text("System Default").tag(EditorSettings.systemFontFamily)
            ForEach(EditorSettings.availableFontFamilies, id: \.self) { family in
                Text(family).tag(family)
            }
        }
        .onChange(of: selection.wrappedValue) {
            EditorSettings.setFamily(selection.wrappedValue, for: key)
        }
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
