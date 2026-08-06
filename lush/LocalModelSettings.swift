import Foundation

enum LocalModelOperation: String, CaseIterable, Identifiable {
    case attachmentSummary
    case imageCaption
    case voiceNoteSummary

    var id: String { rawValue }

    var label: String {
        switch self {
        case .attachmentSummary: "Attachment summaries"
        case .imageCaption: "Image captions"
        case .voiceNoteSummary: "Voice note summaries"
        }
    }
}

enum LocalModelBackend: String, CaseIterable, Identifiable {
    case appleIntelligence
    case huggingFace

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence"
        case .huggingFace: "Hugging Face model"
        }
    }
}

struct HuggingFaceModelConfig: Codable, Equatable {
    var repo: String = ""
    var revision: String = "main"
    var filename: String = ""
    var localPath: String?

    var isConfigured: Bool {
        !repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum LocalModelSettings {
    private static let backendPrefix = "ml.backend."
    private static let huggingFacePrefix = "ml.huggingFace."

    static func backend(for operation: LocalModelOperation) -> LocalModelBackend {
        guard let raw = UserDefaults.standard.string(forKey: backendPrefix + operation.rawValue),
              let backend = LocalModelBackend(rawValue: raw)
        else { return .appleIntelligence }
        return backend
    }

    static func setBackend(_ backend: LocalModelBackend, for operation: LocalModelOperation) {
        UserDefaults.standard.set(backend.rawValue, forKey: backendPrefix + operation.rawValue)
    }

    static func huggingFaceConfig(for operation: LocalModelOperation) -> HuggingFaceModelConfig {
        guard let data = UserDefaults.standard.data(forKey: huggingFacePrefix + operation.rawValue),
              let config = try? JSONDecoder().decode(HuggingFaceModelConfig.self, from: data)
        else { return HuggingFaceModelConfig() }
        return config
    }

    static func setHuggingFaceConfig(_ config: HuggingFaceModelConfig, for operation: LocalModelOperation) {
        UserDefaults.standard.set(
            try? JSONEncoder().encode(config),
            forKey: huggingFacePrefix + operation.rawValue
        )
    }
}

enum HuggingFaceModelDownloader {
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
        _ config: HuggingFaceModelConfig,
        for operation: LocalModelOperation
    ) async throws -> HuggingFaceModelConfig {
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
