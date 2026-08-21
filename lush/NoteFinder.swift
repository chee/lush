import Foundation
import Observation
import SwiftUI

/// One question's worth of index reading. Everything in the catalog is a read —
/// there is no tool here that could change a note, and nothing to apply
/// afterwards. The answer is which notes to open.
@MainActor
@Observable
final class NoteFinderSession {
    let model: NotesModel
    /// The notebook the search field was narrowed to. Searches stay inside it
    /// unless the model names another folder.
    let scope: String?
    private(set) var calls: [NoteChatToolCall] = []
    /// Every note a tool has surfaced, first seen first. An answer that names
    /// none of them still has these to show.
    private(set) var found: [SearchHit] = []

    init(model: NotesModel, scope: String? = nil) {
        self.model = model
        self.scope = scope
    }

    /// `brief` is the same catalog spelled as tersely as it can be read, for
    /// models whose context window cannot afford the long one.
    static func catalog(brief: Bool) -> String {
        brief ? briefCatalog : fullCatalog
    }

    private static let clauses = """
    tag:cooking, title:invoice, kind:note, has:image, when:2026-04-01, \
    created:>2026-01-01, changed:<2026-06-01
    """

    private static let briefCatalog = """
    Tools, arguments as JSON:
    search_notes{query,folder_url?,limit?} — every note, by text and by meaning
    recent_notes{limit?} — the notes worked on most recently
    list_folder{folder_url?} — what is in a folder, or the notebooks themselves
    read_note{url} — one note, at a url a search gave you
    A query may carry \(clauses).
    """

    private static let fullCatalog = """
    search_notes {"query": string, "folder_url": string?, "limit": int?} — searches
      every note by text and by meaning, best first. The query is words to look for,
      not a sentence: two or three of them find more than a whole question does.
    recent_notes {"limit": int?} — the notes worked on most recently, newest first
    list_folder {"folder_url": string?} — what is in that folder; without one, the
      notebooks at the top of the tree
    read_note {"url": string} — one note's text, at a url a search gave you

    A query may also carry \(clauses). Those narrow a search rather than being
    searched for, and one on its own — "tag:cooking" — lists everything it matches.
    """

    /// Runs a tool and records the call. Nothing here writes, so every result is
    /// simply what the index says.
    func run(_ name: String, arguments: [String: Any]) async -> String {
        let result = await execute(name, arguments: arguments)
        calls.append(NoteChatToolCall(name: name, detail: NoteChatEdits.short(describe(arguments), limit: 80)))
        return result
    }

    private func describe(_ arguments: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func execute(_ name: String, arguments: [String: Any]) async -> String {
        switch name {
        case "search_notes", "find_notes", "search", "find":
            guard let query = Self.string(arguments["query"])
                ?? Self.string(arguments["text"])
                ?? Self.string(arguments["q"])
            else { return "search_notes needs a query." }
            let folder = Self.string(arguments["folder_url"]) ?? scope
            let limit = min(max(Self.count(arguments["limit"]) ?? 8, 1), 20)
            let hits = await model.search(query, in: folder)
            guard !hits.isEmpty else { return "Nothing matched \(query)." }
            return remember(Array(hits.prefix(limit)))

        case "recent_notes", "recents", "recent":
            await model.refreshRecents()
            let limit = min(max(Self.count(arguments["limit"]) ?? 15, 1), 40)
            let recents = model.recents.prefix(limit)
            guard !recents.isEmpty else { return "Nothing recent." }
            return remember(recents.map {
                SearchHit(
                    url: $0.node.url,
                    name: $0.node.displayName,
                    snippet: $0.modified.formatted(date: .abbreviated, time: .shortened)
                )
            })

        case "list_folder", "list_folders", "list_notebooks":
            let folder = Self.string(arguments["folder_url"]) ?? Self.string(arguments["url"])
            let nodes = folder.flatMap { model.node(for: $0)?.children } ?? (folder == nil ? model.folderTree : [])
            guard !nodes.isEmpty else { return folder == nil ? "No notebooks." : "Empty, or there is nothing at that url." }
            let listed = Array(nodes.prefix(60))
            // a title can be enough to settle it, so a note named here has to be
            // one the answer can name — and one the person can then open
            _ = remember(listed.filter { $0.kind != "folder" }.map {
                SearchHit(url: $0.url, name: $0.displayName, snippet: "")
            })
            return listed.map { "\($0.kind): \($0.displayName) — \($0.url)" }.joined(separator: "\n")

        case "read_note", "read", "open_note":
            guard let url = Self.string(arguments["url"]) else { return "read_note needs a url." }
            let json = await model.spansJSON(for: url)
            let spans = await Task.detached { SpanNode.decodeList(json) }.value
            guard !spans.isEmpty else { return "That note is empty or could not be read." }
            let name = model.node(for: url)?.displayName ?? "Untitled"
            _ = remember([SearchHit(url: url, name: name, snippet: "")])
            return "\(name) — \(url)\n\(NoteChatEdits.outlineText(spans))"

        default:
            return "There is no tool called \(name)."
        }
    }

    /// Keeps what the tools turned up, in the order they turned it up, and
    /// renders the same lines the model reads.
    private func remember(_ hits: [SearchHit]) -> String {
        for hit in hits where !found.contains(where: { $0.url == hit.url }) {
            found.append(hit)
        }
        return hits.map { hit in
            let name = hit.name.isEmpty ? "Untitled" : hit.name
            let snippet = NoteChatEdits.short(hit.snippet, limit: 160)
            return snippet.isEmpty ? "\(name) — \(hit.url)" : "\(name) — \(hit.url)\n  \(snippet)"
        }.joined(separator: "\n")
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func count(_ value: Any?) -> Int? {
        (value as? Int) ?? (value as? NSNumber)?.intValue
    }
}

/// A natural-language question answered out of the search index: the model gets
/// the index as tools and nothing else, and what comes back is a sentence and
/// the notes it is about.
enum NoteFinder {
    struct Answer {
        /// The model's sentence, with the urls it cited written as note names.
        let text: String
        /// What to show underneath it: the notes it named, or — when it named
        /// none — everything its searches turned up.
        let hits: [SearchHit]
    }

    /// The finder always needs its tools, so it does not take a chat profile:
    /// the settings that are the person's to set are the ones the settings
    /// screen already offers for this task.
    private static func finderProfile() -> ChatProfile {
        let settings = LocalModelSettings.generationSettings(for: .findNotes)
        return ChatProfile(
            id: "finder",
            name: "Find",
            summary: "",
            instruction: "",
            tools: .full,
            rounds: 6,
            temperature: settings.temperature,
            maximumResponseTokens: settings.maximumResponseTokens,
            promptLimit: nil
        )
    }

    static func find(
        _ question: String,
        session: NoteFinderSession,
        choice: ModelChoice? = nil
    ) async throws -> Answer {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw NoteChatAssistant.ChatError.emptyQuestion }
        let choice = choice ?? LocalModelSettings.choice(for: .findNotes)
        let profile = finderProfile()
        var budget = await ModelContextWindow.promptCharacters(
            for: choice, response: profile.maximumResponseTokens
        )

        // The question itself is the obvious first query, and running it before
        // the model has said anything means its first round is spent judging
        // hits rather than guessing a query — and that a model too small to use
        // a tool at all still lands on what plain search would have found.
        let seed = "search_notes \(NoteChatAssistant.json(["query": question]))"
        var transcript = [
            "\(seed)\n→ " + NoteChatAssistant.limited(
                await session.run("search_notes", arguments: ["query": question]), to: 4_000
            ),
        ]
        var called: Set<String> = [seed]

        func think(tools: Bool, last: Bool) async throws -> NoteChatAssistant.GeneratedReply {
            // Apple Intelligence writes a schema far better than it writes JSON
            // by hand, so the pass that only wants a sentence asks it for a
            // value; the tool passes go through the text protocol every other
            // backend shares.
            let guided = choice.backend == .appleIntelligence && !tools
            while true {
                let body = await prompt(
                    question: question,
                    session: session,
                    transcript: transcript,
                    tools: tools,
                    last: last,
                    guided: guided,
                    budget: budget
                )
                do {
                    return try await NoteChatAssistant.generate(
                        body, choice: choice, guided: guided, profile: profile, operation: .findNotes
                    )
                } catch NoteChatAssistant.ChatError.promptTooLong {
                    ModelContextWindow.remember(overflowAt: budget, for: choice)
                    guard budget > 2_500 else { throw NoteChatAssistant.ChatError.promptTooLong }
                    budget = budget * 2 / 3
                }
            }
        }

        let rounds = max(2, min(profile.rounds, await NoteChatAssistant.maximumRounds(for: choice)))
        for round in 0..<rounds {
            let generated = try await think(tools: true, last: round == rounds - 1)
            guard let tool = generated.tool, !tool.isEmpty else {
                if let answer = await finish(generated, session: session) { return answer }
                break
            }
            let call = "\(tool) \(NoteChatAssistant.json(generated.arguments))"
            // a model that asks the same thing twice is stuck, not thorough
            guard called.insert(call).inserted else {
                transcript.append("\(call)\n→ already called; the result is above")
                break
            }
            let result = await session.run(tool, arguments: generated.arguments)
            transcript.append("\(call)\n→ \(NoteChatAssistant.limited(result, to: 4_000))")
        }

        // out of rounds, or going in circles: make it answer with what it has
        let closing = try await think(tools: false, last: true)
        if let answer = await finish(closing, session: session) {
            return answer
        }
        // it never said anything usable — what its searches turned up is still
        // a better answer than an error
        let found = await MainActor.run { session.found }
        guard !found.isEmpty else { throw NoteChatAssistant.ChatError.generationFailed }
        return Answer(text: "", hits: Array(found.prefix(12)))
    }

    private static func finish(
        _ generated: NoteChatAssistant.GeneratedReply,
        session: NoteFinderSession
    ) async -> Answer? {
        let text = generated.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !NoteChatAssistant.isPlaceholder(text) else { return nil }
        let found = await MainActor.run { session.found }
        return Answer(text: naming(text, from: found), hits: hits(citedIn: text, from: found))
    }

    /// The notes the answer named, in the order the searches found them —
    /// falling back to all of them, because an answer with nothing under it is
    /// no use to someone looking for a note.
    static func hits(citedIn text: String, from found: [SearchHit]) -> [SearchHit] {
        // longest first, striking each one out as it is found: otherwise a url
        // that is the start of the one actually cited looks cited too
        var rest = text
        var cited: Set<String> = []
        for hit in found.sorted(by: { $0.url.count > $1.url.count }) where rest.contains(hit.url) {
            rest = rest.replacingOccurrences(of: hit.url, with: " ")
            cited.insert(hit.url)
        }
        let named = found.filter { cited.contains($0.url) }
        return Array((named.isEmpty ? found : named).prefix(12))
    }

    /// A url is how the model addresses a note and not how a person reads one.
    static func naming(_ text: String, from hits: [SearchHit]) -> String {
        var text = text
        for hit in hits.sorted(by: { $0.url.count > $1.url.count }) {
            let name = hit.name.isEmpty ? "Untitled" : hit.name
            text = text.replacingOccurrences(of: hit.url, with: "\u{201C}\(name)\u{201D}")
        }
        return text
    }

    private static func prompt(
        question: String,
        session: NoteFinderSession,
        transcript: [String],
        tools: Bool,
        last: Bool,
        guided: Bool,
        budget: Int
    ) async -> String {
        let scope = await MainActor.run { session.scope.flatMap { session.model.node(for: $0)?.displayName } }
        let catalog = tools
            ? await MainActor.run { NoteFinderSession.catalog(brief: budget < 14_000) }
            : ""
        let question = NoteChatAssistant.limited(question, to: 2_000)
        // scaffolding: the date line, the scope line and the closing
        let spare = max(1_000, budget - catalog.count - question.count - 700)
        let found = NoteChatAssistant.fittedTranscript(transcript, to: spare)

        let sections: [String?] = [
            "Today is \(Date.now.formatted(date: .abbreviated, time: .omitted)).",
            scope.map { "The person is looking inside the notebook \u{201C}\($0)\u{201D}." },
            "What the index has given you so far:\n\(found)",
            catalog.isEmpty ? nil : "Tools:\n\(catalog)",
            "The person is looking for:\n\(question)",
            closing(tools: tools, last: last, guided: guided),
        ]
        return sections.compactMap { $0 }.joined(separator: "\n\n")
    }

    private static func closing(tools: Bool, last: Bool, guided: Bool) -> String {
        let naming = """
        Name every note you mean by the automerge: url the tool gave you, copied \
        exactly, and name only notes a tool actually returned. If none of them is \
        what the person wants, say so plainly rather than picking the closest one.
        """
        if guided {
            return "Say which of the notes above is the one the person is looking for, and why. \(naming)"
        }
        guard tools else {
            return """
            Answer from what the index has given you. \(naming)
            Return one JSON object and no other text — the key "answer", with the \
            reply itself as its value: {"answer": …}
            """
        }
        return """
        Return one JSON object and no other text. To search again — a different \
        wording, a narrower query, a note read in full — use the key "tool" for its \
        name and "arguments" for a JSON object of its arguments. When you can say \
        which note the person wants, use the single key "answer", whose value is a \
        sentence or two saying which it is and why. \(naming)\
        \(last ? "\nThis is the last round: answer now, do not call another tool." : "")
        """
    }
}

struct NoteFinderRequest: Identifiable {
    let question: String
    /// The notebook the search was narrowed to, if it was.
    let scope: String?

    var id: String { "\(scope ?? "")\n\(question)" }
}

/// The search field's words handed to the model instead of to the index: it
/// searches, reads what looks promising, and comes back with the notes it
/// thinks were meant. Picking one opens it.
struct NoteFinderView: View {
    let request: NoteFinderRequest
    let open: (String) -> Void

    @Environment(NotesModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var session: NoteFinderSession?
    @State private var answer: NoteFinder.Answer?
    @State private var errorMessage: String?
    @State private var isFinding = false
    @State private var findTask: Task<Void, Never>?
    @State private var modelChoice: ModelChoice?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label("Ask Your Notes", systemImage: "sparkle.magnifyingglass")
                    .uiFont(.headline)
                Spacer()
                ModelChoiceMenu(operation: .findNotes, selection: $modelChoice)
                    .uiFont(.caption)
                    .disabled(isFinding)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            HStack(alignment: .bottom, spacing: 8) {
                TextField("What are you looking for?", text: $question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .uiFont(.body)
                    .lineLimit(1...4)
                    .onSubmit(find)
                Button(action: find) {
                    Label("Ask", systemImage: "arrow.up.circle.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isFinding || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Ask")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(session?.calls ?? []) { call in
                        HStack(spacing: 5) {
                            Image(systemName: "magnifyingglass")
                            Text(call.name).monospaced()
                            Text(call.detail)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if isFinding {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Looking through your notes")
                                .uiFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .uiFont(.callout)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let answer {
                        if !answer.text.isEmpty {
                            Text(answer.text)
                                .uiFont(.callout)
                                .textSelection(.enabled)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                        }
                        if answer.hits.isEmpty {
                            Text("Nothing to open — it found no notes.")
                                .uiFont(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(answer.hits, id: \.url) { hit in
                                Button {
                                    open(hit.url)
                                    dismiss()
                                } label: {
                                    row(hit)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 480, minHeight: 320, idealHeight: 460)
        #endif
        .onAppear {
            guard session == nil else { return }
            question = request.question
            ask(request.question)
        }
        .onDisappear {
            findTask?.cancel()
        }
    }

    @ViewBuilder
    private func row(_ hit: SearchHit) -> some View {
        if let node = model.node(for: hit.url) {
            NoteRowView(node: node, showFolder: true)
                .contentShape(Rectangle())
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.name.isEmpty ? "Untitled" : hit.name)
                    .uiFont(.body)
                    .lineLimit(1)
                if !hit.snippet.isEmpty {
                    Text(hit.snippet)
                        .uiFont(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
    }

    private func find() {
        ask(question)
    }

    private func ask(_ text: String) {
        let asked = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty, !isFinding else { return }
        errorMessage = nil
        answer = nil
        isFinding = true
        let session = NoteFinderSession(model: model, scope: request.scope)
        self.session = session
        findTask?.cancel()
        findTask = Task {
            do {
                let found = try await NoteFinder.find(asked, session: session, choice: modelChoice)
                guard !Task.isCancelled else { return }
                answer = found
            } catch {
                guard !Task.isCancelled else { return }
                // whatever its searches turned up is still worth showing
                if !session.found.isEmpty {
                    answer = NoteFinder.Answer(text: "", hits: Array(session.found.prefix(12)))
                }
                errorMessage = error.localizedDescription
            }
            isFinding = false
        }
    }
}
