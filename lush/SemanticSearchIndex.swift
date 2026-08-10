import Foundation
import CryptoKit

/// Chunks note text, embeds it through `QueryEmbedding`, and hands the vectors
/// to the core, which stores them in search.sqlite3 beside the full-text index
/// and does the similarity scan.
actor SemanticSearchIndex {
    private static let digestVersion = "2"
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

    func index(url: String, name: String, spansJson: String) async {
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
        let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(digestVersion):\(hash)"
    }

    private static func plainText(from spans: [SpanNode]) -> String {
        var context: [String] = []
        var body: [String] = []
        for span in spans {
            switch span {
            case .block(let block):
                if block.type == "context" {
                    context.append(contextText(block))
                }
                if block.isEmbedBlock, let html = block.htmlSource {
                    body.append(html)
                }
                if let event = block.calendarEventSearchText {
                    body.append(event)
                }
            case .text(let text, _):
                body.append(text)
            }
        }
        return (context + body).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func contextText(_ block: BlockValue) -> String {
        var parts = ["Logline"]
        if let raw = (block.attrs["created"] ?? block.attrs["ts"])?.stringValue,
           let date = ISO8601DateFormatter().date(from: raw) {
            let hour = Calendar.current.component(.hour, from: date)
            switch hour {
            case 5..<12: parts.append("morning daytime")
            case 12..<17: parts.append("afternoon daytime")
            case 17..<21: parts.append("evening")
            default: parts.append("night nighttime")
            }
            parts.append(date.formatted(.dateTime.weekday(.wide)))
        }
        if let location = block.attrs["location"]?.stringValue {
            parts.append(location)
        }
        if let weather = block.attrs["weather"]?.stringValue {
            parts.append(weather)
            let value = weather.lowercased()
            if value.contains("rain") || value.contains("drizzle")
                || value.contains("shower") || value.contains("thunder") {
                parts.append("wet rainy")
            }
            if value.contains("clear") || value.contains("sun") {
                parts.append("sunny sunshine")
            }
            if value.contains("cloud") || value.contains("overcast") {
                parts.append("cloudy")
            }
            if value.contains("snow") {
                parts.append("snowy cold")
            }
            if value.contains("fog") || value.contains("mist") {
                parts.append("foggy misty")
            }
        }
        let reserved = Set(["created", "ts", "location", "lat", "lon", "weather"])
        for (key, value) in block.attrs where !reserved.contains(key) {
            if let text = value.stringValue { parts.append(text) }
        }
        return parts.joined(separator: " ")
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
