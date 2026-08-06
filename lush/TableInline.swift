import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Hosts the live SwiftUI views for attachment characters. TextKit 2 places
/// and sizes them through `NSTextAttachmentViewProvider`; this manager only
/// owns the view cache, so embed state (a playing video, a focused column)
/// survives fragments leaving and re-entering the viewport.
@MainActor
final class InlineViewManager {
    weak var core: EditorCore?

    struct Host {
        let view: PView
        let preferredSize: (CGFloat) -> CGSize
        let retained: AnyObject?
        /// Retaining the box keeps its ObjectIdentifier from being recycled
        /// while the host is cached.
        var box: AnyObject?
    }

    private var hosts: [ObjectIdentifier: Host] = [:]

    func viewProvider(
        for attachment: EmbedAttachment,
        location: NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        guard let host = host(for: attachment.box) else { return nil }
        let provider = EmbedViewProvider(
            textAttachment: attachment,
            parentView: core?.view?.pSelf,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
        provider.host = host
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }

    private func host(for box: AnyObject) -> Host? {
        let id = ObjectIdentifier(box)
        if let hit = hosts[id], hit.box === box { return hit }
        var host: Host? = switch box {
        case let table as TableBox: makeTableHost(for: table)
        case let columns as ColumnsBox: makeColumnsHost(for: columns)
        case let block as BlockBox where block.value.isEmbedBlock: makeEmbedHost(for: block)
        default: nil
        }
        host?.box = box
        hosts[id] = host
        return host
    }

    /// A box's content changed shape (rows added, embed resized) — re-ask the
    /// provider for bounds by invalidating the attachment's layout.
    func embedChanged(_ box: AnyObject) {
        guard let view = core?.view, let storage = view.pStorage,
              let textLayoutManager = view.pTextLayoutManager,
              let contentManager = textLayoutManager.textContentManager
        else { return }
        storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            guard let attachment = value as? EmbedAttachment, attachment.box === box else { return }
            stop.pointee = true
            guard let textRange = contentManager.textRange(
                for: NSRange(location: range.location, length: 1)
            ) else { return }
            textLayoutManager.invalidateLayout(for: textRange)
        }
    }

    func hasLiveView(at point: CGPoint) -> Bool {
        hosts.values.contains { $0.view.superview != nil && $0.view.frame.contains(point) }
    }

    func resetHosts() {
        for host in hosts.values {
            host.view.removeFromSuperview()
        }
        hosts.removeAll()
    }

    private func makeTableHost(for box: TableBox) -> Host? {
        guard let core else { return nil }
        let cache = core.cache
        let root = TableInlineView(box: box, cache: cache) { [weak self] in
            self?.core?.tableChanged(box)
        }
        let (view, _, retained) = makeHosting(root)
        return Host(
            view: view,
            preferredSize: { width in
                CGSize(
                    width: min(CGFloat(max(box.grid.columnCount, 1)) * 150 + 2, width),
                    height: box.grid.rows.reduce(CGFloat(2)) { sum, row in
                        sum + TableInlineView.rowHeight(row, cache: cache)
                    }
                )
            },
            retained: retained
        )
    }

    private func makeColumnsHost(for box: ColumnsBox) -> Host? {
        guard let core else { return nil }
        let cache = core.cache
        let root = ColumnsInlineView(box: box, cache: cache) { [weak self] in
            self?.core?.columnsChanged(box)
        }
        let (view, _, retained) = makeHosting(root)
        return Host(
            view: view,
            preferredSize: { width in
                let count = max(box.columns.count, 1)
                let chrome = CGFloat(count - 1) * 17 + 12
                let columnWidth = max((width - chrome) / CGFloat(count), 60)
                let tallest = box.columns
                    .map { RichText.measuredHeight(of: $0, width: columnWidth - 4, cache: cache) }
                    .max() ?? 40
                return CGSize(width: width, height: max(tallest + 26, 80))
            },
            retained: retained
        )
    }

    private func makeEmbedHost(for box: BlockBox) -> Host? {
        guard let core else { return nil }
        let block = box.value
        if block.type == "html" {
            let html = block.htmlSource ?? ""
            let (view, _, retained) = makeHosting(HtmlInlineView(html: html) { [weak core] in
                core?.controller.sheet = .html(HtmlBlockHandle(box: box, html: html))
            })
            return Host(
                view: view,
                preferredSize: { width in CGSize(width: min(460, width), height: 220) },
                retained: retained
            )
        }
        if block.type == "context" {
            let (view, _, retained) = makeHosting(ContextInlineView(block: block))
            return Host(
                view: view,
                preferredSize: { width in CGSize(width: min(460, width), height: 28) },
                retained: retained
            )
        }
        // A block type this app doesn't know (pasted from another automerge
        // app, or from a newer lush) still renders as a chip — never as
        // invisible space — and round-trips untouched.
        if block.type != "embed" {
            let (view, _, retained) = makeHosting(UnknownBlockView(block: block))
            return Host(
                view: view,
                preferredSize: { width in CGSize(width: min(320, width), height: 44) },
                retained: retained
            )
        }
        guard let url = block.embedUrl else { return nil }
        if core.isPatchworkDoc(url) {
            let (view, _, retained) = makeHosting(PatchworkBoxView(
                docUrl: url,
                toolId: block.attrs["tool"]?.stringValue,
                onSelectTool: { [weak core] tool in
                    core?.updateEmbedTool(box, tool: tool)
                },
                onRemove: { [weak core] in
                    core?.removeEmbed(box)
                },
                onResize: { [weak core] width, height, commit in
                    core?.updateEmbedSize(box, width: width, height: height, commit: commit)
                }
            ))
            return Host(
                view: view,
                preferredSize: { width in
                    CGSize(
                        width: min(box.value.attrs["width"]?.doubleValue ?? 460, width),
                        height: box.value.attrs["height"]?.doubleValue ?? 300
                    )
                },
                retained: retained
            )
        }
        if let size = core.inlineVideoSize(for: url),
           let fileURL = core.videoFileURL(for: url) {
            let (view, _, retained) = makeHosting(VideoInlineView(fileURL: fileURL))
            return Host(
                view: view,
                preferredSize: { width in
                    guard size.width > width else { return size }
                    let scale = width / size.width
                    return CGSize(width: width, height: size.height * scale)
                },
                retained: retained
            )
        }
        if let name = core.cache.names[url],
           AssetCache.kind(forName: name) == "audio",
           let fileURL = core.cache.fileURLs[url] {
            let cache = core.cache
            let root = AudioInlineView(
                name: name,
                fileURL: fileURL,
                transcript: cache.transcripts[url]
            ) { [weak core] in
                core?.controller.sheet = .audio(assetUrl: url, fileURL: fileURL, name: name)
            }
            let (view, _, retained) = makeHosting(root)
            return Host(
                view: view,
                preferredSize: { width in
                    CGSize(
                        width: min(460, width),
                        height: cache.transcripts[url] != nil ? 132 : 84
                    )
                },
                retained: retained
            )
        }
        return nil
    }

    private func makeHosting(_ root: some View) -> (PView, () -> CGSize, AnyObject?) {
        #if os(macOS)
        let hosting = NSHostingView(rootView: root)
        return (hosting, { hosting.fittingSize }, nil)
        #else
        let controller = UIHostingController(rootView: root)
        controller.view.backgroundColor = .clear
        return (
            controller.view,
            {
                controller.sizeThatFits(in: CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                ))
            },
            controller
        )
        #endif
    }
}

final class EmbedViewProvider: NSTextAttachmentViewProvider {
    var host: InlineViewManager.Host?

    override func loadView() {
        view = host?.view
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        let fallback = CGRect(origin: .zero, size: textAttachment?.bounds.size ?? .zero)
        guard let host else { return fallback }
        let padding = textContainer?.lineFragmentPadding ?? 5
        let width = proposedLineFragment.width - padding * 2
        guard width > 80 else { return fallback }
        let size = host.preferredSize(width)
        guard size.width > 1, size.height > 1 else { return fallback }
        return CGRect(origin: .zero, size: size)
    }
}

struct TableInlineView: View {
    let box: TableBox
    let cache: AssetCache
    let onEdit: () -> Void
    @State private var grid: TableGrid

    init(box: TableBox, cache: AssetCache, onEdit: @escaping () -> Void) {
        self.box = box
        self.cache = cache
        self.onEdit = onEdit
        _grid = State(initialValue: box.grid)
    }

    static let cellWidth: CGFloat = 150
    private var line: Color { Color.secondary.opacity(0.35) }

    @MainActor
    static func rowHeight(_ row: [[SpanNode]], cache: AssetCache) -> CGFloat {
        let tallest = row.map {
            RichText.measuredHeight(of: $0, width: cellWidth - 12, cache: cache)
        }.max() ?? 0
        return max(30, tallest + 10)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(0..<grid.rows.count, id: \.self) { r in
                    GridRow {
                        ForEach(0..<max(grid.columnCount, 1), id: \.self) { c in
                            SpanCellEditor(spans: cellSpans(r, c), cache: cache) { spans in
                                setCell(r, c, spans)
                            }
                            .frame(
                                width: Self.cellWidth,
                                height: Self.rowHeight(grid.rows[r], cache: cache),
                                alignment: .topLeading
                            )
                            .background(isHeader(r) ? Color.secondary.opacity(0.12) : .clear)
                            .overlay(Rectangle().strokeBorder(line, lineWidth: 0.5))
                        }
                    }
                }
            }
        }
        .overlay(Rectangle().strokeBorder(line, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            Menu {
                Button("Add Row") {
                    grid.rows.append(Array(repeating: [], count: max(grid.columnCount, 1)))
                    commit()
                }
                Button("Add Column") {
                    grid.rows = grid.rows.map { $0 + [[]] }
                    commit()
                }
                Divider()
                Button("Remove Last Row") {
                    guard grid.rows.count > 1 else { return }
                    grid.rows.removeLast()
                    commit()
                }
                Button("Remove Last Column") {
                    guard grid.columnCount > 1 else { return }
                    grid.rows = grid.rows.map { Array($0.dropLast()) }
                    commit()
                }
                Divider()
                Toggle("Header Row", isOn: Binding(
                    get: { grid.hasHeader },
                    set: { grid.hasHeader = $0; commit() }
                ))
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .foregroundStyle(.secondary)
                    .background(Circle().fill(.background))
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(3)
        }
    }

    private func isHeader(_ row: Int) -> Bool {
        grid.hasHeader && row == 0
    }

    private func cellSpans(_ r: Int, _ c: Int) -> [SpanNode] {
        guard r < grid.rows.count, c < grid.rows[r].count else { return [] }
        return grid.rows[r][c]
    }

    private func setCell(_ r: Int, _ c: Int, _ spans: [SpanNode]) {
        guard r < grid.rows.count, c < grid.rows[r].count else { return }
        grid.rows[r][c] = spans
        commit()
    }

    private func commit() {
        box.grid = grid
        box.raw = nil
        onEdit()
    }
}

/// A one-cell rich editor: spans in, spans out on every edit.
private struct SpanCellEditor {
    let spans: [SpanNode]
    let cache: AssetCache
    let onEdit: ([SpanNode]) -> Void

    @MainActor
    final class Coordinator: NSObject {
        var onEdit: ([SpanNode]) -> Void
        let markers = ListMarkerLayoutDelegate()

        init(onEdit: @escaping ([SpanNode]) -> Void) {
            self.onEdit = onEdit
        }

        func storageChanged(_ storage: NSTextStorage, textLayoutManager: NSTextLayoutManager?, caret: Int) {
            onEdit(RichText.spans(from: storage))
            guard let textLayoutManager else { return }
            invalidateOrderedListRun(around: caret, textLayoutManager: textLayoutManager, storage: storage)
            invalidateCodeRun(around: caret, textLayoutManager: textLayoutManager, storage: storage)
        }
    }

    @MainActor
    func makeCoordinator() -> Coordinator {
        Coordinator(onEdit: onEdit)
    }
}

#if os(macOS)
extension SpanCellEditor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.textLayoutManager?.delegate = context.coordinator.markers
        textView.textLayoutManager?.renderingAttributesValidator = CodeHighlight.applyRenderingAttributes
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.typingAttributes = RichText.attributes(block: .paragraph, marks: [:])
        textView.delegate = context.coordinator
        textView.autoresizingMask = [.width, .height]
        if !spans.isEmpty {
            textView.textStorage?.setAttributedString(RichText.attributed(from: spans, cache: cache))
        }
        return textView
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        context.coordinator.onEdit = onEdit
    }
}

extension SpanCellEditor.Coordinator: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              let storage = textView.textStorage else { return }
        storageChanged(
            storage,
            textLayoutManager: textView.textLayoutManager,
            caret: textView.selectedRange().location
        )
    }
}
#else
extension SpanCellEditor: UIViewRepresentable {
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: true)
        textView.textLayoutManager?.delegate = context.coordinator.markers
        textView.textLayoutManager?.renderingAttributesValidator = CodeHighlight.applyRenderingAttributes
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)
        textView.typingAttributes = RichText.attributes(block: .paragraph, marks: [:])
        textView.delegate = context.coordinator
        if !spans.isEmpty {
            textView.textStorage.setAttributedString(RichText.attributed(from: spans, cache: cache))
        }
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.onEdit = onEdit
    }
}

extension SpanCellEditor.Coordinator: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        storageChanged(
            textView.textStorage,
            textLayoutManager: textView.textLayoutManager,
            caret: textView.selectedRange.location
        )
    }
}
#endif

struct UnknownBlockView: View {
    let block: BlockValue

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark.square.dashed")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(block.type)
                    .font(.caption)
                if let url = block.embedUrl {
                    Text(url)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}
