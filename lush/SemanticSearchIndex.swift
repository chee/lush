import Foundation
import CryptoKit

/// Chunks note text, embeds it through `QueryEmbedding`, and hands the vectors
/// to the core, which stores them in search.sqlite3 beside the full-text index
/// and does the similarity scan.
actor SemanticSearchIndex {
    private static let digestVersion = "3"
    private static let legacyStoreByteLimit = 16 * 1024 * 1024
    private var core: Core?

    func attach(_ core: Core) {
        self.core = core
        migrateLegacyStore()
    }

    func indexedUrls() -> Set<String> {
        guard let core else { return [] }
        return Set(core.noteEmbeddingDigests().keys)
    }

    func contextIndexedUrls() -> Set<String> {
        guard let core else { return [] }
        return Set(core.noteEmbeddingDigests().compactMap { url, digest in
            digest.hasPrefix("\(Self.digestVersion):") ? url : nil
        })
    }

    func indexFile(url: String, name: String, text: String) async {
        guard let core else { return }
        let digest = Self.digest(of: name + "\n" + text)
        if core.noteEmbeddingDigest(url: url) == digest { return }
        guard !text.isEmpty else { return }
        let chunks = await Self.embed(Self.chunks(for: text))
        try? core.setNoteEmbeddings(url: url, name: name, digest: digest, chunks: chunks)
    }

    func index(url: String, name: String, body: String, context: String) async {
        guard let core else { return }
        let displayName = name.isEmpty ? "Untitled" : name
        let text = context.isEmpty ? body : context + "\n" + body
        let digest = Self.digest(of: displayName + "\n" + text)
        // Unchanged text still needs the row rewritten if the note was renamed,
        // but not re-embedded — inference is the expensive half.
        if core.noteEmbeddingDigest(url: url) == digest {
            return
        }
        let chunks = await Self.embed(Self.chunks(for: text))
        try? core.setNoteEmbeddings(url: url, name: displayName, digest: digest, chunks: chunks)
    }

    func remove(url: String) {
        core?.removeNoteEmbeddings(url: url)
    }

    func search(
        _ query: String,
        excluding excluded: Set<String> = [],
        in scope: String? = nil
    ) async -> [SearchHit] {
        guard let core, let vector = await QueryEmbedding.shared.vector(for: query) else {
            return []
        }
        return core.semanticSearch(
            vector: vector,
            limit: 12,
            excluding: Array(excluded),
            filter: SearchFilter(scope: scope, tags: [], whenFrom: nil, whenTo: nil)
        )
    }

    private static func embed(_ chunks: [String]) async -> [EmbeddingChunk] {
        var embedded: [EmbeddingChunk] = []
        for chunk in chunks {
            guard let vector = await QueryEmbedding.shared.embed(chunk) else { continue }
            embedded.append(EmbeddingChunk(text: snippet(from: chunk), vector: vector))
        }
        return embedded
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
        LushShared.coreDataDirectory().appendingPathComponent("semantic-search.json")
    }

    /// Move the old JSON store into the core once, so an upgrade doesn't have to
    /// re-run inference over every note. The file is removed on success.
    private func migrateLegacyStore() {
        guard let core else { return }
        let url = legacyStoreURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size >= 0
        else { return }
        guard size <= Self.legacyStoreByteLimit else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        guard data.count <= Self.legacyStoreByteLimit else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let store = try? JSONDecoder().decode(LegacyStore.self, from: data) else { return }
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
        let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(digestVersion):\(hash)"
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
}
