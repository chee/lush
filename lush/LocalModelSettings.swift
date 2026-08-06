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
}

enum LocalModelBackend: String, CaseIterable, Identifiable {
    case appleIntelligence
    case coreML

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence"
        case .coreML: "Core ML model"
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
            && !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                    id: "lfm25-350m-coreml",
                    label: "LFM2.5 350M Core ML",
                    note: "Preferred small text model lane for summaries and chat when a Core ML runtime adapter is wired.",
                    config: RemoteModelConfig(
                        repo: "mlboydaisuke/lfm2.5-350m-coreml",
                        revision: "main",
                        filename: ""
                    )
                ),
                HuggingFaceModelPreset(
                    id: "lfm25-350m-gguf",
                    label: "LFM2.5 350M GGUF",
                    note: "Good fallback suggestion if we later add a GGUF/llama.cpp runtime.",
                    config: RemoteModelConfig(
                        repo: "LiquidAI/LFM2.5-350M-GGUF",
                        revision: "main",
                        filename: "LFM2.5-350M-Q4_K_M.gguf"
                    )
                ),
                HuggingFaceModelPreset(
                    id: "lfm25-1.2b-gguf",
                    label: "LFM2.5 1.2B Instruct GGUF",
                    note: "Stronger local text model for MacBook-class hardware; GGUF runtime required.",
                    config: RemoteModelConfig(
                        repo: "LiquidAI/LFM2.5-1.2B-Instruct-GGUF",
                        revision: "main",
                        filename: "LFM2.5-1.2B-Instruct-Q4_K_M.gguf"
                    )
                ),
                HuggingFaceModelPreset(
                    id: "lfm25-2.6b-gguf",
                    label: "LFM2.5 2.6B GGUF",
                    note: "Bigger, stronger LFM option for high-memory Macs; GGUF runtime required.",
                    config: RemoteModelConfig(
                        repo: "LiquidAI/LFM2.5-2.6B-GGUF",
                        revision: "main",
                        filename: "LFM2.5-2.6B-Q4_K_M.gguf"
                    )
                ),
                HuggingFaceModelPreset(
                    id: "lfm25-8b-a1b-gguf",
                    label: "LFM2.5 8B-A1B GGUF",
                    note: "Large active-parameter model for powerful Macs; GGUF runtime required.",
                    config: RemoteModelConfig(
                        repo: "LiquidAI/LFM2.5-8B-A1B-GGUF",
                        revision: "main",
                        filename: "LFM2.5-8B-A1B-Q4_K_M.gguf"
                    )
                ),
                HuggingFaceModelPreset(
                    id: "qwen3-0.6b-q4",
                    label: "Qwen3 0.6B Q4",
                    note: "Further suggestion; GGUF runtime required.",
                    config: RemoteModelConfig(
                        repo: "lm-kit/qwen-3-0.6b-instruct-gguf",
                        revision: "main",
                        filename: "qwen-3-0.6b-instruct-q4_k_m.gguf"
                    )
                ),
            ]
        case .imageCaption:
            return [
                HuggingFaceModelPreset(
                    id: "lfm25-vl-coreml",
                    label: "LFM2.5-VL Core ML",
                    note: "Core ML vision-language candidate for richer image captions.",
                    config: RemoteModelConfig(
                        repo: "mweinbach/LFM2.5-VL-1.6B-CoreML",
                        revision: "main",
                        filename: ""
                    )
                ),
                HuggingFaceModelPreset(
                    id: "blip-base",
                    label: "BLIP base",
                    note: "Further suggestion; requires a converted Core ML package or model-specific runtime.",
                    config: RemoteModelConfig(
                        repo: "Salesforce/blip-image-captioning-base",
                        revision: "main",
                        filename: ""
                    )
                ),
            ]
        case .voiceNoteSummary:
            return [
                HuggingFaceModelPreset(
                    id: "moonshine-streaming-tiny",
                    label: "Moonshine Streaming Tiny",
                    note: "Preferred speech-recognition suggestion; needs an ASR runtime adapter.",
                    config: RemoteModelConfig(
                        repo: "cstr/moonshine-streaming-tiny-GGUF",
                        revision: "main",
                        filename: "moonshine-streaming-tiny-q4_k.gguf"
                    )
                ),
                HuggingFaceModelPreset(
                    id: "moonshine-streaming-small",
                    label: "Moonshine Streaming Small",
                    note: "Bigger Moonshine option for better speech recognition on Macs; ASR runtime adapter required.",
                    config: RemoteModelConfig(
                        repo: "cstr/moonshine-streaming-small-GGUF",
                        revision: "main",
                        filename: "moonshine-streaming-small-q4_k.gguf"
                    )
                ),
                HuggingFaceModelPreset(
                    id: "lfm25-1.2b-transcript-summary",
                    label: "LFM2.5 1.2B Instruct GGUF",
                    note: "Summarizes transcripts well on stronger local hardware; GGUF runtime required.",
                    config: RemoteModelConfig(
                        repo: "LiquidAI/LFM2.5-1.2B-Instruct-GGUF",
                        revision: "main",
                        filename: "LFM2.5-1.2B-Instruct-Q4_K_M.gguf"
                    )
                ),
                HuggingFaceModelPreset(
                    id: "whisper-small",
                    label: "Whisper small GGUF",
                    note: "Further suggestion; requires a whisper.cpp-style runtime adapter.",
                    config: RemoteModelConfig(
                        repo: "forkjoin-ai/whisper-small-gguf",
                        revision: "main",
                        filename: "whisper-small-gguf.gguf"
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

    static func backend(for operation: LocalModelOperation) -> LocalModelBackend {
        guard let raw = UserDefaults.standard.string(forKey: backendPrefix + operation.rawValue) else {
            return .appleIntelligence
        }
        if raw == "huggingFace" {
            return .coreML
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
