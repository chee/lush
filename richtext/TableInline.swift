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
        let measure: () -> CGSize
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
            let natural = host.measure()
            if natural.width > 1, natural.height > 1,
               abs(natural.width - rect.width) > 1 || abs(natural.height - rect.height) > 1 {
                resizes.append((location, natural))
                rect.size = natural
            }
            host.view.frame = rect
        }

        storage.enumerateAttribute(.amTableBox, in: full) { value, range, _ in
            guard let box = value as? TableBox else { return }
            let id = ObjectIdentifier(box)
            seen.insert(id)
            let host = hosts[id] ?? makeTableHost(for: box)
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
        return makeHost(root)
    }

    private func makeEmbedHost(for box: BlockBox) -> Host? {
        guard let core else { return nil }
        let block = box.value
        if block.type == "html" {
            let html = block.htmlSource ?? ""
            return makeHost(HtmlInlineView(html: html) { [weak core] in
                core?.controller.sheet = .html(HtmlBlockHandle(box: box, html: html))
            })
        }
        guard let url = block.embedUrl else { return nil }
        if core.isPatchworkDoc(url) {
            return makeHost(PatchworkBoxView(
                docUrl: url,
                toolId: block.attrs["tool"]?.stringValue
            ))
        }
        if let size = core.inlineVideoSize(for: url),
           let fileURL = core.videoFileURL(for: url) {
            return makeHost(VideoInlineView(fileURL: fileURL, size: size))
        }
        return nil
    }

    private func makeHost(_ root: some View) -> Host {
        #if os(macOS)
        let hosting = NSHostingView(rootView: root)
        return Host(view: hosting, measure: { hosting.fittingSize }, retained: nil)
        #else
        let controller = UIHostingController(rootView: root)
        controller.view.backgroundColor = .clear
        return Host(
            view: controller.view,
            measure: {
                controller.sizeThatFits(in: CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                ))
            },
            retained: controller
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
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(0..<grid.rows.count, id: \.self) { r in
                GridRow {
                    ForEach(0..<max(grid.columnCount, 1), id: \.self) { c in
                        TextField("", text: cellBinding(r, c), axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: isHeader(r) ? .semibold : .regular))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(width: cellWidth, alignment: .topLeading)
                            .background(isHeader(r) ? Color.secondary.opacity(0.12) : .clear)
                            .overlay(Rectangle().strokeBorder(line, lineWidth: 0.5))
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
        .fixedSize()
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
