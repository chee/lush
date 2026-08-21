import SwiftUI

#if os(macOS)

enum FolderViewMode: String, CaseIterable, Identifiable {
    case notebook
    case sketchpad
    case outline

    var id: String { rawValue }

    var label: String {
        switch self {
        case .notebook: "Notebook"
        case .sketchpad: "Sketchpad"
        case .outline: "Outline"
        }
    }

    var symbol: String {
        switch self {
        case .notebook: "doc.text"
        case .sketchpad: "square.grid.2x2"
        case .outline: "list.bullet.indent"
        }
    }
}

/// How a folder was last read, remembered per folder. Finder keeps a view per
/// directory and this does the same: one global setting fights every folder
/// that wants reading a different way.
@MainActor
enum FolderViewModes {
    private static let key = "folderViewModes"
    private static var stored: [String: String] =
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]

    static func mode(for folderUrl: String) -> FolderViewMode {
        stored[folderUrl].flatMap(FolderViewMode.init(rawValue:)) ?? .notebook
    }

    static func set(_ mode: FolderViewMode, for folderUrl: String) {
        stored[folderUrl] = mode.rawValue
        UserDefaults.standard.set(stored, forKey: key)
    }
}

struct FolderDetail: View {
    let folderUrl: String

    @Environment(NotesModel.self) private var model
    @State private var mode: FolderViewMode

    init(folderUrl: String) {
        self.folderUrl = folderUrl
        _mode = State(initialValue: FolderViewModes.mode(for: folderUrl))
    }

    /// The order the sidebar draws, so a folder reads the way it looks. Every
    /// other place that renders a folder's contents goes through this.
    private var children: [FolderNode] {
        model.orderedChildren(model.node(for: folderUrl)?.children ?? [], in: folderUrl)
    }

    var body: some View {
        Group {
            switch mode {
            case .notebook:
                FolderNotebook(children: children)
            case .sketchpad:
                FolderSketchpad(children: children)
            case .outline:
                FolderOutline(children: children)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem {
                Picker("View As", selection: $mode) {
                    ForEach(FolderViewMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbol)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .help("View As")
            }
        }
        .onChange(of: mode) { FolderViewModes.set(mode, for: folderUrl) }
    }
}

/// A note in a folder view: the real editor, not a preview of one. It carries
/// no toolbar and claims nothing on appear — several are mounted at once, and
/// the window's toolbar and `activeEditor` each belong to one editor. The
/// editor claims `activeEditor` when it takes first responder instead.
private struct FolderNoteCard: View {
    let noteUrl: String
    /// nil sizes the editor to its content; a value gives it a fixed box.
    var height: CGFloat?

    @Environment(NotesModel.self) private var model
    @Environment(ContextTracker.self) private var contextTracker
    @State private var editor = EditorController()

    var body: some View {
        RichTextEditor(
            noteUrl: noteUrl,
            model: model,
            controller: editor,
            contextTracker: contextTracker,
            scrolls: false
        )
        .frame(height: height ?? max(editor.contentHeight, 44))
    }
}

private struct FolderEmptyState: View {
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The folder as one continuous document — every note in order, editable in
/// place, separated by a rule rather than boxed into cards. One scroll view
/// owns the whole thing: the editors are sized to their content and do not
/// scroll themselves, because a scroll view inside another that scrolls the
/// same way is the thing the HIG tells you not to build.
struct FolderNotebook: View {
    let children: [FolderNode]

    private var notes: [FolderNode] { children.filter(\.isNote) }

    var body: some View {
        if notes.isEmpty {
            FolderEmptyState(message: "No notes in this folder")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(notes) { node in
                        Text(node.displayName)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                            .padding(.top, 22)
                            .padding(.bottom, 2)
                        FolderNoteCard(noteUrl: node.url)
                        if node.id != notes.last?.id {
                            Divider().padding(.horizontal, 20)
                        }
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 40)
            }
        }
    }
}

/// The corkboard: every note a card of the same size, editable where it sits,
/// and draggable to reorder. The order is the folder's own, so moving a card
/// moves it in the sidebar too.
struct FolderSketchpad: View {
    let children: [FolderNode]

    @Environment(NotesModel.self) private var model
    @State private var dropTarget: String?

    private var notes: [FolderNode] { children.filter(\.isNote) }

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 18)]

    var body: some View {
        if notes.isEmpty {
            FolderEmptyState(message: "No notes in this folder")
        } else {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(notes) { node in
                        card(for: node)
                    }
                }
                .padding(18)
            }
        }
    }

    private func card(for node: FolderNode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(node.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            FolderNoteCard(noteUrl: node.url, height: 190)
        }
        .background(Color.folderCard)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    dropTarget == node.url ? Color.accentColor : Color.primary.opacity(0.1),
                    lineWidth: dropTarget == node.url ? 2 : 1
                )
        }
        .draggable(node.url)
        .dropDestination(for: String.self) { urls, _ in
            dropTarget = nil
            guard let dragged = urls.first else { return false }
            model.reorderChild(dragged, adjacentTo: node.url, after: false)
            return true
        } isTargeted: { targeted in
            dropTarget = targeted ? node.url : nil
        }
    }
}

/// The folder as a tree: subfolders expand in place, and the columns are the
/// note's own context rather than a second line of grey text. Sorting is
/// deliberately absent — the folder already has an order, and a sortable
/// column would only fight it.
struct FolderOutline: View {
    let children: [FolderNode]

    @Environment(NotesModel.self) private var model
    @State private var selection: FolderNode.ID?

    var body: some View {
        if children.isEmpty {
            FolderEmptyState(message: "This folder is empty")
        } else {
            Table(of: FolderNode.self, selection: $selection) {
                TableColumn("Name") { node in
                    Label(
                        node.displayName,
                        systemImage: node.kind == "folder" ? "folder" : "doc.text"
                    )
                    .lineLimit(1)
                }
                .width(min: 200, ideal: 340)

                TableColumn("Created") { node in
                    Text(created(node))
                        .foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 150)

                TableColumn("Where") { node in
                    Text(model.noteRow(for: node.url).contextMeta?.location ?? "")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 90, ideal: 170)
            } rows: {
                OutlineGroup(children, children: \.children) { node in
                    TableRow(node)
                        .draggable(node.url)
                }
            }
        }
    }

    private func created(_ node: FolderNode) -> String {
        guard let date = model.noteRow(for: node.url).contextMeta?.created else { return "" }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

private extension Color {
    static var folderCard: Color {
        Color(nsColor: .controlBackgroundColor)
    }
}

#endif
