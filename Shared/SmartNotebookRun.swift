import Foundation
import NaturalLanguage

extension SmartNotebook: Identifiable {
    var displayName: String { name.isEmpty ? "Smart Notebook" : name }
}

enum SmartNotebookKind: String, CaseIterable {
    case any = ""
    case note = "note"
    case file = "file"
    case script = "script"
    case patchwork = "patchwork"

    var label: String {
        switch self {
        case .any: "Anything"
        case .note: "Notes"
        case .file: "Files"
        case .script: "Scripts"
        case .patchwork: "Patchwork Docs"
        }
    }

    func matches(_ kind: String) -> Bool {
        switch self {
        case .any: kind != "folder"
        case .note: kind == "lush" || kind == "rich"
        case .file: kind == "file"
        case .script: kind == "lush:script"
        case .patchwork:
            !["folder", "lush", "rich", "lush:script", "file"].contains(kind)
        }
    }
}

/// What the filters need to know about the tree: a doc's kind and the way up
/// to its ancestors. Lush builds this from the tree it already holds, the
/// helper walks the roots for it.
struct NotebookTree {
    var kinds: [String: String] = [:]
    var parents: [String: String] = [:]

    func contains(_ url: String, under folderUrl: String) -> Bool {
        var parent = parents[url]
        while let current = parent {
            if current == folderUrl { return true }
            parent = parents[current]
        }
        return false
    }

    static func walk(core: Core, roots: [String]) async -> NotebookTree {
        var tree = NotebookTree()
        var queue = roots
        while let url = queue.popLast() {
            for entry in await core.folderEntriesOf(url: url) {
                tree.kinds[entry.url] = entry.kind
                tree.parents[entry.url] = url
                if entry.kind == "folder" { queue.append(entry.url) }
            }
        }
        core.setSearchParents(parents: tree.parents)
        return tree
    }
}

/// The one definition of what a smart notebook holds, so Lush and the helper
/// always arrive at the same list. Blocking: call it off the main actor.
enum SmartNotebookRun {
    static func hits(
        _ folder: SmartNotebook,
        core: Core,
        tree: NotebookTree,
        vector: [Float]?
    ) -> [SearchHit] {
        let recent = core.recentNotes(limit: 5000)
        let query = folder.query.trimmingCharacters(in: .whitespaces)
        // The scope goes to the index rather than being applied to the results:
        // the text search keeps only its top matches, and narrowing afterwards
        // would leave a small folder with whatever survived of everywhere else.
        let filter = SearchFilter(
            scope: folder.scope.isEmpty ? nil : folder.scope,
            tags: [],
            whenFrom: nil,
            whenTo: nil
        )
        var hits: [SearchHit]
        if query.isEmpty {
            hits = recent.map { SearchHit(url: $0.url, name: $0.name, snippet: "") }
        } else {
            hits = core.searchNotes(query: query, filter: filter)
            if let vector, !query.contains("\"") {
                hits += core.semanticSearch(
                    vector: vector,
                    limit: 12,
                    excluding: hits.map(\.url),
                    filter: filter
                )
            }
        }
        let modified = Dictionary(
            recent.map { ($0.url, seconds($0.modified)) },
            uniquingKeysWith: { first, _ in first }
        )
        let kind = SmartNotebookKind(rawValue: folder.kind) ?? .any
        let cutoff = folder.withinDays > 0
            ? Date().timeIntervalSince1970 - Double(folder.withinDays) * 86_400
            : nil
        return hits.filter { hit in
            guard let nodeKind = tree.kinds[hit.url], kind.matches(nodeKind) else { return false }
            if !folder.scope.isEmpty, !tree.contains(hit.url, under: folder.scope) { return false }
            if let cutoff { return (modified[hit.url] ?? 0) >= cutoff }
            return true
        }
    }

    private static func seconds(_ stamp: Int64) -> TimeInterval {
        // older docs recorded milliseconds
        let value = TimeInterval(stamp)
        return value > 4_000_000_000 ? value / 1000 : value
    }
}

/// Sentence embeddings for search queries. Cached by text: a saved search runs
/// again on every change, and the query rarely moves.
actor QueryEmbedding {
    static let shared = QueryEmbedding()

    private var model: NLEmbedding?
    private var loaded = false
    private var cache: [String: [Float]] = [:]

    func vector(for query: String) -> [Float]? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        if let cached = cache[query] { return cached }
        if !loaded {
            loaded = true
            model = NLEmbedding.sentenceEmbedding(for: .english)
        }
        guard let raw = model?.vector(for: query) else { return nil }
        let magnitude = sqrt(raw.reduce(0) { $0 + $1 * $1 })
        let vector = magnitude > 0 ? raw.map { Float($0 / magnitude) } : raw.map(Float.init)
        cache[query] = vector
        return vector
    }
}
