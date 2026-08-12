import Foundation

/// How much prompt a model will actually take. Where the model says so — the
/// OpenRouter catalogue, Ollama's API, an MLX model's config.json — that
/// number is used. Where nothing says so, a conservative guess starts things
/// off and an overflow teaches the real ceiling, remembered per model.
enum ModelContextWindow {
    /// Apple's on-device model is a fixed 4096-token window, prompt and
    /// response together.
    static let appleIntelligenceTokens = 4_096

    /// Nothing declares a window for a bare endpoint, and asking costs a
    /// request; every current hosted model is at least this big.
    static let unknownEndpointTokens = 16_000

    /// A downloaded model whose config could not be read.
    static let unknownLocalTokens = 4_096

    private static let declaredKey = "modelContext.declared."
    private static let ceilingKey = "modelContext.ceiling."
    private static let parametersKey = "modelContext.parameters."

    /// How big the model is, in billions of parameters, when it says so.
    /// Ollama and MLX are ways of running a model, not sizes — the same
    /// runner serves a 350M model and a 120B one.
    static func parameterBillions(for choice: ModelChoice) async -> Double? {
        switch choice.backend {
        case .appleIntelligence:
            return 3
        case .mlx:
            return sizeInName(choice.model) ?? sizeInName(
                LocalModelSettings.mlxConfig(for: .noteChat, choice: choice).repo
            )
        case .ollama:
            let cached = UserDefaults.standard.double(forKey: parametersKey + choice.id)
            if cached > 0 { return cached }
            _ = await declaredTokens(for: choice)
            let stored = UserDefaults.standard.double(forKey: parametersKey + choice.id)
            return stored > 0 ? stored : sizeInName(choice.model)
        case .openRouter, .openAI, .anthropic, .compatible:
            return nil
        }
    }

    /// "LFM2.5-8B-MLX-8bit" is 8B, "qwen3:0.6b" is 0.6B, "…-350M-4bit" is 0.35B.
    static func sizeInName(_ name: String) -> Double? {
        var best: Double?
        var number = ""
        for character in name.lowercased() {
            if character.isNumber || character == "." {
                number.append(character)
                continue
            }
            defer { number = "" }
            guard !number.isEmpty, let value = Double(number) else { continue }
            if character == "b", value >= 0.1, value <= 2_000 {
                best = max(best ?? 0, value)
            } else if character == "m", value >= 50 {
                best = max(best ?? 0, value / 1_000)
            }
        }
        return best
    }

    /// Characters of prompt to aim for, after leaving room for the reply.
    static func promptCharacters(for choice: ModelChoice, response: Int) async -> Int {
        let tokens = await declaredTokens(for: choice) ?? fallbackTokens(for: choice)
        // ~3.5 characters a token for English prose, and keep a fifth of the
        // window spare for the system prompt and the model's own overhead
        let usable = max(tokens - response, 512)
        let derived = Int(Double(usable) * 3.5 * 0.8)
        guard let ceiling = learnedCeiling(for: choice) else { return derived }
        return max(1_200, min(derived, ceiling))
    }

    /// Called when a model refuses a prompt for being too long: that size, and
    /// anything near it, is not attempted again for this model.
    static func remember(overflowAt characters: Int, for choice: ModelChoice) {
        let ceiling = max(1_200, characters * 2 / 3)
        guard ceiling < (learnedCeiling(for: choice) ?? Int.max) else { return }
        UserDefaults.standard.set(ceiling, forKey: ceilingKey + choice.id)
    }

    static func learnedCeiling(for choice: ModelChoice) -> Int? {
        let value = UserDefaults.standard.integer(forKey: ceilingKey + choice.id)
        return value > 0 ? value : nil
    }

    /// The window the model itself reports, cached once found.
    static func declaredTokens(for choice: ModelChoice) async -> Int? {
        if choice.backend == .appleIntelligence { return appleIntelligenceTokens }
        let cached = UserDefaults.standard.integer(forKey: declaredKey + choice.id)
        if cached > 0 { return cached }

        let found: Int? = switch choice.backend {
        case .mlx: mlxTokens(for: choice)
        case .ollama: await ollamaTokens(model: choice.model)
        default: nil
        }
        if let found, found > 0 {
            UserDefaults.standard.set(found, forKey: declaredKey + choice.id)
        }
        return found
    }

    /// The OpenRouter catalogue carries every model's context length; the
    /// settings screen stores them as it lists them.
    static func record(_ tokens: Int, for choice: ModelChoice) {
        guard tokens > 0 else { return }
        UserDefaults.standard.set(tokens, forKey: declaredKey + choice.id)
    }

    private static func fallbackTokens(for choice: ModelChoice) -> Int {
        switch choice.backend {
        case .appleIntelligence: appleIntelligenceTokens
        case .mlx: unknownLocalTokens
        case .ollama, .openRouter, .openAI, .anthropic, .compatible: unknownEndpointTokens
        }
    }

    private static func mlxTokens(for choice: ModelChoice) -> Int? {
        let config = LocalModelSettings.mlxConfig(for: .noteChat, choice: choice)
        let repo = config.repo.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [URL] = []
        if let localPath = config.localPath, !localPath.isEmpty {
            let url = URL(fileURLWithPath: localPath)
            candidates.append(url.appendingPathComponent("config.json"))
            candidates.append(url.deletingLastPathComponent().appendingPathComponent("config.json"))
        }
        if !repo.isEmpty {
            // where mlx-swift's hub puts a snapshot
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            if let documents {
                candidates.append(
                    documents
                        .appendingPathComponent("huggingface/models", isDirectory: true)
                        .appendingPathComponent(repo, isDirectory: true)
                        .appendingPathComponent("config.json")
                )
            }
        }
        for url in candidates {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize,
                  size >= 0,
                  size <= 1_048_576,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  data.count <= 1_048_576,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let tokens = contextLength(in: json) { return tokens }
        }
        return nil
    }

    private static func contextLength(in json: [String: Any]) -> Int? {
        for key in ["max_position_embeddings", "max_sequence_length", "model_max_length", "context_length"] {
            if let value = json[key] as? Int, value > 0 { return value }
        }
        if let nested = json["text_config"] as? [String: Any] {
            return contextLength(in: nested)
        }
        return nil
    }

    private static func ollamaTokens(model: String) async -> Int? {
        let endpoint = LocalModelSettings.endpoint(for: .ollama)
        guard !model.isEmpty,
              let base = URL(string: endpoint)?.host.map({ host in
                  "http://\(host):\(URL(string: endpoint)?.port ?? 11_434)"
              }),
              let url = URL(string: "\(base)/api/show")
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        request.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let info = json["model_info"] as? [String: Any] ?? [:]

        // the same answer says how big the model is; keep that too
        let details = json["details"] as? [String: Any]
        let billions = (info["general.parameter_count"] as? Int).map { Double($0) / 1e9 }
            ?? (details?["parameter_size"] as? String).flatMap(sizeInName)
        if let billions, billions > 0 {
            UserDefaults.standard.set(
                billions, forKey: parametersKey + ModelChoice(backend: .ollama, model: model).id
            )
        }

        // context length is keyed by architecture, e.g. "llama.context_length"
        for (key, value) in info where key.hasSuffix(".context_length") {
            if let tokens = value as? Int, tokens > 0 { return tokens }
        }
        return nil
    }
}
