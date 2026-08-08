import Foundation
import CryptoKit
import NaturalLanguage

/// Embeds note text with NLEmbedding and hands the vectors to the core, which
/// stores them in search.sqlite3 beside the full-text index and does the
/// similarity scan. This actor owns only the embedding model.
actor SemanticSearchIndex {
    private var core: Core?
    private var embedding: NLEmbedding?
    private var loadedEmbedding = false

    func attach(_ core: Core) {
        self.core = core
        migrateLegacyStore()
    }

    func indexedUrls() -> Set<String> {
        guard let core else { return [] }
        return Set(core.noteEmbeddingDigests().keys)
    }

    func indexFile(url: String, name: String, text: String) {
        guard let core else { return }
        let digest = Self.digest(of: name + "\n" + text)
        if core.noteEmbeddingDigest(url: url) == digest { return }
        guard !text.isEmpty, let embedding = embeddingModel() else { return }
        let chunks = Self.chunks(for: text).compactMap { chunk -> EmbeddingChunk? in
            guard let vector = embedding.vector(for: chunk) else { return nil }
            return EmbeddingChunk(text: Self.snippet(from: chunk), vector: Self.unit(vector))
        }
        try? core.setNoteEmbeddings(url: url, name: name, digest: digest, chunks: chunks)
    }

    func index(url: String, name: String, spansJson: String) {
        guard let core else { return }
        let spans = SpanNode.decodeList(spansJson)
        let title = RichText.title(from: spans)
        let displayName = title.isEmpty ? (name.isEmpty ? "Untitled" : name) : title
        let text = Self.plainText(from: spans)
        let digest = Self.digest(of: displayName + "\n" + text)
        // Unchanged text still needs the row rewritten if the note was renamed,
        // but not re-embedded — inference is the expensive half.
        if core.noteEmbeddingDigest(url: url) == digest {
            return
        }
        guard let embedding = embeddingModel() else { return }
        let chunks = Self.chunks(for: text).compactMap { chunk -> EmbeddingChunk? in
            guard let vector = embedding.vector(for: chunk) else { return nil }
            return EmbeddingChunk(text: Self.snippet(from: chunk), vector: Self.unit(vector))
        }
        try? core.setNoteEmbeddings(url: url, name: displayName, digest: digest, chunks: chunks)
    }

    func remove(url: String) {
        core?.removeNoteEmbeddings(url: url)
    }

    func search(_ query: String, excluding excluded: Set<String> = []) -> [SearchHit] {
        guard let core else { return [] }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              let embedding = embeddingModel(),
              let raw = embedding.vector(for: query)
        else { return [] }
        return core.semanticSearch(
            vector: Self.unit(raw),
            limit: 12,
            excluding: Array(excluded)
        )
    }

    private func embeddingModel() -> NLEmbedding? {
        if !loadedEmbedding {
            loadedEmbedding = true
            embedding = NLEmbedding.sentenceEmbedding(for: .english)
        }
        return embedding
    }

    // MARK: legacy store

    private struct LegacyChunk: Codable {
        var text: String
        var vector: [Double]
    }

    private struct LegacyEntry: Codable {
        var name: String
        var digest: String
        var chunks: [LegacyChunk]
    }

    private struct LegacyStore: Codable {
        var entries: [String: LegacyEntry]
    }

    private var legacyStoreURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return support
            .appendingPathComponent("LushCore", isDirectory: true)
            .appendingPathComponent("semantic-search.json")
    }

    /// Move the old JSON store into the core once, so an upgrade doesn't have to
    /// re-run inference over every note. The file is removed on success.
    private func migrateLegacyStore() {
        guard let core else { return }
        let url = legacyStoreURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(LegacyStore.self, from: data)
        else { return }
        for (noteUrl, entry) in store.entries {
            let chunks = entry.chunks.map {
                EmbeddingChunk(text: $0.text, vector: $0.vector.map(Float.init))
            }
            try? core.setNoteEmbeddings(
                url: noteUrl,
                name: entry.name,
                digest: entry.digest,
                chunks: chunks
            )
        }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: text

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

    private static func unit(_ vector: [Double]) -> [Float] {
        let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard magnitude > 0 else { return vector.map(Float.init) }
        return vector.map { Float($0 / magnitude) }
    }
}
