import Foundation
import FoundationModels

struct AssetMLEvidence: Sendable {
    let name: String
    let kind: String
    let description: String
    let text: String
}

enum MLAnalyzer {
    enum AnalyzerError: LocalizedError {
        case noEvidence
        case appleIntelligenceUnavailable
        case customModelNotConfigured
        case customRuntimeUnavailable
        case generationFailed

        var errorDescription: String? {
            switch self {
            case .noEvidence: "There is not enough extracted text or Vision metadata to summarize."
            case .appleIntelligenceUnavailable: "Apple Intelligence is not available on this device."
            case .customModelNotConfigured: "No Core ML model is configured for this operation."
            case .customRuntimeUnavailable: "The model is downloaded, but Lush does not have a Core ML runtime adapter for this model yet."
            case .generationFailed: "The local model could not generate metadata for this attachment."
            }
        }
    }

    private struct GeneratedMetadata: Decodable {
        let summary: String
        let caption: String
        let keywords: [String]
    }

    static func analyze(
        _ evidence: AssetMLEvidence,
        operation: LocalModelOperation = .attachmentSummary
    ) async throws -> AssetMl {
        let text = evidence.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = evidence.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !description.isEmpty else { throw AnalyzerError.noEvidence }

        switch LocalModelSettings.backend(for: operation) {
        case .appleIntelligence:
            return try await analyzeWithFoundationModels(evidence, operation: operation)
        case .coreML:
            return try await analyzeWithCoreMLModel(evidence, operation: operation)
        }
    }

    private static func analyzeWithFoundationModels(
        _ evidence: AssetMLEvidence,
        operation: LocalModelOperation
    ) async throws -> AssetMl {
        let text = evidence.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let description = evidence.description.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let model = SystemLanguageModel.default
        guard model.isAvailable else { throw AnalyzerError.appleIntelligenceUnavailable }

        let instructions = """
        Create concise searchable metadata for a note attachment. Use only the supplied evidence. Do not add facts that are not present. Return strict JSON with keys summary, caption, keywords.
        """
        let prompt = """
        Attachment name: \(evidence.name)
        Attachment kind: \(evidence.kind)
        Existing visual/audio description: \(limited(description, to: 1_500))
        Extracted text or transcript: \(limited(text, to: 6_000))

        JSON requirements:
        - summary: one sentence, empty if there is not enough evidence
        - caption: short phrase for visual content or audio subject, empty if not useful
        - keywords: 3 to 8 short search keywords
        """

        do {
            let session = LanguageModelSession(instructions: instructions)
            let settings = LocalModelSettings.generationSettings(for: operation)
            let options = GenerationOptions(
                temperature: settings.temperature,
                maximumResponseTokens: settings.maximumResponseTokens
            )
            let response = try await session.respond(to: prompt, options: options)
            guard let generated = parse(response.content) else { throw AnalyzerError.generationFailed }
            let summary = generated.summary.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let caption = generated.caption.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let keywords = generated.keywords
                .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(8)
                .joined(separator: ", ")

            if summary.isEmpty && caption.isEmpty && keywords.isEmpty {
                throw AnalyzerError.generationFailed
            }
            return AssetMl(summary: summary, caption: caption, keywords: keywords)
        } catch {
            throw error
        }
    }

    private static func analyzeWithCoreMLModel(
        _ evidence: AssetMLEvidence,
        operation: LocalModelOperation
    ) async throws -> AssetMl {
        let config = LocalModelSettings.remoteModelConfig(for: operation)
        guard !config.repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AnalyzerError.customModelNotConfigured
        }

        let text = evidence.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let description = evidence.description.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let prompt = """
        Create concise searchable metadata for a note attachment. Use only the supplied evidence. Do not add facts that are not present. Return strict JSON with keys summary, caption, keywords.

        Attachment name: \(evidence.name)
        Attachment kind: \(evidence.kind)
        Existing visual/audio description: \(limited(description, to: 1_500))
        Extracted text or transcript: \(limited(text, to: 6_000))

        JSON requirements:
        - summary: one sentence, empty if there is not enough evidence
        - caption: short phrase for visual content or audio subject, empty if not useful
        - keywords: 3 to 8 short search keywords
        """

        let response = try await LocalLLMRuntime.generateText(prompt: prompt, operation: operation)
        guard let generated = parse(response) else { throw AnalyzerError.generationFailed }
        let summary = generated.summary.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let caption = generated.caption.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let keywords = generated.keywords
            .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(8)
            .joined(separator: ", ")

        if summary.isEmpty && caption.isEmpty && keywords.isEmpty {
            throw AnalyzerError.generationFailed
        }
        return AssetMl(summary: summary, caption: caption, keywords: keywords)
    }

    private static func limited(_ value: String, to maxCharacters: Int) -> String {
        guard value.count > maxCharacters else { return value }
        return String(value.prefix(maxCharacters))
    }

    private static func parse(_ raw: String) -> GeneratedMetadata? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = decode(trimmed) {
            return direct
        }
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end
        else { return nil }
        return decode(String(trimmed[start...end]))
    }

    private static func decode(_ json: String) -> GeneratedMetadata? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GeneratedMetadata.self, from: data)
    }
}
