import SwiftUI

/// Counts the inspector shows for a note: everything derivable from its spans.
struct NoteStats: Equatable {
    var words = 0
    var characters = 0
    var paragraphs = 0
    var headings = 0
    var listItems = 0
    var todos: [TodoState: Int] = [:]
    var codeBlocks = 0
    var tables = 0
    var columns = 0
    var links = 0
    var attachments: [String: Int] = [:]

    var attachmentCount: Int { attachments.values.reduce(0, +) }
    var todoCount: Int { todos.values.reduce(0, +) }

    static func of(_ spans: [SpanNode], kinds: [String: String]) -> NoteStats {
        var stats = NoteStats()
        var text = ""
        for span in spans {
            switch span {
            case .block(let block):
                switch block.type {
                case "heading": stats.headings += 1
                case "unordered-list-item", "ordered-list-item": stats.listItems += 1
                case "todo-list-item":
                    stats.todos[block.todoState, default: 0] += 1
                case "code-block": stats.codeBlocks += 1
                case "table": stats.tables += 1
                case "columns": stats.columns += 1
                case "context": break
                default:
                    if block.isEmbedBlock {
                        let kind = block.type == "html"
                            ? "html"
                            : block.embedUrl.flatMap { kinds[$0] } ?? "document"
                        stats.attachments[kind, default: 0] += 1
                    } else {
                        stats.paragraphs += 1
                    }
                }
            case .text(let value, let marks):
                text += value
                if marks["link"]?.stringValue != nil { stats.links += 1 }
            }
        }
        stats.characters = text.count
        stats.words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        return stats
    }
}

struct DocumentInfoView: View {
    let url: String
    let node: FolderNode?
    let history: DocumentHistorySummary

    @Environment(NotesModel.self) private var model
    @State private var stats = NoteStats()
    @State private var attachments: [NoteAttachment] = []

    private var created: Date? {
        guard let time = history.entries.last?.time, time > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time))
    }

    private var contributors: Int {
        Set(history.entries.map(\.actor)).count
    }

    private var edits: (added: UInt64, removed: UInt64) {
        history.entries.reduce(into: (UInt64(0), UInt64(0))) { totals, entry in
            totals.0 += entry.additions
            totals.1 += entry.deletions
        }
    }

    var body: some View {
        Form {
            Section("Document") {
                LabeledContent("Name", value: node?.displayName.nonEmpty ?? "Untitled")
                LabeledContent("Kind", value: node?.kind.nonEmpty ?? "Document")
                if let created {
                    LabeledContent("Created", value: created.formatted(date: .abbreviated, time: .shortened))
                }
                if let modified = history.modified {
                    LabeledContent("Modified", value: modified.formatted(date: .abbreviated, time: .shortened))
                }
            }

            Section("Content") {
                LabeledContent("Words", value: stats.words.formatted())
                LabeledContent("Characters", value: stats.characters.formatted())
                LabeledContent("Paragraphs", value: stats.paragraphs.formatted())
                if stats.headings > 0 {
                    LabeledContent("Headings", value: stats.headings.formatted())
                }
                if stats.listItems > 0 {
                    LabeledContent("List items", value: stats.listItems.formatted())
                }
                if stats.todoCount > 0 {
                    LabeledContent(
                        "To-dos",
                        value: "\(stats.todos[.checked] ?? 0) of \(stats.todoCount) done"
                    )
                    ForEach(TodoState.allCases.filter { $0 != .checked }, id: \.self) { state in
                        if let count = stats.todos[state], count > 0 {
                            LabeledContent(state.label, value: count.formatted())
                        }
                    }
                }
                if stats.codeBlocks > 0 {
                    LabeledContent("Code blocks", value: stats.codeBlocks.formatted())
                }
                if stats.tables > 0 {
                    LabeledContent("Tables", value: stats.tables.formatted())
                }
                if stats.columns > 0 {
                    LabeledContent("Column layouts", value: stats.columns.formatted())
                }
                if stats.links > 0 {
                    LabeledContent("Links", value: stats.links.formatted())
                }
                if stats.attachmentCount > 0 {
                    LabeledContent("Attachments", value: stats.attachments
                        .sorted { $0.key < $1.key }
                        .map { "\($0.value) \($0.key)" }
                        .joined(separator: ", "))
                }
            }

            if !attachments.isEmpty {
                Section("Attachments") {
                    ForEach(attachments, id: \.number) { attachment in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(attachment.name.nonEmpty ?? attachment.kind)
                                .uiFont(.callout)
                            Text(attachmentDetail(attachment))
                                .uiFont(.caption)
                                .foregroundStyle(.secondary)
                            if let url = attachment.url {
                                Text(url)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Section("Automerge") {
                LabeledContent("Changes", value: history.changeCount.formatted())
                if history.pendingChangeCount > 0 {
                    LabeledContent("Unapplied", value: history.pendingChangeCount.formatted())
                }
                LabeledContent("Contributors", value: contributors.formatted())
                LabeledContent("Text added", value: edits.added.formatted())
                LabeledContent("Text removed", value: edits.removed.formatted())
                LabeledContent("Drafts", value: (model.draftLists[url]?.drafts.count ?? 0).formatted())
                InfoField("URL", value: url)
                if !history.heads.isEmpty {
                    InfoField("Heads", value: history.heads.joined(separator: "\n"))
                }
                Button("Copy URL") {
                    Clipboard.copy(url)
                }
                if !history.heads.isEmpty {
                    Button("Copy Heads") {
                        Clipboard.copy(history.heads.joined(separator: "\n"))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: url) {
            await refresh()
        }
        .onChange(of: model.docVersions[url]) {
            Task { await refresh() }
        }
    }

    private func attachmentDetail(_ attachment: NoteAttachment) -> String {
        var parts = [attachment.kind]
        if let tool = attachment.tool?.nonEmpty { parts.append(tool) }
        if !attachment.description.isEmpty { parts.append(attachment.description) }
        else if !attachment.summary.isEmpty { parts.append(attachment.summary) }
        else if !attachment.text.isEmpty { parts.append(attachment.text) }
        return parts.joined(separator: " · ").replacingOccurrences(of: "\n", with: " ")
    }

    private func refresh() async {
        let spans = SpanNode.decodeList(await model.spansJSON(for: url))
        let found = await NoteAttachment.all(in: spans, model: model)
        guard !Task.isCancelled else { return }
        attachments = found
        stats = NoteStats.of(spans, kinds: Dictionary(
            found.compactMap { attachment in
                attachment.url.map { ($0, attachment.kind) }
            },
            uniquingKeysWith: { first, _ in first }
        ))
    }
}

/// A full identifier — a url, a list of heads — on its own line under its
/// label, wrapped rather than truncated and selectable.
private struct InfoField: View {
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .uiFont(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
@Observable
final class ContextToolsState {
    var tools: [ToolChoice] = []
    var selected: String?

    func offer(_ tools: [ToolChoice]) {
        self.tools = tools
        if let selected, tools.contains(where: { $0.id == selected }) { return }
        selected = PatchworkWeb.lastContextTool.flatMap { last in
            tools.first { $0.id == last }?.id
        } ?? tools.first?.id
    }

    func select(_ id: String) {
        selected = id
        PatchworkWeb.lastContextTool = id
    }
}

/// Patchwork's context tools — every component tagged `context-tool` — with a
/// tab bar over them, pointed at the document the inspector is open on.
struct ContextToolsView: View {
    let url: String

    @Environment(NotesModel.self) private var model
    @State private var state = ContextToolsState()

    var body: some View {
        VStack(spacing: 0) {
            if state.tools.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(state.tools) { tool in
                            let isActive = state.selected == tool.id
                            Button(tool.name) {
                                state.select(tool.id)
                            }
                            .buttonStyle(.plain)
                            .uiFont(.caption)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                isActive ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear),
                                in: Capsule()
                            )
                            .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.hidden)

                Divider()
            }

            if state.tools.isEmpty {
                ContentUnavailableView {
                    Label("No Context Tools", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("Patchwork modules that register a context tool appear here.")
                }
            }

            PatchworkContextToolsView(
                docUrl: url,
                accountUrl: model.accountUrl,
                toolId: state.selected,
                onTools: { [state] tools in state.offer(tools) }
            )
            .frame(maxWidth: .infinity, maxHeight: state.tools.isEmpty ? 0 : .infinity)
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
