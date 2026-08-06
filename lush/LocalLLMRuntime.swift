import Foundation

#if canImport(CoreML)
import CoreML
#endif

#if canImport(CoreMLLLM)
import CoreMLLLM
#endif

enum LocalLLMRuntime {
    enum RuntimeError: LocalizedError {
        case packageUnavailable
        case modelNotConfigured
        case unsupportedArtifact(String)

        var errorDescription: String? {
            switch self {
            case .packageUnavailable:
                "CoreML-LLM is not linked in this build."
            case .modelNotConfigured:
                "Select a Core ML model before generating."
            case .unsupportedArtifact(let detail):
                detail
            }
        }
    }

    static func generateText(
        prompt: String,
        operation: LocalModelOperation
    ) async throws -> String {
        let config = LocalModelSettings.remoteModelConfig(for: operation)
        let settings = LocalModelSettings.generationSettings(for: operation)
        return try await generateText(
            prompt: prompt,
            config: config,
            maxTokens: settings.maximumResponseTokens
        )
    }

    static func generateText(
        prompt: String,
        config: RemoteModelConfig,
        maxTokens: Int
    ) async throws -> String {
        let repo = config.repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty else { throw RuntimeError.modelNotConfigured }

        if config.filename.lowercased().hasSuffix(".gguf") {
            throw RuntimeError.unsupportedArtifact("GGUF models need a GGUF runtime; select a CoreML-LLM model for this backend.")
        }

        #if canImport(CoreMLLLM)
        if let localPath = config.localPath, !localPath.isEmpty {
            let url = URL(fileURLWithPath: localPath)
            let llm = try await CoreMLLLM.load(from: localModelDirectory(from: url), computeUnits: computeUnits)
            return try await llm.generate(prompt, maxTokens: maxTokens)
        }

        let llm = try await CoreMLLLM.load(repo: repo, computeUnits: computeUnits)
        return try await llm.generate(prompt, maxTokens: maxTokens)
        #else
        throw RuntimeError.packageUnavailable
        #endif
    }

    private static func localModelDirectory(from url: URL) -> URL {
        if url.hasDirectoryPath {
            return url
        }
        return url.deletingLastPathComponent()
    }

    #if canImport(CoreML)
    private static var computeUnits: MLComputeUnits {
        #if os(macOS) || os(iOS)
        return .cpuAndNeuralEngine
        #else
        return .all
        #endif
    }
    #endif
}
