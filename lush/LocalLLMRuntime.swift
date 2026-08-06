import Foundation

#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
#endif

enum LocalLLMRuntime {
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
        let modelConfig = ModelConfiguration(id: repo)
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
            ) { _ in
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
