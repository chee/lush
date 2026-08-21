import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum PadTab: String, CaseIterable, Identifiable {
    case note
    case pocket

    var id: String { rawValue }

    var short: String {
        switch self {
        case .note: "Note"
        case .pocket: "Pocket"
        }
    }
}

/// A card being dragged from a pad into a note carries which pad it left, so
/// the note can take its spans and the pad can drop the item.
struct PadDrag {
    static let prefix = "lush-pad:"
    let padUrl: String
    let itemId: String

    var text: String { "\(Self.prefix)\(padUrl)|\(itemId)" }

    init(padUrl: String, itemId: String) {
        self.padUrl = padUrl
        self.itemId = itemId
    }

    init?(_ text: String) {
        guard text.hasPrefix(Self.prefix) else { return nil }
        let parts = text.dropFirst(Self.prefix.count).split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        padUrl = String(parts[0])
        itemId = String(parts[1])
    }
}

enum PadTool: String, CaseIterable, Identifiable {
    case hand
    case pen
    case eraser

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .hand: "hand.point.up.left"
        case .pen: "pencil.tip"
        case .eraser: "eraser"
        }
    }

    var help: String {
        switch self {
        case .hand: "Move and select"
        case .pen: "Draw"
        case .eraser: "Rub out"
        }
    }
}

struct ScratchpadView: View {
    let controller: EditorController?
    let noteUrl: String?

    @Environment(NotesModel.self) private var model
    @State private var tab: PadTab = .note
    @State private var tool: PadTool = .hand
    @State private var inkColor = "auto"
    @State private var inkSize: CGFloat = 4
    @AppStorage("padZoom") private var zoom: Double = 1

    private var store: PadStore { model.pads }

    private var padUrl: String? {
        switch tab {
        case .note: noteUrl.flatMap { store.notePad(for: $0) }
        case .pocket: store.pocketPadUrl
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            subnav
            Divider()
            canvas
        }
        .task(id: tab) {
            if tab == .pocket { await store.ensurePocketPad() }
        }
        .task(id: noteUrl) {
            if let noteUrl { _ = store.notePad(for: noteUrl) }
        }
        .onChange(of: tool) { _, tool in
            store.drawing = tool != .hand
        }
        .onDisappear { store.drawing = false }
        .onChange(of: controller?.padded) {
            tab = controller?.paddedPocket == true ? .pocket : .note
        }
    }

    /// One row, and a second only while the pen is out — an always-there strip
    /// of empty toolbar is pad you cannot put anything on.
    private var subnav: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Picker("", selection: $tab) {
                    ForEach(PadTab.allCases) { tab in
                        Text(tab.short).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(noteUrl == nil && tab == .note)

                Spacer(minLength: 0)

                ForEach(PadTool.allCases) { option in
                    Button {
                        tool = option
                    } label: {
                        Image(systemName: option.icon)
                            .frame(width: 20, height: 18)
                    }
                    .buttonStyle(.plain)
                    .background(
                        tool == option ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .help(option.help)
                }

                zoomControl
            }

            if tool == .pen {
                HStack(spacing: 8) {
                    ForEach(PadInk.palette, id: \.self) { hex in
                        swatch(hex)
                    }
                    Slider(value: $inkSize, in: 1...16)
                        .frame(maxWidth: 90)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var zoomControl: some View {
        HStack(spacing: 3) {
            Button { zoom = max(0.5, zoom - 0.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.plain)
            Text("\(Int(zoom * 100))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .onTapGesture { zoom = 1 }
            Button { zoom = min(4, zoom + 0.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.plain)
        }
    }

    private func swatch(_ hex: String) -> some View {
        let selected = inkColor == hex
        return Circle()
            .fill(PadInk.color(hex))
            .frame(width: 12, height: 12)
            .overlay {
                Circle()
                    .strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0)
                    .padding(-3)
            }
            .onTapGesture { inkColor = hex }
    }

    @ViewBuilder
    private var canvas: some View {
        if tab == .note, noteUrl == nil {
            ContentUnavailableView("No Note Open", systemImage: "square.grid.3x1.folder.badge.plus")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PadCanvasView(
                padUrl: padUrl,
                tab: tab,
                noteUrl: noteUrl,
                controller: controller,
                tool: tool,
                inkColor: inkColor,
                inkSize: inkSize,
                zoom: CGFloat(zoom)
            )
            .environment(model)
        }
    }
}

enum PadInk {
    static let palette = ["auto", "#e5484d", "#f5a524", "#30a46c", "#3e63dd", "#8e4ec6"]

    static func color(_ hex: String) -> Color {
        hex == "auto" ? .primary : Color(hex: hex)
    }
}

private struct PadCanvasView: View {
    let padUrl: String?
    let tab: PadTab
    let noteUrl: String?
    let controller: EditorController?
    let tool: PadTool
    let inkColor: String
    let inkSize: CGFloat
    let zoom: CGFloat

    @Environment(NotesModel.self) private var model
    @State private var live: [InkPoint] = []
    @State private var selection: Set<String> = []
    /// Where a selection drag has got to, before it is written to the pad.
    @State private var selectionOffset: CGSize = .zero
    @State private var marquee: CGRect?
    @State private var inkCache = InkPathCache()

    private var store: PadStore { model.pads }

    private var items: [PadItem] { store.items(of: padUrl) }

    var body: some View {
        let _ = store.version
        GeometryReader { proxy in
            let size = canvasSize(in: proxy.size)
            ScrollView([.vertical, .horizontal]) {
                ZStack(alignment: .topLeading) {
                    surface(size)
                    inkLayer(size)
                    selectionLayer
                    ForEach(items.filter { $0.padKind != .ink }, id: \.id) { item in
                        PadCardView(
                            item: item,
                            padUrl: padUrl ?? "",
                            tab: tab,
                            noteUrl: noteUrl,
                            controller: controller,
                            selected: selection.contains(item.id),
                            offset: selection.contains(item.id) ? selectionOffset : .zero,
                            locked: tool != .hand
                        )
                        .environment(model)
                    }
                    if items.isEmpty, live.isEmpty {
                        empty
                    }
                }
                // scale the canvas, then claim the space the scaled canvas
                // takes: sizing first makes the content scale twice over, and
                // everything then lands further from the pointer the further
                // down it is
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(width: size.width * zoom, height: size.height * zoom, alignment: .topLeading)
            }
            .overlay(alignment: .bottomTrailing) { if !selection.isEmpty { selectionActions } }
            // the pen owns the drag while it is out; otherwise the scroller
            // takes the gesture and the stroke never reaches the canvas
            .scrollDisabled(tool != .hand)
            .background(padPaper)
            #if os(macOS)
            .onDeleteCommand { deleteSelection() }
            #endif
        }
    }

    private var selectionActions: some View {
        HStack(spacing: 10) {
            Text("\(selection.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Delete", systemImage: "trash") { deleteSelection() }
                .labelStyle(.iconOnly)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(12)
    }

    private var padPaper: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }

    /// Always at least the visible area: a canvas smaller than its scroller is
    /// centred in it, and the space around it is not pad — nothing can be
    /// dropped or dragged there.
    private func canvasSize(in viewport: CGSize) -> CGSize {
        CGSize(
            width: max(viewport.width / zoom, (items.map { $0.rect.maxX }.max() ?? 0) + 240),
            height: max(viewport.height / zoom, (items.map { $0.rect.maxY }.max() ?? 0) + 200)
        )
    }

    private func surface(_ size: CGSize) -> some View {
        let sized = Color.clear
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
        #if os(macOS)
        return sized.background(PadDropTarget(pad: padUrl, tab: tab, noteUrl: noteUrl))
            .environment(model)
        #else
        return sized
            .dropDestination(for: String.self) { items, location in
                let text = items.joined(separator: "\n")
                guard !text.isEmpty else { return false }
                drop(text: text, at: location)
                return true
            }
            .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers, location in
                for provider in providers {
                    _ = provider.loadDataRepresentation(for: .image) { data, _ in
                        guard let data else { return }
                        Task { @MainActor in
                            drop(file: data, name: "image.png", ext: "png", at: location)
                        }
                    }
                }
                return !providers.isEmpty
            }
        #endif
    }

    private func inkLayer(_ size: CGSize) -> some View {
        StoredInkLayer(
            items: items,
            selection: selection,
            selectionOffset: selectionOffset,
            size: size,
            cache: inkCache
        )
        .equatable()
        .overlay {
            Canvas { context, _ in
                guard live.count > 0 else { return }
                context.fill(
                    Freehand.outline(InkStroke(color: inkColor, size: inkSize, points: live)),
                    with: .color(PadInk.color(inkColor))
                )
            }
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
        }
        // the capture rides on the ink layer rather than beside it, so a point
        // taken from a touch is the point the stroke is drawn at
        .overlay {
            if tool == .hand {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(handGesture)
                    .simultaneousGesture(
                        SpatialTapGesture(count: 2)
                            .onEnded { addBlankCard(at: $0.location) }
                    )
                    .contextMenu {
                        Button("New Card") { addBlankCard(at: nil) }
                        Button("Paste") { paste() }
                    }
            } else {
                InkCaptureView(
                    erasing: tool == .eraser,
                    onPoint: { point in
                        guard tool == .pen else { return }
                        live.append(point)
                    },
                    onEnd: { finish() },
                    onErase: { point in erase(at: point) }
                )
            }
        }
    }

    /// Selected strokes wear a frame, and the frame's corner resizes them.
    @ViewBuilder
    private var selectionLayer: some View {
        if let box = selectionBox {
            let shown = box.offsetBy(dx: selectionOffset.width, dy: selectionOffset.height)
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.accentColor.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(width: shown.width, height: shown.height)
                .offset(x: shown.origin.x, y: shown.origin.y)
                .allowsHitTesting(false)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 9, height: 9)
                .offset(x: shown.maxX - 4, y: shown.maxY - 4)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onEnded { drag in scaleSelection(box: box, by: drag.translation) }
                )
        }
        if let marquee {
            Rectangle()
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: marquee.width, height: marquee.height)
                .offset(x: marquee.origin.x, y: marquee.origin.y)
                .allowsHitTesting(false)
        }
    }

    /// One drag does the lot: on a stroke it moves the selection, on empty
    /// canvas it rubber-bands a new one.
    private var handGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if let hit = hit(at: value.startLocation) {
                    if !selection.contains(hit.id) { selection = [hit.id] }
                    selectionOffset = value.translation
                } else {
                    if marquee == nil, selectionOffset == .zero { selection = [] }
                    marquee = CGRect(
                        x: min(value.startLocation.x, value.location.x),
                        y: min(value.startLocation.y, value.location.y),
                        width: abs(value.translation.width),
                        height: abs(value.translation.height)
                    )
                }
            }
            .onEnded { value in
                if let marquee {
                    selection = Set(items.filter { $0.rect.intersects(marquee) }.map(\.id))
                    self.marquee = nil
                } else if selectionOffset != .zero {
                    moveSelection(by: selectionOffset)
                } else if hit(at: value.startLocation) == nil {
                    selection = []
                }
                selectionOffset = .zero
            }
    }

    private func hit(at point: CGPoint) -> PadItem? {
        items.last { $0.padKind == .ink && $0.rect.insetBy(dx: -4, dy: -4).contains(point) }
    }

    private var selectionBox: CGRect? {
        let boxes = items.filter { selection.contains($0.id) }.map(\.rect)
        guard let first = boxes.first else { return nil }
        return boxes.dropFirst().reduce(first) { $0.union($1) }
    }

    private func moveSelection(by translation: CGSize) {
        guard let padUrl else { return }
        for item in items where selection.contains(item.id) {
            store.move(item.id, in: padUrl, to: CGRect(
                x: max(0, item.x + translation.width),
                y: max(0, item.y + translation.height),
                width: item.w,
                height: item.h
            ))
        }
    }

    /// Strokes scale with their frame: the points move too, so a stroke blown
    /// up stays a stroke rather than a stretched picture of one.
    private func scaleSelection(box: CGRect, by translation: CGSize) {
        guard let padUrl, box.width > 1, box.height > 1 else { return }
        let sx = max(0.2, (box.width + translation.width) / box.width)
        let sy = max(0.2, (box.height + translation.height) / box.height)
        for item in items where selection.contains(item.id) {
            let x = box.origin.x + (item.x - box.origin.x) * sx
            let y = box.origin.y + (item.y - box.origin.y) * sy
            store.move(item.id, in: padUrl, to: CGRect(
                x: x,
                y: y,
                width: item.w * sx,
                height: item.h * sy
            ))
            if let stroke = item.stroke {
                store.setData(item.id, in: padUrl, data: stroke.scaled(x: sx, y: sy).json)
            }
        }
    }

    /// A blank card, at a double-click or wherever there is room.
    private func addBlankCard(at point: CGPoint?) {
        Task { @MainActor in
            guard let pad = await resolvedPad() else { return }
            let item = store.textItem(
                spans: [.block(BlockValue.paragraph)],
                origin: noteUrl,
                in: pad,
                at: point
            )
            store.add(item, to: pad)
        }
    }

    private func paste() {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        if let json = pasteboard.string(
            forType: NSPasteboard.PasteboardType(RichTextClipboard.spansTypeIdentifier)
        ) {
            let spans = SpanNode.decodeList(json)
            if !spans.isEmpty {
                drop(spans: spans, at: nil)
                return
            }
        }
        if let data = pasteboard.data(forType: .png) {
            drop(file: data, name: "image.png", ext: "png", at: nil)
            return
        }
        if let data = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: data),
           let png = rep.representation(using: .png, properties: [:]) {
            drop(file: png, name: "image.png", ext: "png", at: nil)
            return
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            drop(text: text, at: nil)
        }
        #else
        if let image = UIPasteboard.general.image, let data = image.pngData() {
            drop(file: data, name: "image.png", ext: "png", at: nil)
            return
        }
        if let text = UIPasteboard.general.string, !text.isEmpty {
            drop(text: text, at: nil)
        }
        #endif
    }

    private func deleteSelection() {
        guard let padUrl else { return }
        for id in selection { store.remove(id, from: padUrl) }
        selection = []
    }

    private var empty: some View {
        Text(tab == .note
             ? "Park text here with Format → Send to Note Scratchpad, or drop it in. Drag a card back onto the note to put it in."
             : "The pocket pad follows you between notes. Send cards here from a note scratchpad, drop text in, or draw.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(width: 260)
            .allowsHitTesting(false)
    }

    private func finish() {
        let points = live
        live = []
        guard points.count > 1 else { return }
        let stroke = InkStroke(color: inkColor, size: inkSize, points: points)
        Task { @MainActor in
            guard let pad = await resolvedPad() else { return }
            store.add(store.inkItem(stroke: stroke, origin: noteUrl), to: pad)
        }
    }

    private func erase(at point: CGPoint) {
        guard let padUrl, let hit = hit(at: point) else { return }
        store.remove(hit.id, from: padUrl)
    }

    private func drop(file data: Data, name: String, ext: String, at point: CGPoint?) {
        Task { @MainActor in
            guard let pad = await resolvedPad() else { return }
            await store.addFile(
                data: data,
                name: name,
                fileExtension: ext,
                to: pad,
                at: point,
                origin: noteUrl
            )
        }
    }

    private func drop(text: String, at point: CGPoint?) {
        drop(spans: PadStore.spans(fromPlainText: text), at: point)
    }

    private func drop(spans: [SpanNode], at point: CGPoint?) {
        Task { @MainActor in
            guard let pad = await resolvedPad() else { return }
            store.add(
                store.textItem(spans: spans, origin: noteUrl, in: pad, at: point),
                to: pad
            )
        }
    }

    /// The pad a write lands on, made on demand — a note gets its pad the first
    /// time something is put on it.
    private func resolvedPad() async -> String? {
        if let padUrl { return padUrl }
        switch tab {
        case .note:
            guard let noteUrl else { return nil }
            return await store.ensureNotePad(for: noteUrl)
        case .pocket:
            return await store.ensurePocketPad()
        }
    }
}

// MARK: - cards

final class InkPathCache {
    private var drawings: [String: (path: Path, color: Color)] = [:]

    func drawing(for item: PadItem) -> (path: Path, color: Color)? {
        let key = "\(item.id)|\(item.data)"
        if let cached = drawings[key] { return cached }
        guard let stroke = item.stroke else { return nil }
        if drawings.count > 512 { drawings.removeAll() }
        let drawing = (Freehand.outline(stroke), PadInk.color(stroke.color))
        drawings[key] = drawing
        return drawing
    }
}

private struct StoredInkLayer: View, Equatable {
    let items: [PadItem]
    let selection: Set<String>
    let selectionOffset: CGSize
    let size: CGSize
    let cache: InkPathCache

    static func == (a: StoredInkLayer, b: StoredInkLayer) -> Bool {
        a.size == b.size
            && a.selectionOffset == b.selectionOffset
            && a.selection == b.selection
            && a.items == b.items
    }

    var body: some View {
        Canvas { context, _ in
            for item in items where item.padKind == .ink {
                guard let drawing = cache.drawing(for: item) else { continue }
                let shift = selection.contains(item.id)
                    ? CGSize(width: item.x + selectionOffset.width, height: item.y + selectionOffset.height)
                    : CGSize(width: item.x, height: item.y)
                context.fill(
                    drawing.path.applying(
                        CGAffineTransform(translationX: shift.width, y: shift.height)
                    ),
                    with: .color(drawing.color)
                )
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

private struct PadCardView: View {
    let item: PadItem
    let padUrl: String
    let tab: PadTab
    let noteUrl: String?
    let controller: EditorController?
    let selected: Bool
    let offset: CGSize
    let locked: Bool

    @Environment(NotesModel.self) private var model
    @State private var dragOffset: CGSize = .zero
    @State private var resize: CGSize = .zero
    @State private var editing = false
    @State private var attributed = NSAttributedString()
    @State private var display: PImage?

    private var store: PadStore { model.pads }

    private var paper: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    private var size: CGSize {
        CGSize(
            width: max(120, item.w + resize.width),
            height: max(44, item.h + resize.height)
        )
    }

    /// The strip along the top is the handle; everything below it is the text,
    /// clickable straight through to the caret.
    var body: some View {
        VStack(spacing: 0) {
            grab
                .frame(height: 14)
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(editing ? 0.16 : 0.09))
                .overlay {
                    Capsule()
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: 22, height: 3)
                        .allowsHitTesting(false)
                }
            content
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(paper, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottomTrailing) { if !locked { resizeHandle } }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    editing || selected ? Color.accentColor : Color.secondary.opacity(0.25),
                    lineWidth: editing || selected ? 2 : 1
                )
        )
        .shadow(color: .black.opacity(0.16), radius: 5, y: 3)
        .offset(
            x: item.x + dragOffset.width + offset.width,
            y: item.y + dragOffset.height + offset.height
        )
        .contextMenu { menu }
        .onChange(of: item.data, initial: true) { renderText() }
        .onChange(of: store.version) { renderText() }
    }

    private func renderText() {
        attributed = RichText.attributed(from: item.spans, cache: store.cache)
    }

    @ViewBuilder
    private var menu: some View {
        if noteUrl != nil, controller?.core != nil {
            Button("Put Back in Note") { putBack() }
        }
        if tab == .note {
            Button("Send to Pocket Pad") { send(toPocket: true) }
        } else if noteUrl != nil {
            Button("Send to Note Scratchpad") { send(toPocket: false) }
        }
        Divider()
        Button("Delete", role: .destructive) { store.remove(item.id, from: padUrl) }
    }

    private func send(toPocket: Bool) {
        Task { @MainActor in
            var target: String?
            if toPocket {
                target = await store.ensurePocketPad()
            } else if let noteUrl {
                target = await store.ensureNotePad(for: noteUrl)
            }
            guard let target else { return }
            store.transfer(item, from: padUrl, to: target)
        }
    }

    private func putBack() {
        guard let core = controller?.core else { return }
        core.insertPadSpans(item.spans, at: nil)
        store.remove(item.id, from: padUrl)
    }

    private func moved(by translation: CGSize) {
        store.move(item.id, in: padUrl, to: CGRect(
            x: max(0, item.x + translation.width),
            y: max(0, item.y + translation.height),
            width: item.w,
            height: item.h
        ))
        dragOffset = .zero
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { resize = $0.translation }
                    .onEnded { drag in
                        resize = .zero
                        store.move(item.id, in: padUrl, to: CGRect(
                            x: item.x,
                            y: item.y,
                            width: max(120, item.w + drag.translation.width),
                            height: max(44, item.h + drag.translation.height)
                        ))
                    }
            )
    }

    private var grab: some View {
        #if os(macOS)
        PadCardGrab(
            padUrl: padUrl,
            itemId: item.id,
            attributed: attributed,
            onMove: { dragOffset = $0 },
            onDrop: { moved(by: $0) }
        )
        #else
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { dragOffset = $0.translation }
                    .onEnded { moved(by: $0.translation) }
            )
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if item.padKind == .image {
            picture
        } else {
            text
        }
    }

    private var picture: some View {
        Group {
            if let image = store.cache.displayImage(for: item.data) ?? display {
                #if os(macOS)
                Image(nsImage: image).resizable()
                #else
                Image(uiImage: image).resizable()
                #endif
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .scaledToFit()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(item.data)#\(store.version)") {
            display = await store.cache.displayImage(ensureFor: item.data)
        }
    }

    private var text: some View {
        #if os(macOS)
        PadCardEditor(
            attributed: attributed,
            core: controller?.core,
            onFocus: { editing = $0 },
            onCommit: { store.setData(item.id, in: padUrl, data: SpanNode.encodeList(RichText.spans(from: $0))) }
        )
        #else
        PadSnippetView(attributed: attributed)
            .allowsHitTesting(false)
            .clipped()
        #endif
    }
}

/// Read-only rendering of a card's text, for platforms and places that don't
/// edit it in place.
struct PadSnippetView {
    let attributed: NSAttributedString

    @MainActor
    final class Coordinator {
        let markers = ListMarkerLayoutDelegate()
    }

    @MainActor
    func makeCoordinator() -> Coordinator { Coordinator() }
}

#if os(macOS)
extension PadSnippetView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.textLayoutManager?.delegate = context.coordinator.markers
        textView.textLayoutManager?.renderingAttributesValidator = CodeHighlight.applyRenderingAttributes
        textView.textContainer?.widthTracksTextView = true
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 0)
        textView.textStorage?.setAttributedString(attributed)
        return textView
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        if nsView.attributedString() != attributed {
            nsView.textStorage?.setAttributedString(attributed)
        }
    }
}
#else
extension PadSnippetView: UIViewRepresentable {
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: true)
        textView.textLayoutManager?.delegate = context.coordinator.markers
        textView.textLayoutManager?.renderingAttributesValidator = CodeHighlight.applyRenderingAttributes
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        textView.textStorage.setAttributedString(attributed)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if !uiView.textStorage.isEqual(to: attributed) {
            uiView.textStorage.setAttributedString(attributed)
        }
    }
}
#endif

// MARK: - ink capture

/// Drawing input, by hand on both platforms: a pencil or tablet reports real
/// pressure, and everything else gets a fixed one that the stroke's own
/// speed-thinning turns into something with a bit of life in it.
struct InkCaptureView {
    let erasing: Bool
    let onPoint: (InkPoint) -> Void
    let onEnd: () -> Void
    let onErase: (CGPoint) -> Void
}

#if os(macOS)
extension InkCaptureView: NSViewRepresentable {
    func makeNSView(context: Context) -> Capture {
        let view = Capture()
        view.apply(self)
        return view
    }

    func updateNSView(_ nsView: Capture, context: Context) {
        nsView.apply(self)
    }

    final class Capture: NSView {
        var erasing = false
        var onPoint: ((InkPoint) -> Void)?
        var onEnd: (() -> Void)?
        var onErase: ((CGPoint) -> Void)?

        override var isFlipped: Bool { true }

        func apply(_ config: InkCaptureView) {
            erasing = config.erasing
            onPoint = config.onPoint
            onEnd = config.onEnd
            onErase = config.onErase
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .crosshair)
        }

        override func mouseDown(with event: NSEvent) {
            if erasing {
                onErase?(convert(event.locationInWindow, from: nil))
                return
            }
            emit(event)
            while let next = window?.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) {
                guard next.type == .leftMouseDragged else { break }
                emit(next)
            }
            onEnd?()
        }

        private func emit(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let pressure = event.subtype == .tabletPoint ? CGFloat(event.pressure) : 0.6
            onPoint?(InkPoint(x: point.x, y: point.y, pressure: max(0.05, pressure)))
        }
    }
}
#else
extension InkCaptureView: UIViewRepresentable {
    func makeUIView(context: Context) -> Capture {
        let view = Capture()
        view.apply(self)
        return view
    }

    func updateUIView(_ uiView: Capture, context: Context) {
        uiView.apply(self)
    }

    final class Capture: UIView {
        var erasing = false
        var onPoint: ((InkPoint) -> Void)?
        var onEnd: (() -> Void)?
        var onErase: ((CGPoint) -> Void)?

        private lazy var ink = InkRecognizer(target: self, action: #selector(handle))

        override init(frame: CGRect) {
            super.init(frame: frame)
            addGestureRecognizer(ink)
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            addGestureRecognizer(ink)
        }

        func apply(_ config: InkCaptureView) {
            erasing = config.erasing
            onPoint = config.onPoint
            onEnd = config.onEnd
            onErase = config.onErase
        }

        @objc private func handle(_ recognizer: InkRecognizer) {
            switch recognizer.state {
            case .began:
                if erasing {
                    onErase?(recognizer.location(in: self))
                } else {
                    emit(recognizer.samples)
                }
            case .changed:
                guard !erasing else { return }
                emit(recognizer.samples)
            case .ended, .cancelled, .failed:
                guard !erasing else { return }
                emit(recognizer.samples)
                onEnd?()
            default:
                break
            }
            recognizer.samples.removeAll()
        }

        private func emit(_ touches: [(CGPoint, CGFloat)]) {
            for (point, pressure) in touches {
                onPoint?(InkPoint(x: point.x, y: point.y, pressure: pressure))
            }
        }
    }

    /// Recognized the instant a finger lands, which is what makes the stroke
    /// win: the sheet's dismiss pan and any scroller are still waiting for
    /// movement, and a recognizer that has already begun cancels them.
    final class InkRecognizer: UIGestureRecognizer {
        var samples: [(CGPoint, CGFloat)] = []

        private func take(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = touches.first, let view else { return }
            for sample in event?.coalescedTouches(for: touch) ?? [touch] {
                let pressure = sample.maximumPossibleForce > 0 && sample.force > 0
                    ? sample.force / sample.maximumPossibleForce
                    : 0.6
                samples.append((sample.location(in: view), max(0.05, pressure)))
            }
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            take(touches, with: event)
            state = .began
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            take(touches, with: event)
            state = .changed
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            take(touches, with: event)
            state = .ended
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            state = .cancelled
        }
    }
}
#endif
