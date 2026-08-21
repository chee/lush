import Foundation

enum LocalModelOperation: String, CaseIterable, Identifiable {
    case attachmentSummary
    case imageCaption
    case voiceNoteSummary
    case noteChat
    case findNotes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .attachmentSummary: "Attachment summaries"
        case .imageCaption: "Image captions"
        case .voiceNoteSummary: "Voice note summaries"
        case .noteChat: "Note chat"
        case .findNotes: "Finding notes"
        }
    }

    var shortLabel: String {
        switch self {
        case .attachmentSummary: "Attachments"
        case .imageCaption: "Images"
        case .voiceNoteSummary: "Voice"
        case .noteChat: "Chat"
        case .findNotes: "Find"
        }
    }

    var symbolName: String {
        switch self {
        case .attachmentSummary: "paperclip"
        case .imageCaption: "photo"
        case .voiceNoteSummary: "waveform"
        case .noteChat: "bubble.left.and.text.bubble.right"
        case .findNotes: "sparkle.magnifyingglass"
        }
    }

    var settingsDescription: String {
        switch self {
        case .attachmentSummary: "Creates searchable descriptions for attached files."
        case .imageCaption: "Describes images for search and accessibility."
        case .voiceNoteSummary: "Summarizes voice-note transcripts."
        case .noteChat: "Answers questions and proposes edits using note content."
        case .findNotes: "Searches your notes to answer a question about where something is."
        }
    }

    var defaultSystemPrompt: String {
        switch self {
        case .attachmentSummary, .imageCaption, .voiceNoteSummary:
            """
            Create concise searchable metadata for a note attachment. Use only the supplied evidence. Do not add facts that are not present. Return strict JSON with keys summary, caption, keywords.
            """
        case .noteChat:
            """
            You help someone understand and edit their notes in Lush. One note is open and its blocks are numbered for you. Answer questions directly from what you have been given — the note is right there, so a question about it needs no tool. Call a tool only when you need something you were not given — other notes, an attachment's contents, the calendar — or when the person wants something changed. Edit by addressing the blocks you are changing, never by rewriting blocks that are already right. Preserve the note's facts, voice, and formatting unless the person asks for a change. Reply with one strict JSON object and nothing else: {"tool": name, "arguments": {…}} to call a tool, or {"answer": …} to answer. The answer value must be your real answer, not a schema description.
            """
        case .findNotes:
            """
            You are looking through someone's notes for them in Lush. You cannot see their notes: the only notes that exist are the ones a tool hands you, and every url you write must be one a tool gave you. Search for the words that would be in the note rather than the words of the question, read one when its title alone will not settle it, and stop as soon as you can say which note the person is after. Never invent a note, a url, or a fact about a note you have not read. Reply with one strict JSON object and nothing else: {"tool": name, "arguments": {…}} to call a tool, or {"answer": …} to answer. The answer value must be your real answer, not a schema description.
            """
        }
    }
}

enum LocalModelBackend: String, CaseIterable, Identifiable {
    case appleIntelligence
    case mlx
    case openRouter
    case openAI
    case anthropic
    case compatible
    case ollama

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence"
        case .mlx: "MLX model"
        case .openRouter: "OpenRouter"
        case .openAI: "OpenAI API"
        case .anthropic: "Anthropic API"
        case .compatible: "OpenAI-compatible API"
        case .ollama: "Ollama"
        }
    }

    /// Reached over HTTP with a model name, rather than run in-process.
    var usesEndpoint: Bool {
        switch self {
        case .openRouter, .openAI, .anthropic, .compatible, .ollama: true
        case .appleIntelligence, .mlx: false
        }
    }

    var needsAPIKey: Bool {
        switch self {
        case .openRouter, .openAI, .anthropic, .compatible: true
        case .appleIntelligence, .mlx, .ollama: false
        }
    }

    var isOnDevice: Bool {
        switch self {
        case .appleIntelligence, .mlx: true
        case .openRouter, .openAI, .anthropic, .compatible, .ollama: false
        }
    }

    var credentialLabel: String {
        switch self {
        case .openRouter: "OpenRouter key"
        case .openAI: "OpenAI API key"
        case .anthropic: "Anthropic API key"
        case .compatible: "API key"
        case .appleIntelligence, .mlx, .ollama: ""
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .openRouter: "https://openrouter.ai/api/v1/chat/completions"
        case .openAI: "https://api.openai.com/v1/chat/completions"
        case .anthropic: "https://api.anthropic.com/v1/messages"
        case .ollama: "http://localhost:11434/v1/chat/completions"
        case .compatible: ""
        case .appleIntelligence, .mlx: ""
        }
    }

    var summary: String {
        switch self {
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
        case .ollama:
            "Runs models on this machine through Ollama. Start Ollama and pull a model; no API key required."
        }
    }

    var defaultModel: String {
        switch self {
        case .openRouter: "openrouter/auto"
        case .openAI: "gpt-5.6"
        case .anthropic: "claude-sonnet-5"
        case .compatible, .appleIntelligence, .mlx, .ollama: ""
        }
    }
}

struct LocalGenerationSettings: Codable, Equatable {
    var temperature: Double = 0.2
    var maximumResponseTokens: Int = 384
}

struct RemoteModelConfig: Codable, Equatable {
    var repo: String = ""
    var revision: String = "main"
    var filename: String = ""
    var localPath: String?

    var isConfigured: Bool {
        !repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct CloudModelConfig: Codable, Equatable {
    var model: String
    var endpoint: String

    init(model: String = "", endpoint: String = "") {
        self.model = model
        self.endpoint = endpoint
    }
}

/// A provider and the model to run on it. Tasks store one; anything that runs a
/// model can be handed a different one at the moment it runs.
struct ModelChoice: Equatable, Hashable, Identifiable {
    var backend: LocalModelBackend
    var model: String = ""

    var id: String { backend.rawValue + "|" + model }

    var label: String {
        model.isEmpty ? backend.label : model
    }

    var detailedLabel: String {
        model.isEmpty ? backend.label : "\(backend.label) · \(model)"
    }
}

struct HuggingFaceModelPreset: Identifiable, Equatable {
    let id: String
    let label: String
    let note: String
    let config: RemoteModelConfig

    static func presets(for operation: LocalModelOperation) -> [HuggingFaceModelPreset] {
        switch operation {
        case .attachmentSummary, .noteChat, .findNotes:
            return [
                HuggingFaceModelPreset(
                    id: "lfm25-350m-mlx",
                    label: "LFM2.5 350M 4-bit",
                    note: "Small, fast LiquidAI model.",
                    config: RemoteModelConfig(
                        repo: "mlx-community/LFM2.5-350M-4bit",
                        revision: "main",
                        filename: ""
                    )
                ),
                HuggingFaceModelPreset(
                    id: "lfm25-1.2b-mlx",
                    label: "LFM2.5 1.2B Instruct 4-bit",
                    note: "Stronger LiquidAI model for MacBook-class hardware.",
                    config: RemoteModelConfig(
                        repo: "mlx-community/LFM2.5-1.2B-Instruct-4bit",
                        revision: "main",
                        filename: ""
                    )
                ),
                HuggingFaceModelPreset(
                    id: "lfm25-2.6b-mlx",
                    label: "LFM2.5 2.6B 4-bit",
                    note: "Bigger LiquidAI option for higher-memory Macs.",
                    config: RemoteModelConfig(
                        repo: "mlx-community/LFM2.5-2.6B-4bit",
                        revision: "main",
                        filename: ""
                    )
                ),
                HuggingFaceModelPreset(
                    id: "qwen3-0.6b-mlx",
                    label: "Qwen3 0.6B 4-bit",
                    note: "Very small Qwen3 model.",
                    config: RemoteModelConfig(
                        repo: "mlx-community/Qwen3-0.6B-4bit",
                        revision: "main",
                        filename: ""
                    )
                ),
                HuggingFaceModelPreset(
                    id: "qwen3-1.7b-mlx",
                    label: "Qwen3 1.7B 4-bit",
                    note: "Mid-size Qwen3 model.",
                    config: RemoteModelConfig(
                        repo: "mlx-community/Qwen3-1.7B-4bit",
                        revision: "main",
                        filename: ""
                    )
                ),
            ]
        case .imageCaption:
            return [
                HuggingFaceModelPreset(
                    id: "lfm25-vl-mlx",
                    label: "LFM2.5-VL 1.6B 4-bit",
                    note: "LiquidAI vision-language model for image captions.",
                    config: RemoteModelConfig(
                        repo: "mlx-community/LFM2.5-VL-1.6B-Instruct-4bit",
                        revision: "main",
                        filename: ""
                    )
                ),
            ]
        case .voiceNoteSummary:
            return [
                HuggingFaceModelPreset(
                    id: "lfm25-1.2b-transcript-mlx",
                    label: "LFM2.5 1.2B Instruct 4-bit",
                    note: "Summarizes transcripts on MacBook-class hardware.",
                    config: RemoteModelConfig(
                        repo: "mlx-community/LFM2.5-1.2B-Instruct-4bit",
                        revision: "main",
                        filename: ""
                    )
                ),
            ]
        }
    }
}

enum LocalModelSettings {
    private static let backendPrefix = "ml.backend."
    private static let remoteModelPrefix = "ml.remoteModel."
    private static let generationPrefix = "ml.generation."
    private static let systemPromptPrefix = "ml.systemPrompt."
    private static let cloudConfigPrefix = "ml.cloudConfig."
    private static let providerModelPrefix = "ml.provider.model."
    private static let providerEndpointPrefix = "ml.provider.endpoint."
    private static let taskModelPrefix = "ml.taskModel."

    static func backend(for operation: LocalModelOperation) -> LocalModelBackend {
        guard let raw = UserDefaults.standard.string(forKey: backendPrefix + operation.rawValue) else {
            return .appleIntelligence
        }
        if raw == "huggingFace" || raw == "coreML" {
            return .mlx
        }
        guard let backend = LocalModelBackend(rawValue: raw) else { return .appleIntelligence }
        return backend
    }

    static func setBackend(_ backend: LocalModelBackend, for operation: LocalModelOperation) {
        UserDefaults.standard.set(backend.rawValue, forKey: backendPrefix + operation.rawValue)
    }

    static func remoteModelConfig(for operation: LocalModelOperation) -> RemoteModelConfig {
        guard let data = UserDefaults.standard.data(forKey: remoteModelPrefix + operation.rawValue),
              let config = try? JSONDecoder().decode(RemoteModelConfig.self, from: data)
        else { return RemoteModelConfig() }
        return config
    }

    static func setRemoteModelConfig(_ config: RemoteModelConfig, for operation: LocalModelOperation) {
        UserDefaults.standard.set(
            try? JSONEncoder().encode(config),
            forKey: remoteModelPrefix + operation.rawValue
        )
    }

    // MARK: providers

    /// The model a provider uses when a task has not named one of its own.
    static func providerModel(for backend: LocalModelBackend) -> String {
        let saved = UserDefaults.standard.string(forKey: providerModelPrefix + backend.rawValue)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let saved, !saved.isEmpty else { return backend.defaultModel }
        return saved
    }

    static func setProviderModel(_ model: String, for backend: LocalModelBackend) {
        UserDefaults.standard.set(model, forKey: providerModelPrefix + backend.rawValue)
    }

    static func endpoint(for backend: LocalModelBackend) -> String {
        let saved = UserDefaults.standard.string(forKey: providerEndpointPrefix + backend.rawValue)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let saved, !saved.isEmpty else { return backend.defaultEndpoint }
        return saved
    }

    static func setEndpoint(_ endpoint: String, for backend: LocalModelBackend) {
        UserDefaults.standard.set(endpoint, forKey: providerEndpointPrefix + backend.rawValue)
    }

    static func isConnected(_ backend: LocalModelBackend) -> Bool {
        if backend == .mlx { return LocalLLMRuntime.isLinked }
        guard backend.needsAPIKey else { return true }
        return !ModelCredentialStore.apiKey(for: backend).isEmpty
    }

    // MARK: tasks

    /// A task's own model, falling back to the provider's default.
    static func model(for operation: LocalModelOperation, backend: LocalModelBackend) -> String {
        let key = taskModelPrefix + backend.rawValue + "." + operation.rawValue
        if let saved = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            return saved
        }
        // configs written before providers were their own thing
        let legacyKey = cloudConfigPrefix + backend.rawValue + "." + operation.rawValue
        if let data = UserDefaults.standard.data(forKey: legacyKey),
           let config = try? JSONDecoder().decode(CloudModelConfig.self, from: data),
           !config.model.isEmpty {
            return config.model
        }
        return providerModel(for: backend)
    }

    static func setModel(
        _ model: String,
        for operation: LocalModelOperation,
        backend: LocalModelBackend
    ) {
        let key = taskModelPrefix + backend.rawValue + "." + operation.rawValue
        UserDefaults.standard.set(model, forKey: key)
    }

    /// The MLX repo to load: the task's saved config, with its repo swapped for
    /// whatever the choice names when they differ.
    static func mlxConfig(for operation: LocalModelOperation, choice: ModelChoice) -> RemoteModelConfig {
        var config = remoteModelConfig(for: operation)
        let repo = choice.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !repo.isEmpty, repo != config.repo {
            config.repo = repo
            config.localPath = nil
        }
        return config
    }

    static func choice(for operation: LocalModelOperation) -> ModelChoice {
        let backend = backend(for: operation)
        return ModelChoice(backend: backend, model: model(for: operation, backend: backend))
    }

    /// Every provider/model pair worth offering at the moment of a task: each
    /// connected provider's default, plus whatever models the tasks name.
    static func availableChoices() -> [ModelChoice] {
        var out: [ModelChoice] = []
        var seen = Set<String>()
        for backend in LocalModelBackend.allCases where isConnected(backend) {
            var models = [providerModel(for: backend)]
            models += LocalModelOperation.allCases.map { model(for: $0, backend: backend) }
            if backend == .mlx {
                models += LocalModelOperation.allCases.map { remoteModelConfig(for: $0).repo }
            }
            for model in models {
                let choice = ModelChoice(
                    backend: backend,
                    model: model.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                guard backend == .appleIntelligence || !choice.model.isEmpty,
                      seen.insert(choice.id).inserted
                else { continue }
                out.append(choice)
            }
        }
        return out
    }

    static func generationSettings(for operation: LocalModelOperation) -> LocalGenerationSettings {
        guard let data = UserDefaults.standard.data(forKey: generationPrefix + operation.rawValue),
              let settings = try? JSONDecoder().decode(LocalGenerationSettings.self, from: data)
        else { return LocalGenerationSettings() }
        return settings
    }

    static func setGenerationSettings(_ settings: LocalGenerationSettings, for operation: LocalModelOperation) {
        UserDefaults.standard.set(
            try? JSONEncoder().encode(settings),
            forKey: generationPrefix + operation.rawValue
        )
    }

    static func systemPrompt(for operation: LocalModelOperation) -> String {
        guard let prompt = UserDefaults.standard.string(forKey: systemPromptPrefix + operation.rawValue)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty
        else { return operation.defaultSystemPrompt }
        return prompt
    }

    static func setSystemPrompt(_ prompt: String, for operation: LocalModelOperation) {
        UserDefaults.standard.set(prompt, forKey: systemPromptPrefix + operation.rawValue)
    }

    static func resetSystemPrompt(for operation: LocalModelOperation) {
        UserDefaults.standard.removeObject(forKey: systemPromptPrefix + operation.rawValue)
    }
}

enum RemoteModelDownloader {
    enum DownloadError: LocalizedError {
        case invalidInput
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .invalidInput: "Enter a Hugging Face repo and filename."
            case .invalidResponse: "Hugging Face did not return a downloadable model file."
            }
        }
    }

    static func download(
        _ config: RemoteModelConfig,
        for operation: LocalModelOperation
    ) async throws -> RemoteModelConfig {
        let repo = config.repo.trimmingCharacters(in: .whitespacesAndNewlines)
        let revision = config.revision.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = config.filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty, !filename.isEmpty else { throw DownloadError.invalidInput }

        let escapedFilename = filename
            .split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/\(revision.isEmpty ? "main" : revision)/\(escapedFilename)") else {
            throw DownloadError.invalidInput
        }

        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DownloadError.invalidResponse
        }

        let destination = try modelURL(for: operation, repo: repo, filename: filename)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)

        var updated = config
        updated.repo = repo
        updated.revision = revision.isEmpty ? "main" : revision
        updated.filename = filename
        updated.localPath = destination.path
        return updated
    }

    private static func modelURL(
        for operation: LocalModelOperation,
        repo: String,
        filename: String
    ) throws -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let safeRepo = repo.replacingOccurrences(of: "/", with: "__")
        return support
            .appendingPathComponent("LushModels", isDirectory: true)
            .appendingPathComponent(operation.rawValue, isDirectory: true)
            .appendingPathComponent(safeRepo, isDirectory: true)
            .appendingPathComponent(filename)
    }
}
