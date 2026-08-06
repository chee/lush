import Foundation
import FoundationModels

struct AssetMLEvidence: Sendable {
    let name: String
    let kind: String
    let description: String
    let text: String
}

enum MLAnalyzer {
    private struct GeneratedMetadata: Decodable {
        let summary: String
        let caption: String
        let keywords: [String]
    }

    static func analyze(_ evidence: AssetMLEvidence) async -> AssetMl? {
        let text = evidence.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = evidence.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !description.isEmpty else { return nil }

        let model = SystemLanguageModel.default
        guard model.isAvailable else { return nil }

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
            let response = try await session.respond(to: prompt)
            guard let generated = parse(response.content) else { return nil }
            let summary = generated.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let caption = generated.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            let keywords = generated.keywords
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(8)
                .joined(separator: ", ")

            if summary.isEmpty && caption.isEmpty && keywords.isEmpty {
                return nil
            }
            return AssetMl(summary: summary, caption: caption, keywords: keywords)
        } catch {
            return nil
        }
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
