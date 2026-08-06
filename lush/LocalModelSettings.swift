import Foundation

enum LocalModelOperation: String, CaseIterable, Identifiable {
    case attachmentSummary
    case imageCaption
    case voiceNoteSummary
    case noteChat

    var id: String { rawValue }

    var label: String {
        switch self {
        case .attachmentSummary: "Attachment summaries"
        case .imageCaption: "Image captions"
        case .voiceNoteSummary: "Voice note summaries"
        case .noteChat: "Note chat"
        }
    }

    var shortLabel: String {
        switch self {
        case .attachmentSummary: "Attachments"
        case .imageCaption: "Images"
        case .voiceNoteSummary: "Voice"
        case .noteChat: "Chat"
        }
    }

    var symbolName: String {
        switch self {
        case .attachmentSummary: "paperclip"
        case .imageCaption: "photo"
        case .voiceNoteSummary: "waveform"
        case .noteChat: "bubble.left.and.text.bubble.right"
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
            You help someone understand and edit one note in Lush. Use only the supplied note and chat history. If the person asks a question, answer it directly using the note. If the person asks you to change, rewrite, reorganize, summarize, expand, or otherwise edit the note, include the full revised note as editedMarkdown. Preserve the note's facts, voice, and formatting unless the person asks for a change. Return only strict JSON with keys answer and editedMarkdown. The answer value must be your real answer, not a schema description. editedMarkdown must be null when no note change is being proposed.
            """
        }
    }
}

enum LocalModelBackend: String, CaseIterable, Identifiable {
    case appleIntelligence
    case mlx

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence"
        case .mlx: "MLX model"
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

struct HuggingFaceModelPreset: Identifiable, Equatable {
    let id: String
    let label: String
    let note: String
    let config: RemoteModelConfig

    static func presets(for operation: LocalModelOperation) -> [HuggingFaceModelPreset] {
        switch operation {
        case .attachmentSummary, .noteChat:
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
