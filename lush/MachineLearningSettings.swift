import SwiftUI

/// Providers are set up once — credentials, endpoint, a default model. Tasks
/// then pick a provider, and only name a model when they want something other
/// than that provider's default.
struct MachineLearningSettingsPane: View {
    @Environment(NotesModel.self) private var model
    @State private var selectedOperation: LocalModelOperation = .attachmentSummary

    var body: some View {
        Form {
            Section {
                ForEach(LocalModelBackend.allCases) { backend in
                    DisclosureGroup {
                        ProviderSettingsView(backend: backend)
                    } label: {
                        ProviderRowLabel(backend: backend)
                    }
                }
            } header: {
                Text("Providers")
            } footer: {
                Text("Credentials are stored in Keychain on this device. Each task can use a different provider.")
            }

            Section {
                Picker("Task", selection: $selectedOperation) {
                    ForEach(LocalModelOperation.allCases) { operation in
                        Label(operation.shortLabel, systemImage: operation.symbolName)
                            .tag(operation)
                    }
                }
                .pickerStyle(.menu)

                LocalModelTaskSettingsView(operation: selectedOperation)
                    .id(selectedOperation)
            } header: {
                Text("Tasks")
            } footer: {
                Text("These defaults apply immediately. Chat and summary sheets can use another provider for an individual request.")
            }

            #if os(macOS)
            AgentSettingsSection()
            #endif

            Section {
                Button("Rebuild Semantic Search Index") { model.reindexAll() }
            } footer: {
                Text("Recreates local search data from your notes. Your notes are unchanged.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Machine Learning")
    }
}

private struct ProviderRowLabel: View {
    let backend: LocalModelBackend

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(backend.label)
                Text(location)
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if backend.needsAPIKey {
                Label(
                    connected ? "Connected" : "Not connected",
                    systemImage: connected ? "checkmark.circle.fill" : "circle.dashed"
                )
                    .labelStyle(.iconOnly)
                    .foregroundStyle(connected ? Color.green : Color.secondary)
            }
            Text(detail)
                .uiFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }

    private var connected: Bool { LocalModelSettings.isConnected(backend) }

    private var location: String {
        switch backend {
        case .appleIntelligence, .mlx: "On device"
        case .openRouter, .openAI, .anthropic: "Hosted service"
        case .compatible, .ollama: "Configured endpoint"
        }
    }

    private var detail: String {
        if backend.needsAPIKey { return connected ? "Connected" : "Not connected" }
        let model = LocalModelSettings.providerModel(for: backend)
        switch backend {
        case .appleIntelligence: return "Built in"
        case .mlx where !connected: return "Unavailable"
        case .mlx, .ollama: return model.isEmpty ? "Model required" : model
        case .openRouter, .openAI, .anthropic, .compatible: return model
        }
    }
}

struct ProviderSettingsView: View {
    let backend: LocalModelBackend

    @State private var defaultModel: String
    @State private var endpoint: String
    @State private var apiKey = ""
    @State private var credentialStored: Bool
    @State private var isSigningIn = false
    @State private var status: String?
    @State private var statusIsError = false
    @State private var endpointEdited = false

    init(backend: LocalModelBackend) {
        self.backend = backend
        _defaultModel = State(initialValue: LocalModelSettings.providerModel(for: backend))
        _endpoint = State(initialValue: LocalModelSettings.endpoint(for: backend))
        _credentialStored = State(initialValue: !ModelCredentialStore.apiKey(for: backend).isEmpty)
    }

    var body: some View {
        Text(backend.summary)
            .uiFont(.caption)
            .foregroundStyle(.secondary)

        Label(privacySummary, systemImage: backend.isOnDevice ? "lock.fill" : "network")
            .uiFont(.caption)
            .foregroundStyle(.secondary)

        if backend.usesEndpoint {
            LabeledContent("Default model") {
                HStack {
                    TextField("Default model", text: $defaultModel, prompt: Text(backend.defaultModel))
                        .labelsHidden()
                        .accessibilityLabel("Default model")
                        .autocorrectionDisabled()
                        .onChange(of: defaultModel) {
                            LocalModelSettings.setProviderModel(defaultModel, for: backend)
                        }
                    if backend == .openRouter {
                        OpenRouterModelButton(model: $defaultModel, imagesOnly: false)
                    }
                    if backend == .ollama {
                        OllamaModelButton(model: $defaultModel)
                    }
                }
            }

            if backend == .compatible || backend == .ollama {
                LabeledContent("Endpoint") {
                    TextField(
                        "Endpoint",
                        text: $endpoint,
                        prompt: Text(
                            backend == .ollama
                                ? backend.defaultEndpoint
                                : "https://provider.example/v1/chat/completions"
                        )
                    )
                    .labelsHidden()
                    .accessibilityLabel("Endpoint")
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .onChange(of: endpoint) {
                        endpointEdited = true
                        LocalModelSettings.setEndpoint(endpoint, for: backend)
                    }
                }
                if endpointEdited, let endpointValidationMessage {
                    Label(endpointValidationMessage, systemImage: "exclamationmark.triangle.fill")
                        .uiFont(.caption)
                        .foregroundStyle(.red)
                }
            }

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
                        Text(
                            isSigningIn
                                ? "Waiting for OpenRouter…"
                                : credentialStored ? "Reconnect OpenRouter" : "Connect OpenRouter"
                        )
                    }
                }
                .disabled(isSigningIn)
            }

            if backend.needsAPIKey {
                LabeledContent("API key") {
                    SecureField(
                        credentialStored ? "Enter a replacement key" : backend.credentialLabel,
                        text: $apiKey
                    )
                    .labelsHidden()
                    .accessibilityLabel("API key")
                    .textContentType(.password)
                    .autocorrectionDisabled()
                }
                Button(credentialStored ? "Replace API Key" : "Save API Key") { saveAPIKey() }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if credentialStored {
                    Button("Disconnect", role: .destructive) { removeAPIKey() }
                }
            }
        } else if backend == .mlx {
            LabeledContent("Default repository") {
                TextField("Default repository", text: $defaultModel, prompt: Text("owner/model"))
                    .labelsHidden()
                    .accessibilityLabel("Default repository")
                    .autocorrectionDisabled()
                    .onChange(of: defaultModel) {
                        LocalModelSettings.setProviderModel(defaultModel, for: backend)
                    }
            }
        }

        if let status {
            Label(status, systemImage: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .uiFont(.caption)
                .foregroundStyle(statusIsError ? Color.red : Color.secondary)
        }
    }

    private var privacySummary: String {
        switch backend {
        case .appleIntelligence:
            "Requests stay on this device."
        case .mlx:
            "Requests stay on this device. Model files download from Hugging Face when needed."
        case .ollama:
            "Task content is sent only to the configured Ollama endpoint."
        case .openRouter, .openAI, .anthropic, .compatible:
            "Task content is sent to this provider when you use it."
        }
    }

    private var endpointValidationMessage: String? {
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "Enter an endpoint." }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil
        else { return "Enter a valid HTTP or HTTPS URL." }
        return nil
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
}

struct LocalModelTaskSettingsView: View {
    let operation: LocalModelOperation

    @State private var backend: LocalModelBackend
    @State private var model: String
    @State private var mlxConfig: RemoteModelConfig
    @State private var generationSettings: LocalGenerationSettings
    @State private var systemPrompt: String
    @State private var presetFilter = ""
    @State private var advancedExpanded = false
    @State private var promptExpanded = false

    init(operation: LocalModelOperation) {
        self.operation = operation
        let backend = LocalModelSettings.backend(for: operation)
        _backend = State(initialValue: backend)
        _model = State(initialValue: LocalModelSettings.model(for: operation, backend: backend))
        _mlxConfig = State(initialValue: LocalModelSettings.remoteModelConfig(for: operation))
        _generationSettings = State(initialValue: LocalModelSettings.generationSettings(for: operation))
        _systemPrompt = State(initialValue: LocalModelSettings.systemPrompt(for: operation))
    }

    var body: some View {
        Text(operation.settingsDescription)
            .uiFont(.caption)
            .foregroundStyle(.secondary)

        Picker("Provider", selection: $backend) {
            ForEach(LocalModelBackend.allCases) { backend in
                Text(backend.label).tag(backend)
            }
        }
        .pickerStyle(.menu)
        .onChange(of: backend) {
            LocalModelSettings.setBackend(backend, for: operation)
            model = LocalModelSettings.model(for: operation, backend: backend)
        }

        Label(providerDisclosure, systemImage: backend.isOnDevice ? "lock.fill" : "network")
            .uiFont(.caption)
            .foregroundStyle(.secondary)

        if backend == .mlx {
            LabeledContent("Repository") {
                TextField("Repository", text: $mlxConfig.repo, prompt: Text(placeholderRepo))
                    .labelsHidden()
                    .accessibilityLabel("Repository")
                    .autocorrectionDisabled()
                    .onChange(of: mlxConfig.repo) {
                        LocalModelSettings.setRemoteModelConfig(mlxConfig, for: operation)
                    }
            }
            LabeledContent("Revision") {
                TextField("Revision", text: $mlxConfig.revision, prompt: Text("main"))
                    .labelsHidden()
                    .accessibilityLabel("Revision")
                    .autocorrectionDisabled()
                    .onChange(of: mlxConfig.revision) {
                        LocalModelSettings.setRemoteModelConfig(mlxConfig, for: operation)
                    }
            }
            DisclosureGroup("Suggested models") {
                TextField("Filter suggested models", text: $presetFilter)
                    .autocorrectionDisabled()
                if filteredPresets.isEmpty {
                    Text("No matching suggestions.")
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredPresets) { preset in
                        Button {
                            mlxConfig = preset.config
                            LocalModelSettings.setRemoteModelConfig(mlxConfig, for: operation)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.label)
                                Text(preset.note)
                                    .uiFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } else if backend.usesEndpoint {
            LabeledContent("Model") {
                HStack {
                    TextField(
                        "Model",
                        text: $model,
                        prompt: Text(LocalModelSettings.providerModel(for: backend))
                    )
                    .labelsHidden()
                    .accessibilityLabel("Model")
                    .autocorrectionDisabled()
                    .onChange(of: model) {
                        LocalModelSettings.setModel(model, for: operation, backend: backend)
                    }
                    if backend == .openRouter {
                        OpenRouterModelButton(model: $model, imagesOnly: operation == .imageCaption)
                    }
                    if backend == .ollama {
                        OllamaModelButton(model: $model)
                    }
                }
            }
        }

        DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Variation") {
                    Text(generationSettings.temperature.formatted(.number.precision(.fractionLength(2))))
                        .font(.body.monospacedDigit())
                }
                Slider(value: $generationSettings.temperature, in: 0...1, step: 0.05)
                    .accessibilityLabel("Variation")
                    .accessibilityValue(variationAccessibilityValue)
                    .onChange(of: generationSettings.temperature) {
                        LocalModelSettings.setGenerationSettings(generationSettings, for: operation)
                    }
                HStack {
                    Text("Consistent")
                    Spacer()
                    Text("Varied")
                }
                .uiFont(.caption)
                .foregroundStyle(.secondary)
                Text("Lower values make responses more repeatable.")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Response limit") {
                HStack(spacing: 8) {
                    Text("\(generationSettings.maximumResponseTokens) tokens")
                        .font(.body.monospacedDigit())
                    Stepper(
                        "Response limit",
                        value: $generationSettings.maximumResponseTokens,
                        in: 64...4096,
                        step: 64
                    )
                    .labelsHidden()
                }
            }
            .onChange(of: generationSettings.maximumResponseTokens) {
                LocalModelSettings.setGenerationSettings(generationSettings, for: operation)
            }

            DisclosureGroup("Instructions", isExpanded: $promptExpanded) {
                Text("Lush sends these instructions with every request for this task.")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $systemPrompt)
                    .font(.caption.monospaced())
                    .frame(minHeight: 140)
                    .accessibilityLabel("Instructions for \(operation.label)")
                    .onChange(of: systemPrompt) {
                        LocalModelSettings.setSystemPrompt(systemPrompt, for: operation)
                    }
                HStack {
                    Spacer()
                    Button("Restore Default") {
                        systemPrompt = operation.defaultSystemPrompt
                        LocalModelSettings.resetSystemPrompt(for: operation)
                    }
                    .disabled(systemPrompt == operation.defaultSystemPrompt)
                }
            }
        }
    }

    private var providerDisclosure: String {
        switch backend {
        case .appleIntelligence, .mlx:
            "This task stays on this device."
        case .ollama:
            "This task sends content to the configured Ollama endpoint."
        case .openRouter, .openAI, .anthropic, .compatible:
            "This task sends content to \(backend.label)."
        }
    }

    private var variationAccessibilityValue: String {
        switch generationSettings.temperature {
        case ..<0.34: "Low"
        case ..<0.67: "Medium"
        default: "High"
        }
    }

    private var placeholderRepo: String {
        let providerDefault = LocalModelSettings.providerModel(for: .mlx)
        return providerDefault.isEmpty ? "owner/model" : providerDefault
    }

    private var filteredPresets: [HuggingFaceModelPreset] {
        let presets = HuggingFaceModelPreset.presets(for: operation)
        let query = presetFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return presets }
        return presets.filter { preset in
            preset.label.lowercased().contains(query)
                || preset.note.lowercased().contains(query)
                || preset.config.repo.lowercased().contains(query)
        }
    }
}

struct OllamaModelButton: View {
    @Binding var model: String

    @State private var presented = false
    @State private var models: [OllamaModel] = []
    @State private var catalogError: String?
    @State private var isLoading = false

    var body: some View {
        Button {
            presented.toggle()
            if models.isEmpty { refresh() }
        } label: {
            Text("Choose…")
        }
        .help("Choose a pulled Ollama model")
        .popover(isPresented: $presented, arrowEdge: .trailing) {
            picker
        }
    }

    private var picker: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Installed models")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    refresh()
                } label: {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .help("Refresh models")
            }
            .padding(12)

            Divider()

            if let catalogError {
                ContentUnavailableView(
                    "Ollama unavailable",
                    systemImage: "bolt.horizontal.circle",
                    description: Text(catalogError)
                )
            } else if isLoading && models.isEmpty {
                ProgressView("Loading models…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if models.isEmpty {
                ContentUnavailableView(
                    "No models pulled",
                    systemImage: "shippingbox",
                    description: Text("Run `ollama pull` for a model, then refresh.")
                )
            } else {
                List(models) { candidate in
                    Button {
                        model = candidate.name
                        presented = false
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(candidate.name)
                                    .lineLimit(1)
                                if let note = detail(for: candidate) {
                                    Text(note)
                                        .uiFont(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if model == candidate.name {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 380, height: 360)
    }

    private func detail(for candidate: OllamaModel) -> String? {
        var parts: [String] = []
        if let size = candidate.details?.parameterSize { parts.append(size) }
        if let quantization = candidate.details?.quantizationLevel { parts.append(quantization) }
        if let bytes = candidate.size {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func refresh() {
        guard !isLoading else { return }
        isLoading = true
        catalogError = nil
        Task {
            do {
                models = try await OllamaModelCatalog.fetch()
            } catch {
                catalogError = error.localizedDescription
            }
            isLoading = false
        }
    }
}

struct OpenRouterModelButton: View {
    @Binding var model: String
    let imagesOnly: Bool

    @State private var presented = false
    @State private var filter = ""
    @State private var models: [OpenRouterModel] = []
    @State private var catalogError: String?
    @State private var isLoading = false

    var body: some View {
        Button {
            presented.toggle()
            if models.isEmpty { refresh() }
        } label: {
            Text("Choose…")
        }
        .help("Choose an OpenRouter model")
        .popover(isPresented: $presented, arrowEdge: .trailing) {
            picker
        }
    }

    private var picker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter models", text: $filter)
                    .textFieldStyle(.plain)
                Button {
                    refresh()
                } label: {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .help("Refresh models")
            }
            .padding(12)

            Divider()

            if let catalogError, models.isEmpty {
                ContentUnavailableView(
                    "Models unavailable",
                    systemImage: "wifi.exclamationmark",
                    description: Text(catalogError)
                )
            } else if isLoading && models.isEmpty {
                ProgressView("Loading models…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else {
                List(filtered) { candidate in
                    Button {
                        model = candidate.id
                        presented = false
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(candidate.name)
                                    .lineLimit(1)
                                Spacer()
                                if model == candidate.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            Text(candidate.id)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if let contextLength = candidate.contextLength {
                                Text("\(contextLength.formatted()) context")
                                    .uiFont(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }

            if let catalogError, !models.isEmpty {
                Divider()
                Label(catalogError, systemImage: "exclamationmark.triangle.fill")
                    .uiFont(.caption)
                    .foregroundStyle(.orange)
                    .padding(10)
            }
        }
        .frame(width: 430, height: 430)
    }

    private var filtered: [OpenRouterModel] {
        let candidates = imagesOnly
            ? models.filter { $0.architecture?.inputModalities?.contains("image") != false }
            : models
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return candidates }
        return candidates.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
                || ($0.description?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func refresh() {
        guard !isLoading else { return }
        isLoading = true
        catalogError = nil
        Task {
            do {
                models = try await OpenRouterModelCatalog.fetch()
                for model in models {
                    guard let contextLength = model.contextLength else { continue }
                    ModelContextWindow.record(
                        contextLength, for: ModelChoice(backend: .openRouter, model: model.id)
                    )
                }
            } catch {
                catalogError = error.localizedDescription
            }
            isLoading = false
        }
    }
}
