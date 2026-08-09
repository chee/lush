import Foundation
import FoundationModels
import SwiftUI

struct NoteChatTurn: Identifiable, Codable, Equatable {
    enum Role: String, Codable, Equatable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let text: String
    /// Chats saved before the chat could edit spans directly still hold a
    /// whole-note markdown draft.
    let proposedMarkdown: String?
    var calls: [NoteChatToolCall]
    var proposals: [NoteChatProposal]
    var applied: Set<UUID>

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        proposedMarkdown: String? = nil,
        calls: [NoteChatToolCall] = [],
        proposals: [NoteChatProposal] = [],
        applied: Set<UUID> = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.proposedMarkdown = proposedMarkdown
        self.calls = calls
        self.proposals = proposals
        self.applied = applied
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(Role.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        proposedMarkdown = try c.decodeIfPresent(String.self, forKey: .proposedMarkdown)
        calls = try c.decodeIfPresent([NoteChatToolCall].self, forKey: .calls) ?? []
        proposals = try c.decodeIfPresent([NoteChatProposal].self, forKey: .proposals) ?? []
        applied = try c.decodeIfPresent(Set<UUID>.self, forKey: .applied) ?? []
    }
}

enum NoteChatStore {
    static func turns(for url: String) -> [NoteChatTurn] {
        guard let data = UserDefaults.standard.data(forKey: key(for: url)),
              let turns = try? JSONDecoder().decode([NoteChatTurn].self, from: data)
        else { return [] }
        return turns
    }

    static func save(_ turns: [NoteChatTurn], for url: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(turns), forKey: key(for: url))
    }

    static func clear(for url: String) {
        UserDefaults.standard.removeObject(forKey: key(for: url))
    }

    private static func key(for url: String) -> String {
        let safeURL = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url
        return "noteChat.turns.\(safeURL)"
    }
}

/// What the chat knows about one embed in the note: the asset's name and kind,
/// whatever Vision and the summarizer wrote about it (OCR for images, the
/// transcript for audio), or — for a patchwork embed — the document it points
/// at, which the model can ask to read.
struct NoteAttachment: Equatable {
    let number: Int
    let url: String?
    let kind: String
    let name: String
    let tool: String?
    let description: String
    let text: String
    let summary: String
    let isPatchworkDoc: Bool

    var label: String {
        let title = name.isEmpty ? kind : name
        return "[attachment \(number)] \(title) — \(kind)"
    }

    @MainActor
    static func all(in spans: [SpanNode], model: NotesModel) async -> [NoteAttachment] {
        // html blocks carry their source into the markdown, so they take no
        // attachment number — the numbering must match RichTextClipboard
        let blocks = spans.compactMap { span -> BlockValue? in
            guard case .block(let block) = span, block.isEmbedBlock, block.type != "html" else { return nil }
            return block
        }
        var out: [NoteAttachment] = []
        for (index, block) in blocks.enumerated() {
            let tool = block.attrs["tool"]?.stringValue
            guard let url = block.embedUrl else {
                out.append(NoteAttachment(
                    number: index + 1, url: nil, kind: block.type, name: "", tool: tool,
                    description: "", text: "", summary: "", isPatchworkDoc: false
                ))
                continue
            }
            let info = await model.assetInfo(url)
            guard let info, !info.mimeType.isEmpty else {
                out.append(NoteAttachment(
                    number: index + 1, url: url, kind: "patchwork document",
                    name: model.node(for: url)?.displayName ?? "", tool: tool,
                    description: "", text: "", summary: "", isPatchworkDoc: true
                ))
                continue
            }
            let vision = await model.assetVision(url)
            let ml = await model.assetML(url)
            out.append(NoteAttachment(
                number: index + 1,
                url: url,
                kind: AssetCache.kind(forName: info.name),
                name: info.name,
                tool: tool,
                description: vision?.description ?? "",
                text: vision?.ocr ?? "",
                summary: ml?.summary ?? "",
                isPatchworkDoc: false
            ))
        }
        return out
    }
}

enum NoteChatAssistant {
    enum ChatError: LocalizedError {
        case emptyQuestion
        case appleIntelligenceUnavailable
        case customModelNotConfigured
        case customRuntimeUnavailable
        case generationFailed
        case promptTooLong

        var errorDescription: String? {
            switch self {
            case .emptyQuestion:
                "Ask a question or describe the change you want."
            case .appleIntelligenceUnavailable:
                "Apple Intelligence is not available on this device."
            case .customModelNotConfigured:
                "No Core ML model is configured for note chat."
            case .customRuntimeUnavailable:
                "The selected model is downloaded, but Lush does not have a Core ML runtime adapter for this model yet."
            case .generationFailed:
                "The local model could not answer about this note."
            case .promptTooLong:
                "This note is too long for the on-device model. Pick a larger model above."
            }
        }
    }

    private struct GeneratedReply {
        let answer: String
        let tool: String?
        let arguments: [String: Any]
        /// What the model says it is missing, when it was asked without tools.
        let need: String?
        /// Older chats and models that ignore the tools still send a whole
        /// rewritten note.
        let editedMarkdown: String?

        var needsTools: Bool {
            need?.isEmpty == false
        }
    }

    /// A small model gains nothing from a long loop — it repeats itself. Size
    /// is the model's, not the runner's, so this asks the model; anything that
    /// does not say gets the benefit of the doubt.
    static func maximumRounds(for choice: ModelChoice) async -> Int {
        guard let billions = await ModelContextWindow.parameterBillions(for: choice) else { return 8 }
        return billions < 8 ? 3 : 8
    }

    /// Generate, run whatever tool was called, generate again — until the model
    /// answers or the round budget runs out.
    static func respond(
        to question: String,
        session: NoteChatSession,
        previousTurns: [NoteChatTurn],
        choice: ModelChoice? = nil
    ) async throws -> (answer: String, proposedMarkdown: String?) {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else { throw ChatError.emptyQuestion }
        let choice = choice ?? LocalModelSettings.choice(for: .noteChat)

        var transcript: [String] = []
        var called = Set<String>()
        let settings = LocalModelSettings.generationSettings(for: .noteChat)
        var budget = await ModelContextWindow.promptCharacters(
            for: choice, response: settings.maximumResponseTokens
        )

        func think(tools: Bool, last: Bool) async throws -> GeneratedReply {
            while true {
                let body = await prompt(
                    question: trimmedQuestion,
                    session: session,
                    transcript: transcript,
                    previousTurns: previousTurns,
                    tools: tools,
                    last: last,
                    budget: budget
                )
                do {
                    return try await generate(body, choice: choice)
                } catch ChatError.promptTooLong {
                    // the window was smaller than this model let on; remember
                    // that and try again rather than losing the turn
                    ModelContextWindow.remember(overflowAt: budget, for: choice)
                    guard budget > 2_500 else { throw ChatError.promptTooLong }
                    budget = budget * 2 / 3
                }
            }
        }

        // First, the note and the question alone. Most of what gets asked is
        // answerable from the note that is already in front of it, and a model
        // shown a page of tool syntax will imitate the syntax instead.
        let opening = try await think(tools: false, last: false)
        if opening.tool == nil, !opening.needsTools, !opening.answer.isEmpty {
            return try await reply(from: opening, session: session)
        }
        if let need = opening.need, !need.isEmpty {
            transcript.append("You said you needed: \(limited(need, to: 400))")
        }

        let rounds = await maximumRounds(for: choice)
        for round in 0..<rounds {
            let generated = try await think(tools: true, last: round == rounds - 1)
            guard let tool = generated.tool, !tool.isEmpty else {
                return try await reply(from: generated, session: session)
            }
            let call = "\(tool) \(json(generated.arguments))"
            // a model that asks the same thing twice is stuck, not thorough
            guard called.insert(call).inserted else {
                transcript.append("\(call)\n→ already called; the result is above")
                break
            }
            let result = await session.run(tool, arguments: generated.arguments)
            transcript.append("\(call)\n→ \(limited(result, to: 4_000))")
        }

        // out of rounds, or going in circles: make it answer with what it has
        return try await reply(from: try await think(tools: false, last: true), session: session)
    }

    private static func prompt(
        question: String,
        session: NoteChatSession,
        transcript: [String],
        previousTurns: [NoteChatTurn],
        tools: Bool,
        last: Bool,
        budget: Int
    ) async -> String {
        let outline = await MainActor.run { session.outline }
        let title = await MainActor.run { session.title }
        let attachments = await MainActor.run { session.attachments }

        let catalog = tools ? (budget < 14_000 ? NoteChatSession.briefCatalog : NoteChatSession.catalog) : ""
        let question = limited(question, to: 2_000)
        // scaffolding, the title line and the closing instructions
        let spare = max(1_000, budget - catalog.count - question.count - 700)
        let calls = transcript.isEmpty ? "" : fittedTranscript(transcript, to: spare * 45 / 100)
        let notes = fit(attachmentsSection(attachments), to: min(spare * 15 / 100, 1_500))
        let history = fit(historySummary(from: previousTurns), to: min(spare * 15 / 100, 1_500))
        let blocks = fitOutline(outline, to: spare - calls.count - notes.count - history.count)

        let sections = [
            "Note title: \(limited(title, to: 300))",
            "The note, one line per block, numbered for editing:\n\(blocks)",
            attachments.isEmpty ? nil : "Attachments:\n\(notes)",
            previousTurns.isEmpty ? nil : "Recent chat:\n\(history)",
            calls.isEmpty ? nil : "What you have found so far this turn:\n\(calls)",
            catalog.isEmpty ? nil : "Tools:\n\(catalog)",
            "Person request:\n\(question)",
            closing(tools: tools, last: last),
        ].compactMap { $0 }
        return sections.joined(separator: "\n\n")
    }

    /// Without the tools in front of it, the model is asked for an answer and
    /// nothing else — the one escape hatch is saying what it is missing, which
    /// is what brings the tools out on the next pass.
    private static func closing(tools: Bool, last: Bool) -> String {
        guard tools else {
            return """
            Answer the person, using the note above. Return one JSON object and no other text:
            {"answer": "your reply"}
            If — and only if — answering is impossible without something the note above \
            does not contain, say what you are missing instead:
            {"need": "what you are missing"}
            """
        }
        return """
        Return one JSON object and no other text. Call one tool:
        {"tool": "name", "arguments": {…}}
        or, once you have what you need, answer:
        {"answer": "your reply to the person"}
        \(last ? "\nThis is the last round: answer now, do not call another tool." : "")
        """
    }

    private static func attachmentsSection(_ attachments: [NoteAttachment]) -> String {
        guard !attachments.isEmpty else { return "None." }
        return attachments.map { attachment in
            var lines = [attachment.label]
            if let tool = attachment.tool, !tool.isEmpty {
                lines.append("  tool: \(tool)")
            }
            if !attachment.description.isEmpty {
                lines.append("  description: \(limited(attachment.description, to: 600))")
            }
            if !attachment.text.isEmpty {
                let field = attachment.kind == "audio" ? "transcript" : "text"
                lines.append("  \(field): \(limited(attachment.text, to: 4_000))")
            }
            if !attachment.summary.isEmpty {
                lines.append("  summary: \(limited(attachment.summary, to: 1_000))")
            }
            if attachment.isPatchworkDoc {
                lines.append("  contents readable with read_attachment \(attachment.number)")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    private static func generate(_ body: String, choice: ModelChoice) async throws -> GeneratedReply {
        let settings = LocalModelSettings.generationSettings(for: .noteChat)
        let raw: String
        switch choice.backend {
        case .appleIntelligence:
            guard SystemLanguageModel.default.isAvailable else {
                throw ChatError.appleIntelligenceUnavailable
            }
            let session = LanguageModelSession(
                instructions: LocalModelSettings.systemPrompt(for: .noteChat)
            )
            let options = GenerationOptions(
                temperature: settings.temperature,
                maximumResponseTokens: settings.maximumResponseTokens
            )
            do {
                raw = try await session.respond(to: body, options: options).content
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                throw ChatError.promptTooLong
            }
        case .mlx:
            let config = LocalModelSettings.mlxConfig(for: .noteChat, choice: choice)
            guard !config.repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ChatError.customModelNotConfigured
            }
            raw = try await LocalLLMRuntime.generateText(
                prompt: "\(LocalModelSettings.systemPrompt(for: .noteChat))\n\n\(body)",
                config: config,
                maxTokens: settings.maximumResponseTokens,
                temperature: settings.temperature
            )
        case .openRouter, .openAI, .anthropic, .compatible, .ollama:
            raw = try await CloudLLMRuntime.generateText(
                prompt: "\(LocalModelSettings.systemPrompt(for: .noteChat))\n\n\(body)",
                operation: .noteChat,
                choice: choice
            )
        }
        guard let generated = parse(raw) else { throw ChatError.generationFailed }
        return generated
    }

    /// A small model often stops mid-JSON or answers in plain prose. Whatever
    /// it managed to say is better than an error, so pull the answer out of a
    /// half-written object, or take the text as the answer.
    private static func salvage(_ raw: String) -> GeneratedReply? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let key = trimmed.range(of: "\"answer\"") {
            let rest = trimmed[key.upperBound...].drop { $0 == ":" || $0 == " " || $0 == "\n" }
            if rest.first == "\"" {
                var answer = ""
                var escaped = false
                for character in rest.dropFirst() {
                    if escaped {
                        answer.append(character == "n" ? "\n" : character)
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        break
                    } else {
                        answer.append(character)
                    }
                }
                if !answer.isEmpty {
                    return GeneratedReply(answer: answer, tool: nil, arguments: [:], need: nil, editedMarkdown: nil)
                }
            }
        }
        guard !trimmed.hasPrefix("{"), !trimmed.hasPrefix("[") else { return nil }
        return GeneratedReply(answer: trimmed, tool: nil, arguments: [:], need: nil, editedMarkdown: nil)
    }

    private static func reply(
        from generated: GeneratedReply,
        session: NoteChatSession
    ) async throws -> (answer: String, proposedMarkdown: String?) {
        let answer = generated.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let proposedMarkdown = generated.editedMarkdown?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        guard !isPlaceholder(answer), !isPlaceholder(proposedMarkdown) else { throw ChatError.generationFailed }
        let proposals = await MainActor.run { session.proposals }
        guard !answer.isEmpty || proposedMarkdown != nil || !proposals.isEmpty else {
            throw ChatError.generationFailed
        }
        return (answer.isEmpty ? "I drafted a change for you." : answer, proposedMarkdown)
    }

    private static func json(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func historySummary(from turns: [NoteChatTurn]) -> String {
        let lines = turns.suffix(8).map { turn in
            let role = turn.role == .user ? "Person" : "Assistant"
            return "\(role): \(limited(turn.text, to: 1_000))"
        }
        return lines.isEmpty ? "No previous chat." : lines.joined(separator: "\n")
    }

    private static func fit(_ value: String, to limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(max(limit - 20, 0))) + "\n… (trimmed to fit)"
    }

    /// The outline keeps its first and last blocks when it will not fit whole,
    /// so the model can still see where the note starts and ends — and is told
    /// which numbers it is not being shown, rather than guessing.
    private static func fitOutline(_ outline: String, to limit: Int) -> String {
        guard outline.count > limit, limit > 400 else {
            return outline.count > limit ? fit(outline, to: limit) : outline
        }
        let lines = outline.components(separatedBy: "\n")
        var head: [String] = []
        var tail: [String] = []
        var used = 0
        var start = 0
        var end = lines.count - 1
        while start <= end {
            let line = start <= end && head.count <= tail.count ? lines[start] : lines[end]
            guard used + line.count + 1 <= limit - 60 else { break }
            used += line.count + 1
            if head.count <= tail.count {
                head.append(line)
                start += 1
            } else {
                tail.insert(line, at: 0)
                end -= 1
            }
        }
        let hidden = end - start + 1
        guard hidden > 0 else { return outline }
        return (head + ["… \(hidden) blocks (\(start + 1)–\(end + 1)) not shown …"] + tail)
            .joined(separator: "\n")
    }

    /// Newest tool results matter most: older ones shrink to their first line
    /// before any of them are dropped.
    private static func fittedTranscript(_ transcript: [String], to limit: Int) -> String {
        guard !transcript.isEmpty else { return "None." }
        var kept: [String] = []
        var used = 0
        for (offset, entry) in transcript.enumerated().reversed() {
            let allowance = kept.isEmpty ? limit : max(120, (limit - used) / 2)
            let text = fit(entry, to: allowance)
            guard used + text.count <= limit else {
                kept.insert("… \(offset + 1) earlier tool calls omitted …", at: 0)
                break
            }
            used += text.count
            kept.insert(text, at: 0)
        }
        return kept.joined(separator: "\n\n")
    }

    private static func limited(_ value: String, to maxCharacters: Int) -> String {
        guard value.count > maxCharacters else { return value }
        return String(value.prefix(maxCharacters))
    }

    private static func isPlaceholder(_ value: String?) -> Bool {
        guard let value else { return false }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "short helpful response"
            || normalized == "what changed and why"
            || normalized == "full revised note in markdown"
    }

    private static func parse(_ raw: String) -> GeneratedReply? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = decode(trimmed) {
            return direct
        }
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}"),
           start <= end,
           let embedded = decode(String(trimmed[start...end])) {
            return embedded
        }
        return salvage(trimmed)
    }

    private static func decode(_ json: String) -> GeneratedReply? {
        guard let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // some models nest the call, some spell the fields out flat
        let call = value["tool_call"] as? [String: Any] ?? value
        let tool = (call["tool"] as? String ?? call["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return GeneratedReply(
            answer: value["answer"] as? String ?? value["text"] as? String ?? "",
            tool: tool?.isEmpty == true ? nil : tool,
            arguments: call["arguments"] as? [String: Any] ?? call["parameters"] as? [String: Any] ?? [:],
            need: value["need"] as? String,
            editedMarkdown: value["editedMarkdown"] as? String
        )
    }

    /// The chat pipeline round-trips the note through markdown, which cannot
    /// represent atomic blocks: embeds/images/audio flatten to "[attachment]"
    /// and tables/columns/context blocks to bare lines. Before an applied
    /// draft replaces the document, reinsert every atomic region from the
    /// current spans into the drafted ones.
    ///
    /// Anchoring is a nearest-anchor heuristic: each region remembers how many
    /// plain top-level paragraphs preceded it in the current document and is
    /// reinserted after that many plain paragraphs of the draft (at a
    /// top-level block boundary). Edited drafts shift text around, so a
    /// region can land next to different neighbors — but it always survives.
    static func isAttachmentPlaceholder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("[attachment") && trimmed.hasSuffix("]")
    }

    static func mergingAtomicBlocks(from current: [SpanNode], into drafted: [SpanNode]) -> [SpanNode] {
        struct Region {
            let spans: [SpanNode]
            let anchor: Int
        }

        func topLevelBlock(_ span: SpanNode) -> BlockValue? {
            if case .block(let b) = span, b.parents.isEmpty { return b }
            return nil
        }
        func isAtomicRoot(_ b: BlockValue) -> Bool {
            b.isAtomic || b.type == "context" || b.type == "calendar-event"
        }

        var regions: [Region] = []
        var plainCount = 0
        var i = 0
        while i < current.count {
            guard let block = topLevelBlock(current[i]) else {
                i += 1
                continue
            }
            if isAtomicRoot(block) {
                // tables/columns own every following span until the next
                // top-level block (nested blocks carry parents, cell text
                // follows its cell block); single-attachment blocks own
                // just themselves
                var j = i + 1
                if block.type == "table" || block.type == "columns" {
                    while j < current.count, topLevelBlock(current[j]) == nil { j += 1 }
                }
                regions.append(Region(spans: Array(current[i..<j]), anchor: plainCount))
                i = j
            } else {
                plainCount += 1
                i += 1
            }
        }
        guard !regions.isEmpty else { return drafted }

        // a draft that somehow kept atomic blocks knows better than we do
        let draftHasAtomic = drafted.contains {
            if case .block(let b) = $0 { return isAtomicRoot(b) }
            return false
        }
        guard !draftHasAtomic else { return drafted }

        // drop "[attachment]" placeholder paragraphs the model echoed back;
        // the real embeds are being reinserted
        var cleaned: [SpanNode] = []
        var k = 0
        while k < drafted.count {
            if let block = topLevelBlock(drafted[k]),
               !isAtomicRoot(block),
               k + 1 < drafted.count,
               case .text(let text, _) = drafted[k + 1],
               isAttachmentPlaceholder(text),
               k + 2 >= drafted.count || topLevelBlock(drafted[k + 2]) != nil {
                k += 2
                continue
            }
            cleaned.append(drafted[k])
            k += 1
        }

        var out: [SpanNode] = []
        var pending = regions[...]
        var seenPlain = 0
        for span in cleaned {
            if let block = topLevelBlock(span) {
                while let region = pending.first, region.anchor <= seenPlain {
                    out.append(contentsOf: region.spans)
                    pending.removeFirst()
                }
                if !isAtomicRoot(block) { seenPlain += 1 }
            }
            out.append(span)
        }
        for region in pending {
            out.append(contentsOf: region.spans)
        }
        return out
    }
}

struct NoteChatView: View {
    let url: String
    let node: FolderNode?

    @Environment(NotesModel.self) private var model
    @State private var turns: [NoteChatTurn] = []
    @State private var draft = ""
    @State private var errorMessage: String?
    @State private var isGenerating = false
    @State private var applyingTurnId: UUID?
    @State private var chatTask: Task<Void, Never>?
    @State private var modelChoice: ModelChoice?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                ModelChoiceMenu(operation: .noteChat, selection: $modelChoice)
                    .uiFont(.caption)
                    .disabled(isGenerating)
                Button {
                    clearChat()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(turns.isEmpty || isGenerating)
                .help("Clear Chat")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if turns.isEmpty {
                            ContentUnavailableView {
                                Label("Ask About This Note", systemImage: "sparkles")
                            } description: {
                                Text("It can read your other notes, attachments, and calendar. Anything it wants to change appears here for you to apply.")
                            }
                            .padding(.top, 28)
                        } else {
                            ForEach(turns) { turn in
                                NoteChatBubble(
                                    turn: turn,
                                    isApplying: applyingTurnId == turn.id,
                                    applyDraft: { markdown in
                                        apply(markdown, from: turn.id)
                                    },
                                    applyProposal: { proposal in
                                        apply(proposal, from: turn.id)
                                    }
                                )
                                .id(turn.id)
                            }
                        }

                        if isGenerating {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Thinking")
                                    .uiFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: turns.count) {
                    guard let last = turns.last?.id else { return }
                    Task { @MainActor in
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .uiFont(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }

            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: $draft)
                    .uiFont(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 44, idealHeight: 54, maxHeight: 86)
                    .padding(5)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        if draft.isEmpty {
                            Text("Ask or request an edit")
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 12)
                                .allowsHitTesting(false)
                        }
                    }

                Button(action: submit) {
                    Image(systemName: "paperplane.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(isGenerating || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send")
            }
            .padding(10)
        }
        .task(id: url) {
            chatTask?.cancel()
            chatTask = nil
            isGenerating = false
            turns = NoteChatStore.turns(for: url)
            draft = ""
            errorMessage = nil
        }
        .onDisappear {
            chatTask?.cancel()
        }
    }

    private func submit() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isGenerating else { return }

        errorMessage = nil
        draft = ""
        isGenerating = true
        let previousTurns = turns
        turns.append(NoteChatTurn(role: .user, text: question, proposedMarkdown: nil))
        NoteChatStore.save(turns, for: url)
        let noteName = node?.displayName ?? "Untitled"
        let currentUrl = url

        chatTask?.cancel()
        chatTask = Task {
            let snapshot = await model.spansSnapshot(for: currentUrl)
            let spans = SpanNode.decodeList(snapshot.spansJson)
            let session = NoteChatSession(
                model: model,
                url: currentUrl,
                title: noteName,
                snapshot: snapshot,
                attachments: await NoteAttachment.all(in: spans, model: model)
            )
            do {
                let reply = try await NoteChatAssistant.respond(
                    to: question,
                    session: session,
                    previousTurns: previousTurns,
                    choice: modelChoice
                )
                guard !Task.isCancelled else { return }
                turns.append(NoteChatTurn(
                    role: .assistant,
                    text: reply.answer,
                    proposedMarkdown: reply.proposedMarkdown,
                    calls: session.calls,
                    proposals: session.proposals
                ))
                NoteChatStore.save(turns, for: currentUrl)
            } catch {
                guard !Task.isCancelled else { return }
                // work the model already did is worth keeping on screen
                if !session.calls.isEmpty || !session.proposals.isEmpty {
                    turns.append(NoteChatTurn(
                        role: .assistant,
                        text: error.localizedDescription,
                        calls: session.calls,
                        proposals: session.proposals
                    ))
                    NoteChatStore.save(turns, for: currentUrl)
                } else {
                    errorMessage = error.localizedDescription
                }
            }
            isGenerating = false
        }
    }

    private func apply(_ proposal: NoteChatProposal, from turnId: UUID) {
        guard applyingTurnId == nil else { return }
        applyingTurnId = turnId
        errorMessage = nil
        Task {
            errorMessage = await proposal.action.apply(model: model)
            if errorMessage == nil, let index = turns.firstIndex(where: { $0.id == turnId }) {
                turns[index].applied.insert(proposal.id)
                NoteChatStore.save(turns, for: url)
            }
            applyingTurnId = nil
        }
    }

    private func clearChat() {
        chatTask?.cancel()
        isGenerating = false
        errorMessage = nil
        turns = []
        NoteChatStore.clear(for: url)
    }

    private func apply(_ markdown: String, from turnId: UUID) {
        guard applyingTurnId == nil else { return }
        applyingTurnId = turnId
        errorMessage = nil
        Task {
            let drafted = await MainActor.run {
                RichTextClipboard.spans(fromMarkdown: markdown)
            }
            guard !drafted.isEmpty else {
                errorMessage = "The draft did not contain note content to apply."
                applyingTurnId = nil
                return
            }
            // the markdown round trip loses embeds/tables/columns/context —
            // carry them over from the live document before replacing it
            let snapshot = await model.spansSnapshot(for: url)
            let current = SpanNode.decodeList(snapshot.spansJson)
            let spans = NoteChatAssistant.mergingAtomicBlocks(from: current, into: drafted)
            let title = RichText.title(from: spans)
            await model.updateDocument(
                url,
                json: SpanNode.encodeList(spans),
                title: title,
                heads: snapshot.heads.isEmpty ? nil : snapshot.heads
            )
            applyingTurnId = nil
        }
    }
}

private struct NoteChatBubble: View {
    let turn: NoteChatTurn
    let isApplying: Bool
    let applyDraft: (String) -> Void
    let applyProposal: (NoteChatProposal) -> Void

    var body: some View {
        VStack(alignment: turn.role == .user ? .trailing : .leading, spacing: 6) {
            ForEach(turn.calls) { call in
                HStack(spacing: 5) {
                    Image(systemName: "wrench.and.screwdriver")
                    Text(call.name).monospaced()
                    Text(call.detail)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .uiFont(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(turn.text)
                .uiFont(.callout)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity, alignment: turn.role == .user ? .trailing : .leading)

            ForEach(turn.proposals) { proposal in
                VStack(alignment: .leading, spacing: 6) {
                    Text(proposal.title)
                        .uiFont(.callout, weight: .medium)
                    ForEach(Array(proposal.detail.prefix(8).enumerated()), id: \.offset) { line in
                        Text(line.element)
                            .uiFont(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if turn.applied.contains(proposal.id) {
                        Label("Applied", systemImage: "checkmark.circle.fill")
                            .uiFont(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            applyProposal(proposal)
                        } label: {
                            if isApplying {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Apply", systemImage: "checkmark.circle")
                            }
                        }
                        .uiFont(.caption)
                        .disabled(isApplying)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            }

            if let proposedMarkdown = turn.proposedMarkdown {
                VStack(alignment: .leading, spacing: 8) {
                    Text(proposedMarkdown)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))

                    HStack {
                        Button {
                            applyDraft(proposedMarkdown)
                        } label: {
                            if isApplying {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Apply Draft", systemImage: "checkmark.circle")
                            }
                        }
                        .disabled(isApplying)

                        Button {
                            Clipboard.copy(proposedMarkdown)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                    .uiFont(.caption)
                }
                .padding(8)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, alignment: turn.role == .user ? .trailing : .leading)
    }

    private var bubbleBackground: AnyShapeStyle {
        turn.role == .user ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.7))
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
