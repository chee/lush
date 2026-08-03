import Foundation
import NaturalLanguage

@MainActor
final class SemanticSearchIndex {
    private struct Chunk: Codable {
        var url: String
        var name: String
        var text: String
        var vector: [Double]
    }

    private struct Store: Codable {
        var chunks: [Chunk]
    }

    private let embedding = NLEmbedding.sentenceEmbedding(for: .english)
    private var chunks: [Chunk] = []
    private var loaded = false
    private var saveTask: Task<Void, Never>?

    private var storeURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let dir = support.appendingPathComponent("LushCore", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("semantic-search.json")
    }

    var isAvailable: Bool {
        embedding != nil
    }

    func index(url: String, name: String, spansJson: String) {
        guard let embedding else { return }
        loadIfNeeded()
        let spans = SpanNode.decodeList(spansJson)
        let title = RichText.title(from: spans)
        let displayName = title.isEmpty ? (name.isEmpty ? "Untitled" : name) : title
        let text = Self.plainText(from: spans)
        let nextChunks = Self.chunks(for: text)
            .compactMap { text -> Chunk? in
                guard let vector = embedding.vector(for: text) else { return nil }
                return Chunk(
                    url: url,
                    name: displayName,
                    text: Self.snippet(from: text),
                    vector: Self.normalized(vector)
                )
            }
        chunks.removeAll { $0.url == url }
        chunks.append(contentsOf: nextChunks)
        scheduleSave()
    }

    func remove(url: String) {
        loadIfNeeded()
        chunks.removeAll { $0.url == url }
        scheduleSave()
    }

    func search(_ query: String, excluding excluded: Set<String> = []) -> [SearchHit] {
        guard let embedding else { return [] }
        loadIfNeeded()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let rawVector = embedding.vector(for: query) else { return [] }
        let vector = Self.normalized(rawVector)
        var best: [String: (score: Double, chunk: Chunk)] = [:]
        for chunk in chunks where !excluded.contains(chunk.url) {
            let score = Self.dot(vector, chunk.vector)
            guard score > 0.36 else { continue }
            if best[chunk.url]?.score ?? -.infinity < score {
                best[chunk.url] = (score, chunk)
            }
        }
        return best.values
            .sorted { $0.score > $1.score }
            .prefix(12)
            .map {
                SearchHit(
                    url: $0.chunk.url,
                    name: $0.chunk.name,
                    snippet: $0.chunk.text
                )
            }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: storeURL),
              let store = try? JSONDecoder().decode(Store.self, from: data)
        else { return }
        chunks = store.chunks
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        let store = Store(chunks: chunks)
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: storeURL, options: [.atomic])
    }

    private static func plainText(from spans: [SpanNode]) -> String {
        var parts: [String] = []
        for span in spans {
            switch span {
            case .block(let block):
                if block.isEmbedBlock, let html = block.htmlSource {
                    parts.append(html)
                }
            case .text(let text, _):
                parts.append(text)
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func chunks(for text: String) -> [String] {
        let normalized = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !normalized.isEmpty else { return [] }
        var chunks: [String] = []
        var current = ""
        for paragraph in normalized.components(separatedBy: "\n") {
            if current.count + paragraph.count > 900, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            if !current.isEmpty { current += "\n" }
            current += paragraph
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return Array(chunks.prefix(8))
    }

    private static func snippet(from text: String) -> String {
        var snippet = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if snippet.count > 140 {
            snippet = String(snippet.prefix(140)) + "..."
        }
        return snippet
    }

    private static func normalized(_ vector: [Double]) -> [Double] {
        let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }

    private static func dot(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
