import Foundation
import Security

enum ModelCredentialStore {
    private static let service = "party.chee.patchwork.lush.models"

    static func apiKey(for backend: LocalModelBackend) -> String {
        var query: [String: Any] = baseQuery(for: backend)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8)
        else { return "" }
        return key
    }

    static func setAPIKey(_ value: String, for backend: LocalModelBackend) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = baseQuery(for: backend)
        guard !key.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialError.keychain(status)
            }
            return
        }

        let data = Data(key.utf8)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialError.keychain(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw CredentialError.keychain(updateStatus)
        }

        guard apiKey(for: backend) == key else { throw CredentialError.verificationFailed }
    }

    private static func baseQuery(for backend: LocalModelBackend) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: backend.rawValue,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    enum CredentialError: LocalizedError {
        case keychain(OSStatus)
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .keychain(let status): "Keychain error \(status)."
            case .verificationFailed: "The key could not be read back from Keychain."
            }
        }
    }
}

enum CloudLLMRuntime {
    enum RuntimeError: LocalizedError {
        case modelNotConfigured
        case endpointNotConfigured
        case credentialNotConfigured
        case invalidResponse
        case requestFailed(Int, String)

        var errorDescription: String? {
            switch self {
            case .modelNotConfigured: "Enter a model name before generating."
            case .endpointNotConfigured: "Enter an API endpoint before generating."
            case .credentialNotConfigured: "Connect this provider or save its API key before generating."
            case .invalidResponse: "The provider returned a response Lush could not read."
            case .requestFailed(let status, let message): "The provider returned \(status): \(message)"
            }
        }
    }

    private struct CompatibleRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let temperature: Double?
        let maxTokens: Int?
        let maxCompletionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case temperature
            case maxTokens = "max_tokens"
            case maxCompletionTokens = "max_completion_tokens"
        }
    }

    private struct CompatibleResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String
            }

            let message: Message
        }

        let choices: [Choice]
    }

    private struct AnthropicRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let temperature: Double
        let maxTokens: Int

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case temperature
            case maxTokens = "max_tokens"
        }
    }

    private struct AnthropicResponse: Decodable {
        struct Content: Decodable {
            let type: String
            let text: String?
        }

        let content: [Content]
    }

    private struct ErrorEnvelope: Decodable {
        struct ProviderError: Decodable {
            let message: String?
        }

        let error: ProviderError?
        let message: String?
    }

    static func generateText(prompt: String, operation: LocalModelOperation) async throws -> String {
        let backend = LocalModelSettings.backend(for: operation)
        let config = LocalModelSettings.cloudModelConfig(for: operation, backend: backend)
        let settings = LocalModelSettings.generationSettings(for: operation)
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = ModelCredentialStore.apiKey(for: backend)
        guard !model.isEmpty else { throw RuntimeError.modelNotConfigured }
        guard let url = URL(string: endpoint), !endpoint.isEmpty else { throw RuntimeError.endpointNotConfigured }
        guard !apiKey.isEmpty else { throw RuntimeError.credentialNotConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if backend == .anthropic {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try JSONEncoder().encode(AnthropicRequest(
                model: model,
                messages: [.init(role: "user", content: prompt)],
                temperature: settings.temperature,
                maxTokens: settings.maximumResponseTokens
            ))
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            if backend == .openRouter {
                request.setValue("Lush", forHTTPHeaderField: "X-OpenRouter-Title")
            }
            request.httpBody = try JSONEncoder().encode(CompatibleRequest(
                model: model,
                messages: [.init(role: "user", content: prompt)],
                temperature: backend == .openAI ? nil : settings.temperature,
                maxTokens: backend == .openAI ? nil : settings.maximumResponseTokens,
                maxCompletionTokens: backend == .openAI ? settings.maximumResponseTokens : nil
            ))
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RuntimeError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            let message = envelope?.error?.message ?? envelope?.message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw RuntimeError.requestFailed(http.statusCode, message)
        }

        if backend == .anthropic {
            let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
            let text = decoded.content.compactMap(\.text).joined(separator: "\n")
            guard !text.isEmpty else { throw RuntimeError.invalidResponse }
            return text
        }

        let decoded = try JSONDecoder().decode(CompatibleResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content, !text.isEmpty else {
            throw RuntimeError.invalidResponse
        }
        return text
    }
}
