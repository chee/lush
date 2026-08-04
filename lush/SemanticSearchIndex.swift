import Foundation
import CryptoKit
import NaturalLanguage

actor SemanticSearchIndex {
    private struct Chunk: Codable {
        var text: String
        var vector: [Double]
    }

    private struct Entry: Codable {
        var name: String
        var digest: String
        var chunks: [Chunk]
    }

    private struct Store: Codable {
        var entries: [String: Entry]
    }

    private var embedding: NLEmbedding?
    private var entries: [String: Entry] = [:]
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

    func indexedUrls() -> Set<String> {
        loadIfNeeded()
        return Set(entries.keys)
    }

    func index(url: String, name: String, spansJson: String) {
        loadIfNeeded()
        guard let embedding else { return }
        let spans = SpanNode.decodeList(spansJson)
        let title = RichText.title(from: spans)
        let displayName = title.isEmpty ? (name.isEmpty ? "Untitled" : name) : title
        let text = Self.plainText(from: spans)
        let digest = Self.digest(of: text)
        if let existing = entries[url], existing.digest == digest {
            guard existing.name != displayName else { return }
            entries[url]?.name = displayName
            scheduleSave()
            return
        }
        let chunks = Self.chunks(for: text).compactMap { text -> Chunk? in
            guard let vector = embedding.vector(for: text) else { return nil }
            return Chunk(text: Self.snippet(from: text), vector: Self.normalized(vector))
        }
        entries[url] = Entry(name: displayName, digest: digest, chunks: chunks)
        scheduleSave()
    }

    func remove(url: String) {
        loadIfNeeded()
        guard entries.removeValue(forKey: url) != nil else { return }
        scheduleSave()
    }

    func search(_ query: String, excluding excluded: Set<String> = []) -> [SearchHit] {
        loadIfNeeded()
        guard let embedding else { return [] }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let rawVector = embedding.vector(for: query) else { return [] }
        let vector = Self.normalized(rawVector)
        var best: [String: (score: Double, name: String, text: String)] = [:]
        for (url, entry) in entries where !excluded.contains(url) {
            for chunk in entry.chunks {
                let score = Self.dot(vector, chunk.vector)
                guard score > 0.36 else { continue }
                if best[url]?.score ?? -.infinity < score {
                    best[url] = (score, entry.name, chunk.text)
                }
            }
        }
        return best
            .sorted { $0.value.score > $1.value.score }
            .prefix(12)
            .map { SearchHit(url: $0.key, name: $0.value.name, snippet: $0.value.text) }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        embedding = NLEmbedding.sentenceEmbedding(for: .english)
        guard let data = try? Data(contentsOf: storeURL),
              let store = try? JSONDecoder().decode(Store.self, from: data)
        else { return }
        entries = store.entries
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    private func save() {
        let store = Store(entries: entries)
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: storeURL, options: [.atomic])
    }

    private static func digest(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
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
