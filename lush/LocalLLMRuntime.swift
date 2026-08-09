import Foundation

#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
#endif

enum LocalLLMRuntime {
    /// Whether this build can run an MLX model at all.
    static var isLinked: Bool {
        #if canImport(MLXLLM)
        true
        #else
        false
        #endif
    }

    enum RuntimeError: LocalizedError {
        case packageUnavailable
        case modelNotConfigured

        var errorDescription: String? {
            switch self {
            case .packageUnavailable:
                "MLXLLM is not linked in this build. Add mlx-swift-examples and link MLXLLM + MLXLMCommon."
            case .modelNotConfigured:
                "Select an MLX model before generating."
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
            maxTokens: settings.maximumResponseTokens,
            temperature: settings.temperature
        )
    }

    static func generateText(
        prompt: String,
        config: RemoteModelConfig,
        maxTokens: Int,
        temperature: Double = 0.2
    ) async throws -> String {
        let repo = config.repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty else { throw RuntimeError.modelNotConfigured }

        #if canImport(MLXLLM)
        let localPath = config.localPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var isDirectory: ObjCBool = false
        let modelConfig: ModelConfiguration
        if !localPath.isEmpty,
           FileManager.default.fileExists(atPath: localPath, isDirectory: &isDirectory),
           isDirectory.boolValue {
            modelConfig = ModelConfiguration(directory: URL(fileURLWithPath: localPath))
        } else {
            let revision = config.revision.trimmingCharacters(in: .whitespacesAndNewlines)
            modelConfig = ModelConfiguration(id: repo, revision: revision.isEmpty ? "main" : revision)
        }
        let container = try await LLMModelFactory.shared.loadContainer(configuration: modelConfig)
        return try await container.perform { context in
            let input = try await context.processor.prepare(
                input: .init(messages: [["role": "user", "content": prompt]])
            )
            var tokenCount = 0
            let result = try MLXLMCommon.generate(
                input: input,
                parameters: GenerateParameters(temperature: Float(temperature)),
                context: context
            ) { (_: [Int]) in
                tokenCount += 1
                return tokenCount < maxTokens ? .more : .stop
            }
            return result.output
        }
        #else
        throw RuntimeError.packageUnavailable
        #endif
    }
}
