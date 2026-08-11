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
        var seen: Set<String> = []
        while let current = parent {
            if current == folderUrl { return true }
            guard seen.insert(current).inserted else { return false }
            parent = parents[current]
        }
        return false
    }

    static func walk(core: Core, roots: [String]) async -> NotebookTree {
        var tree = NotebookTree()
        var queue = roots
        var seen: Set<String> = []
        while let url = queue.popLast() {
            guard seen.insert(url).inserted else { continue }
            tree.kinds[url] = "folder"
            for entry in await core.folderEntriesOf(url: url) {
                tree.kinds[entry.url] = entry.kind
                tree.parents[entry.url] = url
                if entry.kind == "folder" { queue.append(entry.url) }
            }
        }
        core.setSearchParents(parents: tree.parents.map { SearchParent(url: $0.key, parent: $0.value) })
        return tree
    }
}

/// The one definition of what a smart notebook holds, so Lush and the helper
/// always arrive at the same list. Blocking: call it off the main actor.
enum SmartNotebookRun {
    /// Every text a run of this notebook has to ask the index about, as the
    /// index wants it. Title and tag rules are read off the index entries
    /// instead, so they never come through here. The caller embeds these
    /// before the blocking part.
    static func searchQueries(_ folder: SmartNotebook) -> [String] {
        var queries: [String] = []
        walk(folder.rootRule) { rule in
            guard case let .text(.anything, false, exact, text) = rule.body else { return }
            let query = searchQuery(SearchSyntax(text).text, exact: exact)
            if !query.isEmpty, !queries.contains(query) { queries.append(query) }
        }
        return queries
    }

    /// The list every run needs: one read of the index, shared across a cycle.
    static let corpusLimit: UInt32 = 5000

    /// `notes` is the whole index; a cycle over several notebooks reads it once
    /// and hands the same list to each.
    static func hits(
        _ folder: SmartNotebook,
        core: Core,
        tree: NotebookTree,
        vectors: [String: [Float]],
        notes: [IndexedNote]
    ) -> [SearchHit] {
        let root = folder.rootRule
        // The scope goes to the index rather than being applied to the results:
        // the text search keeps only its top matches, and narrowing afterwards
        // would leave a small folder with whatever survived of everywhere else.
        // Only a scope every hit must be under can go there.
        let scope = requiredFolder(root)
        let filter = SearchFilter(scope: scope, tags: [], whenFrom: nil, whenTo: nil)
        var matched: [String: Set<String>] = [:]
        var snippets: [String: String] = [:]
        var ranked: [String] = []
        var seen: Set<String> = []
        for query in searchQueries(folder) {
            var hits = core.searchNotes(query: query, filter: filter)
            if let vector = vectors[query], !query.contains("\"") {
                hits += core.semanticSearch(
                    vector: vector,
                    limit: 12,
                    excluding: hits.map(\.url),
                    filter: filter
                )
            }
            matched[query] = Set(hits.map(\.url))
            for hit in hits {
                if snippets[hit.url] == nil { snippets[hit.url] = hit.snippet }
                if seen.insert(hit.url).inserted { ranked.append(hit.url) }
            }
        }
        let byUrl = Dictionary(notes.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Date().timeIntervalSince1970
        var candidates = ranked.compactMap { byUrl[$0] }
        // A tree that can be satisfied without the index — no text rule, or
        // text only in an `any` branch — has to look at every doc, not just at
        // what the searches turned up.
        if matches(root, note: nil, tree: tree, matched: matched, now: now) {
            candidates += notes.filter { !seen.contains($0.url) }
        }
        return candidates
            .filter { note in
                guard let kind = tree.kinds[note.url], kind != "folder" else { return false }
                return matches(root, note: note, tree: tree, matched: matched, now: now)
            }
            .map { note in
                SearchHit(url: note.url, name: note.title, snippet: snippets[note.url] ?? "")
            }
    }

    /// A nil `note` asks the structural question instead of the per-doc one:
    /// could this tree hold a doc the searches never turned up?
    private static func matches(
        _ rule: SmartRule,
        note: IndexedNote?,
        tree: NotebookTree,
        matched: [String: Set<String>],
        now: TimeInterval
    ) -> Bool {
        func check(_ rule: SmartRule) -> Bool {
            matches(rule, note: note, tree: tree, matched: matched, now: now)
        }
        switch rule.body {
        case let .group(.all, rules):
            return rules.allSatisfy(check)
        case let .group(.any, rules):
            return rules.isEmpty ? false : rules.contains(where: check)
        case let .text(field, whole, exact, text):
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return true }
            switch field {
            case .anything:
                let syntax = SearchSyntax(text)
                let query = searchQuery(syntax.text, exact: exact)
                guard let note else { return query.isEmpty }
                return syntax.matches(note)
                    && (query.isEmpty || matched[query]?.contains(note.url) == true)
            case .title:
                guard let note else { return true }
                return compare(note.title, text, whole: whole, exact: exact)
            case .tag:
                guard let note else { return true }
                return note.tags.contains { compare($0, text, whole: whole, exact: exact) }
            }
        case let .kind(kind):
            guard let note else { return true }
            return tree.kinds[note.url].map(kind.matches) ?? false
        case let .folder(folderUrl):
            guard let note else { return true }
            return folderUrl.isEmpty || tree.contains(note.url, under: folderUrl)
        case let .date(on, op, age, day):
            guard let note else { return true }
            let stamp = Date(docTimestamp: on == .created ? note.created : note.modified)
                .timeIntervalSince1970
            switch op {
            case .within:
                return age == .any || stamp >= now - Double(age.rawValue) * 86_400
            case .before:
                guard let start = smartRuleDayStart(day) else { return true }
                return stamp > 0 && stamp < start.timeIntervalSince1970
            case .after:
                guard let start = smartRuleDayStart(day) else { return true }
                return stamp >= start.timeIntervalSince1970 + 86_400
            }
        }
    }

    /// "Like" is loose about case and accents; "exactly" wants the characters
    /// as typed.
    private static func compare(_ value: String, _ text: String, whole: Bool, exact: Bool) -> Bool {
        if exact {
            return whole ? value == text : value.contains(text)
        }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if whole {
            return value.compare(text, options: options) == .orderedSame
        }
        return value.range(of: text, options: options) != nil
    }

    /// A folder every hit is guaranteed to be under: one `in` rule, on the
    /// root's `all` chain, and no others anywhere.
    private static func requiredFolder(_ root: SmartRule) -> String? {
        var folders: [String] = []
        walk(root) { rule in
            if case let .folder(url) = rule.body, !url.isEmpty { folders.append(url) }
        }
        guard folders.count == 1, case let .group(.all, rules) = root.body else { return nil }
        return rules.contains { $0.body == .folder(folders[0]) } ? folders[0] : nil
    }

    private static func walk(_ rule: SmartRule, _ visit: (SmartRule) -> Void) {
        visit(rule)
        for child in rule.children { walk(child, visit) }
    }

    /// Sentence vectors for every text rule, keyed by the query they belong to.
    /// Quoted text is asking for that text, not for something like it.
    static func vectors(for folder: SmartNotebook) async -> [String: [Float]] {
        var vectors: [String: [Float]] = [:]
        for query in searchQueries(folder) where !query.contains("\"") {
            vectors[query] = await QueryEmbedding.shared.vector(for: query)
        }
        return vectors
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
        guard let vector = embed(query) else { return nil }
        cache[query] = vector
        return vector
    }

    /// Uncached: document text is embedded once, and there is a lot of it.
    func embed(_ text: String) -> [Float]? {
        if !loaded {
            loaded = true
            model = NLEmbedding.sentenceEmbedding(for: .english)
        }
        guard let raw = model?.vector(for: text) else { return nil }
        let magnitude = sqrt(raw.reduce(0) { $0 + $1 * $1 })
        return magnitude > 0 ? raw.map { Float($0 / magnitude) } : raw.map(Float.init)
    }
}
