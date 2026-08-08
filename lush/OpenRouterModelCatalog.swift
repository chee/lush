import Foundation

struct OpenRouterModel: Codable, Identifiable, Sendable {
    struct Architecture: Codable, Sendable {
        let inputModalities: [String]?
        let outputModalities: [String]?

        enum CodingKeys: String, CodingKey {
            case inputModalities = "input_modalities"
            case outputModalities = "output_modalities"
        }
    }

    let id: String
    let name: String
    let description: String?
    let contextLength: Int?
    let architecture: Architecture?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case contextLength = "context_length"
        case architecture
    }
}

enum OpenRouterModelCatalog {
    private struct Response: Decodable {
        let data: [OpenRouterModel]
    }

    static func fetch() async throws -> [OpenRouterModel] {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
        request.setValue("Lush", forHTTPHeaderField: "X-OpenRouter-Title")
        let key = ModelCredentialStore.apiKey(for: .openRouter)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CatalogError.requestFailed
        }
        return try JSONDecoder().decode(Response.self, from: data).data.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    enum CatalogError: LocalizedError {
        case requestFailed

        var errorDescription: String? { "OpenRouter's model list could not be loaded." }
    }
}
