import SwiftUI

#if os(macOS)
import AppKit

/// Which note owns a run of text. It rides on the text itself rather than on
/// a stored range, so an edit anywhere moves ownership with the characters
/// instead of invalidating an index.
private let notebookNote = NSAttributedString.Key("lushNotebookNote")
/// The title line standing between two notes. Owned by nothing, so the save
/// pass walks straight past it.
private let notebookBoundary = NSAttributedString.Key("lushNotebookBoundary")

/// A folder read as one document: every note's content in one text view, one
/// scroll view, one caret. The notes are not embedded editors — they are
/// rendered like any other text, and the boundary between two of them is a
/// heading rather than the edge of a box.
///
/// Boundaries are hard. A note's text is its own, an edit is never allowed to
/// span two of them, and every character maps to exactly one note. Merging two
/// notes by deleting the boundary would have to be a real operation with its
/// own undo, and until it is one a single keystroke must not be able to do it.
@MainActor
@Observable
final class FolderNotebookCore {
    private struct Section {
        var heads: [String]
        var lastJSON: String
    }

    @ObservationIgnored let storage = NSTextStorage()
    private(set) var loaded = false

    @ObservationIgnored private var sections: [String: Section] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private let cache = AssetCache()
    @ObservationIgnored private let model: NotesModel
    @ObservationIgnored private let origin = UUID()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var applying = false

    init(model: NotesModel) {
        self.model = model
    }

    func load(_ notes: [FolderNode]) async {
        let built = NSMutableAttributedString()
        var next: [String: Section] = [:]
        var nextOrder: [String] = []

        for node in notes {
            guard let snapshot = await model.spansSnapshot(for: node.url) else { continue }
            let spans = SpanNode.decodeList(snapshot.spansJson)
            let body = NSMutableAttributedString(
                attributedString: RichText.attributed(from: spans, cache: cache)
            )
            // An empty note still needs somewhere to put the caret.
            if body.length == 0 {
                body.append(NSAttributedString(
                    string: "\n",
                    attributes: RichText.attributes(block: .paragraph, marks: [:])
                ))
            }
            body.addAttribute(
                notebookNote,
                value: node.url,
                range: NSRange(location: 0, length: body.length)
            )
            built.append(boundary(titled: node.displayName, first: nextOrder.isEmpty))
            built.append(body)
            next[node.url] = Section(heads: snapshot.heads, lastJSON: snapshot.spansJson)
            nextOrder.append(node.url)
        }

        applying = true
        storage.setAttributedString(built)
        applying = false
        sections = next
        order = nextOrder
        loaded = true
    }

    /// The leading newline belongs to the boundary, not to the note above it.
    /// It closes that note's last paragraph so the title does not land on the
    /// same line, while keeping it out of the note's own slice — a trailing
    /// newline inside the slice would save an empty paragraph onto every note.
    private func boundary(titled title: String, first: Bool) -> NSAttributedString {
        var attributes = RichText.attributes(block: .heading(level: 2), marks: [:])
        attributes[notebookBoundary] = true
        attributes[.foregroundColor] = NSColor.secondaryLabelColor
        return NSAttributedString(
            string: (first ? "" : "\n") + title + "\n",
            attributes: attributes
        )
    }

    // MARK: - Ownership

    private func owner(at location: Int) -> String? {
        guard location >= 0, location < storage.length else { return nil }
        return storage.attribute(notebookNote, at: location, effectiveRange: nil) as? String
    }

    private func isBoundary(at location: Int) -> Bool {
        guard location >= 0, location < storage.length else { return false }
        return storage.attribute(notebookBoundary, at: location, effectiveRange: nil) != nil
    }

    /// The note a caret at `location` is writing into. A caret resting at the
    /// very start of a note sits just past a boundary, where looking backwards
    /// would answer with the note above it.
    func note(forCaretAt location: Int) -> String? {
        if let url = owner(at: location) { return url }
        if location > 0, let url = owner(at: location - 1) { return url }
        return nil
    }

    /// Typed text inherits the attributes to its left, which at the head of a
    /// note is the boundary. Stamping the caret keeps new text with its note.
    func typingAttributes(
        from current: [NSAttributedString.Key: Any],
        at location: Int
    ) -> [NSAttributedString.Key: Any] {
        var attributes = current
        attributes[notebookBoundary] = nil
        if let url = note(forCaretAt: location) {
            attributes[notebookNote] = url
        }
        return attributes
    }

    /// No edit may touch a boundary or reach across one. That is what makes
    /// every character's owner unambiguous, and what stops a backspace at the
    /// top of a note from swallowing the one above it.
    func allowsEdit(in range: NSRange) -> Bool {
        guard range.length > 0 else {
            // An insertion point inside a boundary owns nothing, including the
            // one above the first title: a notebook starts at its first note.
            return note(forCaretAt: range.location) != nil
        }
        var seen: Set<String> = []
        for location in range.location..<NSMaxRange(range) {
            if isBoundary(at: location) { return false }
            guard let url = owner(at: location) else { return false }
            seen.insert(url)
            if seen.count > 1 { return false }
        }
        return true
    }

    // MARK: - Saving

    func scheduleSave() {
        guard loaded, !applying else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    /// Slice the one storage back into the notes it came from and write each
    /// against the heads it was loaded at, so a note edited elsewhere in the
    /// meantime conflicts rather than being clobbered.
    func saveNow() async {
        guard loaded else { return }
        saveTask?.cancel()
        saveTask = nil

        var pieces: [String: NSMutableAttributedString] = [:]
        storage.enumerateAttribute(
            notebookNote,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let url = value as? String else { return }
            let piece = pieces[url] ?? NSMutableAttributedString()
            piece.append(storage.attributedSubstring(from: range))
            pieces[url] = piece
        }

        for url in order {
            guard let section = sections[url], let text = pieces[url] else { continue }
            let spans = RichText.spans(from: text)
            let json = SpanNode.encodeList(spans)
            guard json != section.lastJSON else { continue }
            sections[url]?.lastJSON = json
            let written = await model.updateDocument(
                url,
                json: json,
                title: RichText.title(from: spans),
                heads: section.heads.isEmpty ? nil : section.heads,
                origin: origin
            )
            if let written { sections[url]?.heads = written }
        }
    }
}

struct FolderNotebookText: NSViewRepresentable {
    let core: FolderNotebookCore

    func makeCoordinator() -> Coordinator {
        Coordinator(core: core)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.typingAttributes = RichText.attributes(block: .paragraph, marks: [:])
        textView.delegate = context.coordinator
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContentStorage?.textStorage = core.storage

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.automaticallyAdjustsContentInsets = true
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.textContentStorage?.textStorage !== core.storage {
            textView.textContentStorage?.textStorage = core.storage
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let core: FolderNotebookCore

        init(core: FolderNotebookCore) {
            self.core = core
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            core.allowsEdit(in: affectedCharRange)
        }

        func textDidChange(_ notification: Notification) {
            core.scheduleSave()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            textView.typingAttributes = core.typingAttributes(
                from: textView.typingAttributes,
                at: textView.selectedRange().location
            )
        }
    }
}

#endif
