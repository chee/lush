import SwiftUI

extension Color {
    static let lushSelection = Color(red: 1.0, green: 0.412, blue: 0.647)
}

#if os(macOS)

/// Finder column view over the folder tree. `path` is both the column stack and
/// the selection: column *i* highlights `path[i + 1]`, or `noteUrl` when it is
/// the last one.
struct ColumnBrowser: View {
    @Binding var path: [String]
    @Binding var noteUrl: String?
    var open: (String) -> Void
    var search: (String) -> Void
    var settings: (FolderNode) -> Void
    var move: ([String]) -> Void

    @Environment(NotesModel.self) private var model
    @State private var renamingUrl: String?
    @State private var renameText = ""
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(path.enumerated()), id: \.element) { entry in
                        column(entry.element, index: entry.offset)
                            .frame(width: 260)
                            .id(entry.element)
                        Divider()
                    }
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
            .onChange(of: path) { scroll(proxy) }
            .onChange(of: noteUrl) { scroll(proxy) }
            .onAppear { scroll(proxy) }
        }
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { pop() }
        .onKeyPress(.rightArrow) { descend() }
        .onKeyPress(.upArrow) { step(-1) }
        .onKeyPress(.downArrow) { step(1) }
        .onKeyPress(.return) { descend() }
        .onKeyPress(.space) { descend() }
        .onChange(of: model.folderTree) { prune() }
        .tint(.lushSelection)
    }

    private func column(_ folderUrl: String, index: Int) -> some View {
        List {
            ForEach(children(of: folderUrl)) { node in
                row(node, column: index)
                    .listRowBackground(background(node, column: index))
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .task(id: folderUrl) { await model.loadFolder(url: folderUrl) }
    }

    @ViewBuilder
    private func row(_ node: FolderNode, column: Int) -> some View {
        if node.kind == "folder" {
            folderRow(node)
                .contentShape(Rectangle())
                .onTapGesture { select(node, column: column) }
                .onDrag({ SidebarDrag.provider(node.url, kind: .item) }, preview: {
                    DragPreviewView(name: node.displayName, isFolder: true)
                })
                .modifier(
                    FolderDropTarget(
                        node: node,
                        isRoot: model.rootFolderUrls.contains(node.url),
                        model: model,
                        scope: "col"
                    )
                )
                .contextMenu { folderMenu(node) }
        } else {
            NoteRowView(
                node: node,
                renameText: renamingUrl == node.url ? $renameText : nil,
                commitRename: { commitRename(node) }
            )
                .contentShape(Rectangle())
                .onTapGesture {
                    guard renamingUrl != node.url else { return }
                    select(node, column: column)
                }
                .modifier(NoteReorderDropTarget(node: node, model: model, scope: "col"))
                .contextMenu {
                    NoteContextMenu(
                        node: node,
                        move: { move([node.url]) },
                        rename: { beginRename(node) }
                    )
                }
        }
    }

    private func folderRow(_ node: FolderNode) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            if renamingUrl == node.url {
                InlineRenameField(text: $renameText) { commitRename(node) }
            } else {
                Text(node.displayName)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if model.folderSettings(for: node.url).showCount {
                Text("\(model.folderNoteCount(node))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func folderMenu(_ node: FolderNode) -> some View {
        FolderContextMenu(
            node: node,
            open: { open($0) },
            search: { search(node.url) },
            settings: { settings(node) },
            rename: { beginRename(node) },
            move: { move([node.url]) }
        )
    }

    @ViewBuilder
    private func background(_ node: FolderNode, column: Int) -> some View {
        if selection(inColumn: column) == node.url {
            if column == path.count - 1 {
                Color.lushSelection.opacity(0.22)
            } else {
                Color.secondary.opacity(0.12)
            }
        }
    }

    private func children(of folderUrl: String) -> [FolderNode] {
        let raw = (model.node(for: folderUrl)?.children ?? [])
            .filter { !($0.kind == "folder" && model.focus.hides($0.url)) }
        return model.orderedChildren(raw, in: folderUrl)
    }

    private func selection(inColumn column: Int) -> String? {
        if column + 1 < path.count { return path[column + 1] }
        return column == path.count - 1 ? noteUrl : nil
    }

    private func select(_ node: FolderNode, column: Int) {
        if node.kind == "folder" {
            path = Array(path.prefix(column + 1)) + [node.url]
            noteUrl = nil
        } else {
            path = Array(path.prefix(column + 1))
            noteUrl = node.url
            open(node.url)
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let last = path.last else { return }
        Task { @MainActor in
            await Task.yield()
            withAnimation { proxy.scrollTo(last, anchor: .trailing) }
        }
    }

    private var activeColumn: Int { path.count - 1 }

    private func pop() -> KeyPress.Result {
        guard renamingUrl == nil, path.count > 1 else { return .ignored }
        path.removeLast()
        noteUrl = nil
        return .handled
    }

    private func descend() -> KeyPress.Result {
        guard renamingUrl == nil, let folderUrl = path.last else { return .ignored }
        guard let selected = selection(inColumn: activeColumn),
              let node = children(of: folderUrl).first(where: { $0.url == selected })
        else { return .ignored }
        select(node, column: activeColumn)
        return .handled
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        guard renamingUrl == nil, let folderUrl = path.last else { return .ignored }
        let items = children(of: folderUrl)
        guard !items.isEmpty else { return .ignored }
        let current = selection(inColumn: activeColumn)
            .flatMap { url in items.firstIndex { $0.url == url } }
        let next = current.map { min(max($0 + delta, 0), items.count - 1) } ?? 0
        select(items[next], column: activeColumn)
        return .handled
    }

    private func beginRename(_ node: FolderNode) {
        renameText = node.name
        renamingUrl = node.url
    }

    private func commitRename(_ node: FolderNode) {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingUrl = nil
        guard !name.isEmpty, name != node.name else { return }
        model.renameNode(node, to: name)
    }

    /// A folder deleted or moved elsewhere takes the columns below it with it.
    /// A root that doesn't resolve means the tree hasn't caught up yet, not
    /// that the path is stale.
    private func prune() {
        guard let root = path.first, model.node(for: root) != nil else { return }
        var kept: [String] = []
        for url in path {
            guard model.node(for: url) != nil else { break }
            kept.append(url)
        }
        if kept.count != path.count { path = kept }
    }
}

#endif
