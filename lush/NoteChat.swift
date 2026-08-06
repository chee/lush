import Foundation
import FoundationModels
import SwiftUI

struct NoteChatTurn: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    let text: String
    let proposedMarkdown: String?
}

enum NoteChatAssistant {
    enum ChatError: LocalizedError {
        case emptyQuestion
        case appleIntelligenceUnavailable
        case generationFailed

        var errorDescription: String? {
            switch self {
            case .emptyQuestion:
                "Ask a question or describe the change you want."
            case .appleIntelligenceUnavailable:
                "Apple Intelligence is not available on this device."
            case .generationFailed:
                "The local model could not answer about this note."
            }
        }
    }

    private struct GeneratedReply: Decodable {
        let answer: String
        let editedMarkdown: String?
    }

    static func respond(
        to question: String,
        noteTitle: String,
        noteMarkdown: String,
        previousTurns: [NoteChatTurn]
    ) async throws -> (answer: String, proposedMarkdown: String?) {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else { throw ChatError.emptyQuestion }

        let model = SystemLanguageModel.default
        guard model.isAvailable else { throw ChatError.appleIntelligenceUnavailable }

        let instructions = """
        You help someone understand and edit one note in Lush. Use only the supplied note and chat history. If the person asks a question, answer it directly. If the person asks you to change, rewrite, reorganize, summarize, expand, or otherwise edit the note, include the full revised note as editedMarkdown. Preserve the note's facts, voice, and formatting unless the person asks for a change. Return strict JSON with keys answer and editedMarkdown. editedMarkdown must be null when no note change is being proposed.
        """
        let prompt = """
        Note title: \(limited(noteTitle, to: 300))

        Current note in Markdown:
        \(limited(noteMarkdown, to: 12_000))

        Recent chat:
        \(historySummary(from: previousTurns))

        Person request:
        \(trimmedQuestion)

        JSON shape:
        {"answer":"short helpful response","editedMarkdown":null}
        or
        {"answer":"what changed and why","editedMarkdown":"full revised note in Markdown"}
        """

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt)
        guard let generated = parse(response.content) else { throw ChatError.generationFailed }

        let answer = generated.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let proposedMarkdown = generated.editedMarkdown?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
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
}

#if os(macOS)
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

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
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
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: turns.count) {
                    if let last = turns.last?.id {
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }

            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: $draft)
                    .font(.body)
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
                .buttonStyle(.borderedProminent)
                .disabled(isGenerating || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send")
            }
            .padding(10)
        }
        .task(id: url) {
            turns = []
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
        turns.append(NoteChatTurn(role: .user, text: question, proposedMarkdown: nil))
        let previousTurns = turns
        let noteName = node?.displayName ?? "Untitled"
        let currentUrl = url

        chatTask?.cancel()
        chatTask = Task {
            do {
                let json = await model.spansJSON(for: currentUrl)
                let spans = SpanNode.decodeList(json)
                let markdown = await MainActor.run {
                    RichTextClipboard.markdown(from: spans)
                }
                let reply = try await NoteChatAssistant.respond(
                    to: question,
                    noteTitle: noteName,
                    noteMarkdown: markdown,
                    previousTurns: previousTurns
                )
                guard !Task.isCancelled else { return }
                turns.append(NoteChatTurn(role: .assistant, text: reply.answer, proposedMarkdown: reply.proposedMarkdown))
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            isGenerating = false
        }
    }

    private func apply(_ markdown: String, from turnId: UUID) {
        guard applyingTurnId == nil else { return }
        applyingTurnId = turnId
        errorMessage = nil
        Task {
            let spans = await MainActor.run {
                RichTextClipboard.spans(fromMarkdown: markdown)
            }
            guard !spans.isEmpty else {
                errorMessage = "The draft did not contain note content to apply."
                applyingTurnId = nil
                return
            }
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
                .font(.callout)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 8))
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
                    .font(.caption)
                }
                .padding(8)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, alignment: turn.role == .user ? .trailing : .leading)
    }

    private var backgroundStyle: some ShapeStyle {
        turn.role == .user ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.7))
    }
}
#endif

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
