#if os(macOS)
import AppKit
import SwiftUI

/// A card is a real editor over the spans the pad holds: the same text view
/// class as the note, so clicks, keys, menus and formatting all behave the
/// same. What the card holds afterwards goes back to the pad item.
final class PadCardTextView: EditorTextView, PadCardEditing {
    var onFocus: ((Bool) -> Void)?
    var onCommit: ((NSAttributedString) -> Void)?

    private let cardUndoManager = UndoManager()
    override var undoManager: UndoManager? { cardUndoManager }
    private var commitTask: Task<Void, Never>?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            core?.focusedPadCard = self
            let onFocus = onFocus
            Task { @MainActor in onFocus?(true) }
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            if core?.focusedPadCard === self { core?.focusedPadCard = nil }
            commit()
            let onFocus = onFocus
            Task { @MainActor in onFocus?(false) }
        }
        return resigned
    }

    override func cancelOperation(_ sender: Any?) {
        window?.makeFirstResponder(nil)
    }

    func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.commit()
        }
    }

    func commit() {
        commitTask?.cancel()
        commitTask = nil
        onCommit?(attributedString())
    }

    private func focused(_ body: () -> Void) {
        guard let core, core.focusedPadCard === self else {
            body()
            return
        }
        core.onFocusedText { _ in body() }
    }

    override func mouseDown(with event: NSEvent) {
        focused { super.mouseDown(with: event) }
    }

    override func keyDown(with event: NSEvent) {
        focused { super.keyDown(with: event) }
    }

    /// Menu and key-equivalent actions — paste, undo, the edit menu — arrive
    /// through the responder chain rather than as key events.
    override func tryToPerform(_ action: Selector, with object: Any?) -> Bool {
        var handled = false
        focused { handled = super.tryToPerform(action, with: object) }
        return handled
    }

    // the card sets its own width; the note's centring insets have no place here
    override func pApplyMaxWidth() {}
}

struct PadCardEditor: NSViewRepresentable {
    let attributed: NSAttributedString
    /// Formatting commands run through the open note's core when there is one.
    let core: EditorCore?
    let onFocus: (Bool) -> Void
    let onCommit: (NSAttributedString) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(core: core) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PadCardTextView(usingTextLayoutManager: true)
        textView.core = core
        textView.delegate = context.coordinator
        textView.textLayoutManager?.delegate = context.coordinator.markers
        textView.textLayoutManager?.renderingAttributesValidator = CodeHighlight.applyRenderingAttributes
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 2)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textStorage?.setAttributedString(attributed)
        textView.typingAttributes = RichText.attributes(block: .paragraph, marks: [:])
        context.coordinator.markers.driveTypingAttributes(from: textView)
        context.coordinator.markers.driveSelection(from: textView)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? PadCardTextView else { return }
        textView.core = core
        textView.onFocus = onFocus
        textView.onCommit = onCommit
        context.coordinator.core = core
        let focused = textView.window?.firstResponder === textView
        // reseeding under the caret would eat the edit that produced this
        // update; a card being typed in is already the source of truth
        if !focused, !textView.attributedString().isEqual(to: attributed) {
            textView.textStorage?.setAttributedString(attributed)
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        (nsView.documentView as? PadCardTextView)?.commit()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var core: EditorCore?
        let markers = ListMarkerLayoutDelegate()

        init(core: EditorCore?) {
            self.core = core
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            view.undoManager
        }

        func textDidChange(_ notification: Notification) {
            (notification.object as? PadCardTextView)?.scheduleCommit()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            core?.onFocusedText { $0.refreshFormattingState() }
        }

        func textView(_ view: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let core else { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                return core.handleReturn()
            }
            if commandSelector == #selector(NSResponder.insertLineBreak(_:))
                || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                if core.blockAtSelection().type == "code-block" {
                    return core.leaveCodeBlock()
                }
                core.insertSoftLineBreak()
                return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                return core.nestListItem()
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                return core.unnestListItem()
            }
            return false
        }

        /// No splice pipeline here: the card's text is its own spans blob, and
        /// the commit writes the whole thing.
        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            if replacementString == " ",
               affectedCharRange.length == 0,
               core?.handleMarkdownTrigger(at: affectedCharRange.location) == true {
                return false
            }
            return true
        }
    }
}

/// What the pasteboard holds before anything has been read: a hover never gets
/// further than this.
private enum PadDroppedFile {
    case url(URL)
    case png(Data)
    case tiff(Data)
}

/// The bytes behind a drop. Reading a file and re-encoding a TIFF are the slow
/// half, so this runs off the main actor once the drop has landed.
private func padFileBytes(_ file: PadDroppedFile) -> (Data, String, String)? {
    switch file {
    case .url(let url):
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension.lowercased()
        return (data, url.lastPathComponent, ext)
    case .png(let data):
        return (data, "image.png", "png")
    case .tiff(let data):
        guard let rep = NSBitmapImageRep(data: data),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        return (png, "image.png", "png")
    }
}

/// The pad takes dropped text as a new card. Text dragged out of the note
/// leaves it: the drop answers `.move`, which is the note's cue as the drag
/// source to remove what was dragged.
struct PadDropTarget: NSViewRepresentable {
    let pad: String?
    let tab: PadTab
    let noteUrl: String?

    @Environment(NotesModel.self) private var model

    func makeNSView(context: Context) -> Drop {
        let view = Drop()
        view.registerForDraggedTypes([
            .string,
            .fileURL,
            .png,
            .tiff,
            NSPasteboard.PasteboardType(RichTextClipboard.spansTypeIdentifier),
        ])
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: Drop, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: Drop) {
        view.pad = pad
        view.tab = tab
        view.noteUrl = noteUrl
        view.store = model.pads
    }

    final class Drop: NSView {
        var pad: String?
        var tab: PadTab = .note
        var noteUrl: String?
        var store: PadStore?

        // the pad places cards from its top-left, and so does this
        override var isFlipped: Bool { true }

        /// Text dragged out of a note moves onto the pad; hold option and the
        /// note keeps its copy. A drag from another app is always a copy —
        /// there is nothing here to take it out of.
        private func operation(_ sender: NSDraggingInfo) -> NSDragOperation {
            let pasteboard = sender.draggingPasteboard
            if let text = pasteboard.string(forType: .string), text.hasPrefix(PadDrag.prefix) {
                return []
            }
            if hasFile(pasteboard) { return .copy }
            guard spans(from: pasteboard) != nil else { return [] }
            guard sender.draggingSource is EditorTextView else { return .copy }
            return NSEvent.modifierFlags.contains(.option) ? .copy : .move
        }

        private func spans(from pasteboard: NSPasteboard) -> [SpanNode]? {
            if let json = pasteboard.string(
                forType: NSPasteboard.PasteboardType(RichTextClipboard.spansTypeIdentifier)
            ) {
                let spans = SpanNode.decodeList(json)
                if !spans.isEmpty { return spans }
            }
            guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
            return PadStore.spans(fromPlainText: text)
        }

        private func fileURL(from pasteboard: NSPasteboard) -> URL? {
            (pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL])?.first
        }

        /// Hover asks this and nothing more: a drag-over tick must not read a
        /// single byte of what is being dragged.
        private func hasFile(_ pasteboard: NSPasteboard) -> Bool {
            fileURL(from: pasteboard) != nil
                || pasteboard.availableType(from: [.png, .tiff]) != nil
        }

        /// An image or file lands as an asset doc of its own, the same as one
        /// dropped in a note.
        private func file(from pasteboard: NSPasteboard) -> PadDroppedFile? {
            if let url = fileURL(from: pasteboard) {
                return .url(url)
            }
            if let data = pasteboard.data(forType: .png) {
                return .png(data)
            }
            if let data = pasteboard.data(forType: .tiff) {
                return .tiff(data)
            }
            return nil
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            operation(sender)
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            operation(sender)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let store else { return false }
            let pasteboard = sender.draggingPasteboard
            // the pasteboard only lives as long as this call, so what is on it
            // is taken here and the bytes behind it read off the main actor
            let dropped = file(from: pasteboard)
            let spans = spans(from: pasteboard)
            guard dropped != nil || spans != nil else { return false }
            let point = convert(sender.draggingLocation, from: nil)
            let pad = pad
            let tab = tab
            let noteUrl = noteUrl
            Task { @MainActor in
                let bytes: (Data, String, String)?
                if let dropped {
                    bytes = await Task.detached { padFileBytes(dropped) }.value
                } else {
                    bytes = nil
                }
                guard bytes != nil || spans != nil else { return }
                let target: String?
                if let pad {
                    target = pad
                } else if tab == .note, let noteUrl {
                    target = await store.ensureNotePad(for: noteUrl)
                } else {
                    target = await store.ensurePocketPad()
                }
                guard let target else { return }
                if let (data, name, ext) = bytes {
                    await store.addFile(
                        data: data,
                        name: name,
                        fileExtension: ext,
                        to: target,
                        at: point,
                        origin: noteUrl
                    )
                } else if let spans {
                    store.add(
                        store.textItem(spans: spans, origin: noteUrl, in: target, at: point),
                        to: target
                    )
                }
            }
            return true
        }
    }
}

/// One drag for a card, tracked by hand: it slides around the pad, and the
/// moment the pointer reaches the note it becomes a document drag the editor
/// can take. SwiftUI can't hand a gesture over to a drag session mid-flight,
/// which is why the tracking loop lives here.
struct PadCardGrab: NSViewRepresentable {
    let padUrl: String
    let itemId: String
    let attributed: NSAttributedString
    let onMove: (CGSize) -> Void
    let onDrop: (CGSize) -> Void

    func makeNSView(context: Context) -> Grab { Grab() }

    func updateNSView(_ nsView: Grab, context: Context) {
        nsView.padUrl = padUrl
        nsView.itemId = itemId
        nsView.attributed = attributed
        nsView.onMove = onMove
        nsView.onDrop = onDrop
    }

    final class Grab: NSView, NSDraggingSource {
        var padUrl = ""
        var itemId = ""
        var attributed = NSAttributedString()
        var onMove: ((CGSize) -> Void)?
        var onDrop: ((CGSize) -> Void)?

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            let start = event.locationInWindow
            var translation = CGSize.zero
            while let next = window?.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) {
                guard next.type == .leftMouseDragged else { break }
                let point = next.locationInWindow
                translation = CGSize(width: point.x - start.x, height: start.y - point.y)
                if overTheNote(point) {
                    // the card keeps its place on the pad unless the drop
                    // lands somewhere that takes it
                    onMove?(.zero)
                    dragToNote(with: next)
                    return
                }
                onMove?(translation)
            }
            onDrop?(translation)
        }

        private func overTheNote(_ windowPoint: CGPoint) -> Bool {
            var hit = window?.contentView?.hitTest(windowPoint)
            while let view = hit {
                if view is EditorTextView { return !(view is PadCardTextView) }
                hit = view.superview
            }
            guard let scroll = enclosingScrollView else { return false }
            return !scroll.bounds.contains(scroll.convert(windowPoint, from: nil))
        }

        private func dragToNote(with event: NSEvent) {
            let item = NSPasteboardItem()
            item.setString(PadDrag(padUrl: padUrl, itemId: itemId).text, forType: .string)
            let dragItem = NSDraggingItem(pasteboardWriter: item)
            dragItem.setDraggingFrame(bounds, contents: cardImage())
            beginDraggingSession(with: [dragItem], event: event, source: self)
        }

        /// What travels with the pointer is the card itself, drawn.
        private func cardImage() -> NSImage {
            let size = bounds.size
            let image = NSImage(size: size)
            guard size.width > 1, size.height > 1 else { return image }
            image.lockFocusFlipped(true)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let card = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
                let shape = NSBezierPath(roundedRect: card, xRadius: 6, yRadius: 6)
                NSColor.textBackgroundColor.withAlphaComponent(0.95).setFill()
                shape.fill()
                NSColor.separatorColor.setStroke()
                shape.stroke()
                attributed.draw(
                    with: card.insetBy(dx: 8, dy: 8),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                )
            }
            image.unlockFocus()
            return image
        }

        /// Move, not copy: the card goes to the note rather than being
        /// duplicated, and the pointer shows no badge. Option keeps it here.
        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            NSEvent.modifierFlags.contains(.option) ? .copy : .move
        }
    }
}
#endif
