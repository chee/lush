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

struct OllamaModel: Decodable, Identifiable, Sendable {
    struct Details: Decodable, Sendable {
        let parameterSize: String?
        let quantizationLevel: String?

        enum CodingKeys: String, CodingKey {
            case parameterSize = "parameter_size"
            case quantizationLevel = "quantization_level"
        }
    }

    let name: String
    let size: Int64?
    let details: Details?

    var id: String { name }
}

enum OllamaModelCatalog {
    private struct Response: Decodable {
        let models: [OllamaModel]
    }

    /// The models Ollama already has pulled, read from the host of the
    /// configured chat endpoint.
    static func fetch() async throws -> [OllamaModel] {
        guard let url = tagsURL() else { throw CatalogError.endpointUnreadable }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CatalogError.requestFailed
        }
        return try JSONDecoder().decode(Response.self, from: data).models.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func tagsURL() -> URL? {
        let endpoint = LocalModelSettings.endpoint(for: .ollama)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: endpoint) else { return nil }
        components.path = "/api/tags"
        components.query = nil
        return components.url
    }

    enum CatalogError: LocalizedError {
        case endpointUnreadable
        case requestFailed

        var errorDescription: String? {
            switch self {
            case .endpointUnreadable: "Enter a valid Ollama endpoint first."
            case .requestFailed: "Ollama did not answer. Check that it is running."
            }
        }
    }
}
