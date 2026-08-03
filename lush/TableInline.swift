import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Positions live SwiftUI views over attachment characters, Proton-style:
/// the attachment reserves space in the text flow, the hosted view sits on
/// top of it and is repositioned after every layout pass.
@MainActor
final class InlineViewManager {
    weak var core: EditorCore?

    private struct Host {
        let view: PView
        let preferredSize: (CGFloat) -> CGSize
        let retained: AnyObject?
    }

    private var hosts: [ObjectIdentifier: Host] = [:]
    private var reconcileScheduled = false

    func setNeedsReconcile() {
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        Task { @MainActor in
            self.reconcileScheduled = false
            self.reconcile()
        }
    }

    func reconcile() {
        guard let core, let view = core.view, let storage = view.pStorage,
              let layoutManager = view.pLayoutManager,
              let textContainer = view.pTextContainer
        else { return }
        let origin = view.pTextOrigin
        let containerWidth = max(
            textContainer.size.width - textContainer.lineFragmentPadding * 2,
            0
        )
        var seen = Set<ObjectIdentifier>()
        var resizes: [(location: Int, size: CGSize)] = []
        let full = NSRange(location: 0, length: storage.length)

        func place(_ host: Host, at location: Int) {
            if host.view.superview !== view.pSelf {
                view.pSelf.addSubview(host.view)
            }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: location, length: 1),
                actualCharacterRange: nil
            )
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += origin.x
            rect.origin.y += origin.y
            guard containerWidth > 80 else {
                if host.view.frame != rect { host.view.frame = rect }
                return
            }
            let desired = host.preferredSize(containerWidth)
            guard desired.width > 1, desired.height > 1 else {
                if host.view.frame != rect { host.view.frame = rect }
                return
            }
            // compare against the attachment's own bounds, not the layout
            // rect — TextKit clamps wide attachments to the line fragment,
            // and chasing that difference loops layout forever
            let bounds = (storage.attribute(.attachment, at: location, effectiveRange: nil)
                as? NSTextAttachment)?.bounds.size ?? rect.size
            if abs(desired.width - bounds.width) > 1 || abs(desired.height - bounds.height) > 1 {
                resizes.append((location, desired))
            }
            let targetFrame = CGRect(origin: rect.origin, size: desired)
            if host.view.frame != targetFrame { host.view.frame = targetFrame }
        }

        storage.enumerateAttribute(.amTableBox, in: full) { value, range, _ in
            guard let box = value as? TableBox else { return }
            let id = ObjectIdentifier(box)
            seen.insert(id)
            let host = hosts[id] ?? makeTableHost(for: box)
            hosts[id] = host
            place(host, at: range.location)
        }
        storage.enumerateAttribute(.amColumnsBox, in: full) { value, range, _ in
            guard let box = value as? ColumnsBox else { return }
            let id = ObjectIdentifier(box)
            guard let host = hosts[id] ?? makeColumnsHost(for: box) else { return }
            seen.insert(id)
            hosts[id] = host
            place(host, at: range.location)
        }
        storage.enumerateAttribute(.amBlock, in: full) { value, range, _ in
            guard let box = value as? BlockBox, box.value.isEmbedBlock else { return }
            let id = ObjectIdentifier(box)
            guard let host = hosts[id] ?? makeEmbedHost(for: box) else { return }
            seen.insert(id)
            hosts[id] = host
            place(host, at: range.location)
        }
        for (id, host) in hosts where !seen.contains(id) {
            host.view.removeFromSuperview()
            hosts.removeValue(forKey: id)
        }
        for resize in resizes {
            resizeAttachment(at: resize.location, to: resize.size)
        }
        if containerWidth > 80 {
            clampImageAttachments(in: storage, layoutManager: layoutManager, to: containerWidth)
        }
    }

    /// Images and posters carry their ideal size; keep their bounds within
    /// the column, growing back if the column widens.
    private func clampImageAttachments(
        in storage: NSTextStorage,
        layoutManager: NSLayoutManager,
        to containerWidth: CGFloat
    ) {
        storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let attachment = value as? FittingImageAttachment else { return }
            let ideal = attachment.idealSize
            guard ideal.width > 0, ideal.height > 0 else { return }
            let width = min(ideal.width, containerWidth)
            let target = CGSize(width: width, height: ideal.height * width / ideal.width)
            let current = attachment.bounds.size
            guard abs(current.width - target.width) > 1
                || abs(current.height - target.height) > 1 else { return }
            attachment.bounds = CGRect(origin: .zero, size: target)
            let charRange = NSRange(location: range.location, length: 1)
            layoutManager.invalidateLayout(forCharacterRange: charRange, actualCharacterRange: nil)
            layoutManager.invalidateDisplay(forCharacterRange: charRange)
        }
    }

    func hasLiveView(at point: CGPoint) -> Bool {
        hosts.values.contains { $0.view.frame.contains(point) }
    }

    func resetHosts() {
        for host in hosts.values {
            host.view.removeFromSuperview()
        }
        hosts.removeAll()
        setNeedsReconcile()
    }

    private func resizeAttachment(at location: Int, to size: CGSize) {
        guard let view = core?.view, let storage = view.pStorage,
              location < storage.length,
              let attachment = storage.attribute(.attachment, at: location, effectiveRange: nil)
                as? NSTextAttachment,
              let layoutManager = view.pLayoutManager
        else { return }
        attachment.bounds = CGRect(origin: .zero, size: size)
        let range = NSRange(location: location, length: 1)
        layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        layoutManager.invalidateDisplay(forCharacterRange: range)
    }

    private func makeTableHost(for box: TableBox) -> Host {
        let root = TableInlineView(box: box) { [weak self] in
            self?.core?.tableChanged(box)
        }
        let (view, _, retained) = makeHosting(root)
        return Host(
            view: view,
            preferredSize: { width in
                CGSize(
                    width: min(CGFloat(max(box.grid.columnCount, 1)) * 150 + 2, width),
                    height: CGFloat(max(box.grid.rows.count, 1)) * 30 + 2
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
                }
            ))
            return Host(
                view: view,
                preferredSize: { width in CGSize(width: min(460, width), height: 300) },
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

struct TableInlineView: View {
    let box: TableBox
    let onEdit: () -> Void
    @State private var grid: TableGrid

    init(box: TableBox, onEdit: @escaping () -> Void) {
        self.box = box
        self.onEdit = onEdit
        _grid = State(initialValue: box.grid)
    }

    private let cellWidth: CGFloat = 150
    private var line: Color { Color.secondary.opacity(0.35) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(0..<grid.rows.count, id: \.self) { r in
                    GridRow {
                        ForEach(0..<max(grid.columnCount, 1), id: \.self) { c in
                            TextField("", text: cellBinding(r, c))
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, weight: isHeader(r) ? .semibold : .regular))
                                .padding(.horizontal, 8)
                                .frame(width: cellWidth, height: 30, alignment: .leading)
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
                    grid.rows.append(Array(repeating: "", count: max(grid.columnCount, 1)))
                    commit()
                }
                Button("Add Column") {
                    grid.rows = grid.rows.map { $0 + [""] }
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

    private func cellBinding(_ r: Int, _ c: Int) -> Binding<String> {
        Binding(
            get: {
                guard r < grid.rows.count, c < grid.rows[r].count else { return "" }
                return grid.rows[r][c]
            },
            set: { value in
                guard r < grid.rows.count, c < grid.rows[r].count else { return }
                grid.rows[r][c] = value
                commit()
            }
        )
    }

    private func commit() {
        box.grid = grid
        box.raw = nil
        onEdit()
    }
}
