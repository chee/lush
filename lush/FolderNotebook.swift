import SwiftUI

#if os(macOS)
import AppKit

/// Which note owns a run of text. It rides on the text itself rather than on
/// a stored range, so an edit anywhere moves ownership with the characters
/// instead of invalidating an index.
private let notebookNote = NSAttributedString.Key("lushNotebookNote")
/// Structure rather than content: the title line between two notes and the
/// newlines that close it off. The body save pass walks straight past it.
private let notebookBoundary = NSAttributedString.Key("lushNotebookBoundary")
/// The editable part of a boundary — the note's name. Typing here renames the
/// note; the newlines on either side carry no title and so cannot be typed in.
private let notebookTitle = NSAttributedString.Key("lushNotebookTitle")

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
        var lastName: String
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
            built.append(boundary(
                titled: node.displayName,
                url: node.url,
                first: nextOrder.isEmpty
            ))
            built.append(body)
            next[node.url] = Section(
                heads: snapshot.heads,
                lastJSON: snapshot.spansJson,
                lastName: node.displayName
            )
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
    private func boundary(titled title: String, url: String, first: Bool) -> NSAttributedString {
        var attributes = RichText.attributes(block: .heading(level: 2), marks: [:])
        attributes[notebookBoundary] = true
        attributes[.foregroundColor] = NSColor.secondaryLabelColor
        let line = NSMutableAttributedString()
        if !first {
            line.append(NSAttributedString(string: "\n", attributes: attributes))
        }
        var titleAttributes = attributes
        titleAttributes[notebookTitle] = url
        line.append(NSAttributedString(string: title, attributes: titleAttributes))
        line.append(NSAttributedString(string: "\n", attributes: attributes))
        return line
    }

    private func titleOwner(at location: Int) -> String? {
        guard location >= 0, location < storage.length else { return nil }
        return storage.attribute(notebookTitle, at: location, effectiveRange: nil) as? String
    }

    /// The note whose name a caret at `location` is editing, by the same rule
    /// bodies use: the run under the caret, else the one it sits just past.
    func title(forCaretAt location: Int) -> String? {
        if let url = titleOwner(at: location) { return url }
        if location > 0, let url = titleOwner(at: location - 1) { return url }
        return nil
    }

    private func titleRange(of url: String) -> NSRange? {
        var found: NSRange?
        storage.enumerateAttribute(
            notebookTitle,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            if value as? String == url {
                found = range
                stop.pointee = true
            }
        }
        return found
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
    /// note is the boundary and at the head of a title is a bare newline.
    /// Stamping the caret keeps new text with whatever it is being typed into.
    func typingAttributes(
        from current: [NSAttributedString.Key: Any],
        at location: Int
    ) -> [NSAttributedString.Key: Any] {
        var attributes = current
        if let url = title(forCaretAt: location) {
            attributes[notebookNote] = nil
            attributes[notebookBoundary] = true
            attributes[notebookTitle] = url
            return attributes
        }
        attributes[notebookBoundary] = nil
        attributes[notebookTitle] = nil
        if let url = note(forCaretAt: location) {
            attributes[notebookNote] = url
        }
        return attributes
    }

    /// An edit stays inside one note's body or inside one note's title, and
    /// never spans two of either or touches the newlines holding a boundary
    /// together. That is what makes every character's owner unambiguous, and
    /// what stops a backspace at the top of a note swallowing the one above.
    func allowsEdit(in range: NSRange, replacement: String) -> Bool {
        guard range.length > 0 else {
            if title(forCaretAt: range.location) != nil {
                return !replacement.contains("\n")
            }
            // An insertion point in the structure owns nothing, including the
            // one above the first title: a notebook starts at its first note.
            return note(forCaretAt: range.location) != nil
        }

        var titles: Set<String> = []
        var bodies: Set<String> = []
        for location in range.location..<NSMaxRange(range) {
            if let url = titleOwner(at: location) {
                titles.insert(url)
            } else if isBoundary(at: location) {
                return false
            } else if let url = owner(at: location) {
                bodies.insert(url)
            } else {
                return false
            }
            if titles.count + bodies.count > 1 { return false }
        }

        guard let url = titles.first else { return true }
        // A title is one line, and retyping all of it is fine — but deleting
        // it outright would leave nowhere to type and no way to name the note
        // again, so the run has to survive.
        if replacement.contains("\n") { return false }
        return !replacement.isEmpty || range.length < (titleRange(of: url)?.length ?? 0)
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

        var titles: [String: String] = [:]
        storage.enumerateAttribute(
            notebookTitle,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let url = value as? String else { return }
            titles[url, default: ""] += storage.attributedSubstring(from: range).string
        }

        for url in order {
            if let name = titles[url]?.trimmingCharacters(in: .whitespacesAndNewlines),
               name != sections[url]?.lastName,
               let node = model.node(for: url) {
                sections[url]?.lastName = name
                model.renameNode(node, to: name)
            }
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
            core.allowsEdit(in: affectedCharRange, replacement: replacementString ?? "")
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
