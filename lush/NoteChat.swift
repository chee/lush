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
    let proposedMarkdown: String?

    init(id: UUID = UUID(), role: Role, text: String, proposedMarkdown: String?) {
        self.id = id
        self.role = role
        self.text = text
        self.proposedMarkdown = proposedMarkdown
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
            }
        }
    }

    private struct GeneratedReply: Decodable {
        let answer: String
        let editedMarkdown: String?
        let readAttachments: [Int]?
    }

    /// One round of generation, then — if the model asked to see inside a
    /// patchwork embed — a second round with those documents in the prompt.
    static func respond(
        to question: String,
        noteTitle: String,
        noteMarkdown: String,
        attachments: [NoteAttachment],
        previousTurns: [NoteChatTurn],
        choice: ModelChoice? = nil
    ) async throws -> (answer: String, proposedMarkdown: String?) {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else { throw ChatError.emptyQuestion }
        let choice = choice ?? LocalModelSettings.choice(for: .noteChat)

        var documents = ""
        for _ in 0...1 {
            let body = prompt(
                question: trimmedQuestion,
                noteTitle: noteTitle,
                noteMarkdown: noteMarkdown,
                attachments: attachments,
                documents: documents,
                previousTurns: previousTurns
            )
            let generated = try await generate(body, choice: choice)
            if documents.isEmpty, let wanted = generated.readAttachments, !wanted.isEmpty {
                documents = await documentsSection(attachments, numbers: wanted)
                if !documents.isEmpty { continue }
            }
            return try reply(from: generated)
        }
        throw ChatError.generationFailed
    }

    private static func prompt(
        question: String,
        noteTitle: String,
        noteMarkdown: String,
        attachments: [NoteAttachment],
        documents: String,
        previousTurns: [NoteChatTurn]
    ) -> String {
        """
        Note title: \(limited(noteTitle, to: 300))

        Current note in Markdown:
        \(limited(noteMarkdown, to: 12_000))

        Attachments:
        \(attachmentsSection(attachments))
        \(documents.isEmpty ? "" : "\nAttachment document contents:\n\(documents)\n")
        Recent chat:
        \(historySummary(from: previousTurns))

        Person request:
        \(question)

        Return one JSON object and no other text.
        Requirements for the JSON fields:
        - answer: your actual response to the person's request
        - editedMarkdown: null unless you are proposing a note change; otherwise \
        the complete revised note in Markdown, keeping every [attachment n] line where it is
        - readAttachments: an empty list, unless you need to read inside a patchwork \
        document attachment before you can answer; then list its numbers, leave answer empty, \
        and you will be asked again with those documents included
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
                lines.append("  contents readable — put \(attachment.number) in readAttachments to see them")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    private static func documentsSection(_ attachments: [NoteAttachment], numbers: [Int]) async -> String {
        var sections: [String] = []
        for number in numbers.prefix(4) {
            guard let attachment = attachments.first(where: { $0.number == number }),
                  attachment.isPatchworkDoc,
                  let url = attachment.url,
                  let json = try? await PatchworkScripting.shared.documentJSON(url)
            else { continue }
            sections.append("[attachment \(number)] as JSON:\n\(limited(json, to: 8_000))")
        }
        return sections.joined(separator: "\n\n")
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
            raw = try await session.respond(to: body, options: options).content
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

    private static func reply(from generated: GeneratedReply) throws -> (answer: String, proposedMarkdown: String?) {
        let answer = generated.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let proposedMarkdown = generated.editedMarkdown?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        guard !isPlaceholder(answer), !isPlaceholder(proposedMarkdown) else { throw ChatError.generationFailed }
        guard !answer.isEmpty || proposedMarkdown != nil else { throw ChatError.generationFailed }
        return (answer.isEmpty ? "I drafted a change for this note." : answer, proposedMarkdown)
    }

    private static func historySummary(from turns: [NoteChatTurn]) -> String {
        let lines = turns.suffix(8).map { turn in
            let role = turn.role == .user ? "Person" : "Assistant"
            return "\(role): \(limited(turn.text, to: 1_000))"
        }
        return lines.isEmpty ? "No previous chat." : lines.joined(separator: "\n")
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
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end
        else { return nil }
        return decode(String(trimmed[start...end]))
    }

    private static func decode(_ json: String) -> GeneratedReply? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GeneratedReply.self, from: data)
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
            b.isAtomic || b.type == "context"
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
                Label("Chat", systemImage: "bubble.left.and.text.bubble.right")
                    .uiFont(.headline)
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
                                Text("Questions stay grounded in the current note. Requested edits appear as drafts you can apply.")
                            }
                            .padding(.top, 28)
                        } else {
                            ForEach(turns) { turn in
                                NoteChatBubble(
                                    turn: turn,
                                    isApplying: applyingTurnId == turn.id,
                                    applyDraft: { markdown in
                                        apply(markdown, from: turn.id)
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
            do {
                let json = await model.spansJSON(for: currentUrl)
                let spans = SpanNode.decodeList(json)
                let markdown = await MainActor.run {
                    RichTextClipboard.markdown(from: spans) { "[attachment \($0 + 1)]" }
                }
                let attachments = await NoteAttachment.all(in: spans, model: model)
                let reply = try await NoteChatAssistant.respond(
                    to: question,
                    noteTitle: noteName,
                    noteMarkdown: markdown,
                    attachments: attachments,
                    previousTurns: previousTurns,
                    choice: modelChoice
                )
                guard !Task.isCancelled else { return }
                turns.append(NoteChatTurn(role: .assistant, text: reply.answer, proposedMarkdown: reply.proposedMarkdown))
                NoteChatStore.save(turns, for: currentUrl)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            isGenerating = false
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
            let current = SpanNode.decodeList(await model.spansJSON(for: url))
            let spans = NoteChatAssistant.mergingAtomicBlocks(from: current, into: drafted)
            let title = RichText.title(from: spans)
            await model.updateDocument(url, json: SpanNode.encodeList(spans), title: title)
            applyingTurnId = nil
        }
    }
}

private struct NoteChatBubble: View {
    let turn: NoteChatTurn
    let isApplying: Bool
    let applyDraft: (String) -> Void

    var body: some View {
        VStack(alignment: turn.role == .user ? .trailing : .leading, spacing: 6) {
            Text(turn.text)
                .uiFont(.callout)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity, alignment: turn.role == .user ? .trailing : .leading)

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
