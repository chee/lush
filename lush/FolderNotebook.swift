import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Which note owns a run of text. It rides on the text itself rather than on
/// a stored range, so an edit anywhere moves ownership with the characters
/// instead of invalidating an index.
let notebookNote = NSAttributedString.Key("lushNotebookNote")
/// Structure rather than content: the title line between two notes and the
/// newlines that close it off. The body save pass walks straight past it.
let notebookBoundary = NSAttributedString.Key("lushNotebookBoundary")
/// The editable part of a boundary — the note's name. Typing here renames the
/// note; the newlines on either side carry no title and so cannot be typed in.
let notebookTitle = NSAttributedString.Key("lushNotebookTitle")

/// The folder's notes concatenated into one piece of text, and the rules for
/// reading and editing it: who owns each character, where a caret is writing,
/// and which edits are allowed.
///
/// Boundaries are hard. A note's text is its own, an edit is never allowed to
/// span two of them, and every character maps to exactly one note. Merging two
/// notes by deleting the boundary would have to be a real operation with its
/// own undo, and until it is one a single keystroke must not be able to do it.
///
/// Deliberately knows nothing about the document store: the rules are worth
/// testing on their own, and a test should not need a Rust core to run.
@MainActor
final class NotebookDocument {
    struct Section {
        let url: String
        let title: String
        let body: NSAttributedString
    }

    let storage = NSTextStorage()
    private(set) var order: [String] = []

    private var boundaryColor: PColor {
        #if os(macOS)
        .secondaryLabelColor
        #else
        .secondaryLabel
        #endif
    }

    func rebuild(_ sections: [Section]) {
        let built = NSMutableAttributedString()
        var urls: [String] = []
        for section in sections {
            let body = NSMutableAttributedString(attributedString: section.body)
            // An empty note still needs somewhere to put the caret.
            if body.length == 0 {
                body.append(NSAttributedString(
                    string: "\n",
                    attributes: RichText.attributes(block: .paragraph, marks: [:])
                ))
            }
            body.addAttribute(
                notebookNote,
                value: section.url,
                range: NSRange(location: 0, length: body.length)
            )
            built.append(boundary(
                titled: section.title,
                url: section.url,
                first: urls.isEmpty
            ))
            built.append(body)
            urls.append(section.url)
        }
        storage.setAttributedString(built)
        order = urls
    }

    /// The leading newline belongs to the boundary, not to the note above it.
    /// It closes that note's last paragraph so the title does not land on the
    /// same line, while keeping it out of the note's own slice — a trailing
    /// newline inside the slice would save an empty paragraph onto every note.
    private func boundary(titled title: String, url: String, first: Bool) -> NSAttributedString {
        var attributes = RichText.attributes(block: .heading(level: 2), marks: [:])
        attributes[notebookBoundary] = true
        attributes[.foregroundColor] = boundaryColor
        // Room above the title for the rule the text view draws there.
        if !first,
           let base = attributes[.paragraphStyle] as? NSParagraphStyle,
           let spaced = base.mutableCopy() as? NSMutableParagraphStyle {
            spaced.paragraphSpacingBefore = 30
            attributes[.paragraphStyle] = spaced
        }
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

    // MARK: - Ownership

    func owner(at location: Int) -> String? {
        guard location >= 0, location < storage.length else { return nil }
        return storage.attribute(notebookNote, at: location, effectiveRange: nil) as? String
    }

    func titleOwner(at location: Int) -> String? {
        guard location >= 0, location < storage.length else { return nil }
        return storage.attribute(notebookTitle, at: location, effectiveRange: nil) as? String
    }

    func isBoundary(at location: Int) -> Bool {
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

    /// The note whose name a caret at `location` is editing, by the same rule
    /// bodies use: the run under the caret, else the one it sits just past.
    func title(forCaretAt location: Int) -> String? {
        if let url = titleOwner(at: location) { return url }
        if location > 0, let url = titleOwner(at: location - 1) { return url }
        return nil
    }

    func titleRange(of url: String) -> NSRange? {
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

    /// Where the text view draws a rule between two notes: the head of every
    /// title but the first, which has nothing above it to be separated from.
    func separatorLocations() -> [Int] {
        var locations: [Int] = []
        storage.enumerateAttribute(
            notebookTitle,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard value != nil, range.location > 0 else { return }
            locations.append(range.location)
        }
        return locations
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
            // An insertion point belonging to no note at all, which only an
            // empty notebook has.
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

    // MARK: - Reading back

    /// The storage sliced back into the notes it came from. Boundary runs own
    /// no note and so never reach a slice.
    func bodies() -> [String: NSAttributedString] {
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
        return pieces
    }

    func titles() -> [String: String] {
        var names: [String: String] = [:]
        storage.enumerateAttribute(
            notebookTitle,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let url = value as? String else { return }
            names[url, default: ""] += storage.attributedSubstring(from: range).string
        }
        return names
    }
}

/// A folder read as one document: every note's content in one text view, one
/// scroll view, one caret. The notes are not embedded editors — they are
/// rendered like any other text, and the boundary between two of them is a
/// title over a dotted rule rather than the edge of a box.
@MainActor
@Observable
final class FolderNotebookCore {
    private struct Section {
        var heads: [String]
        var lastJSON: String
        var lastName: String
    }

    @ObservationIgnored let document = NotebookDocument()
    private(set) var loaded = false

    @ObservationIgnored private var sections: [String: Section] = [:]
    @ObservationIgnored private let cache = AssetCache()
    @ObservationIgnored private let model: NotesModel
    @ObservationIgnored private let origin = UUID()
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(model: NotesModel) {
        self.model = model
    }

    func load(_ notes: [FolderNode]) async {
        var built: [NotebookDocument.Section] = []
        var next: [String: Section] = [:]

        for node in notes {
            guard let snapshot = await model.spansSnapshot(for: node.url) else { continue }
            let spans = SpanNode.decodeList(snapshot.spansJson)
            built.append(NotebookDocument.Section(
                url: node.url,
                title: node.displayName,
                body: RichText.attributed(from: spans, cache: cache)
            ))
            next[node.url] = Section(
                heads: snapshot.heads,
                lastJSON: snapshot.spansJson,
                lastName: node.displayName
            )
        }

        document.rebuild(built)
        sections = next
        loaded = true
    }

    func scheduleSave() {
        guard loaded else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    /// Write each note back against the heads it was loaded at, so a note
    /// edited elsewhere in the meantime conflicts rather than being clobbered.
    func saveNow() async {
        guard loaded else { return }
        saveTask?.cancel()
        saveTask = nil

        let bodies = document.bodies()
        let titles = document.titles()

        for url in document.order {
            if let name = titles[url]?.trimmingCharacters(in: .whitespacesAndNewlines),
               name != sections[url]?.lastName,
               let node = model.node(for: url) {
                sections[url]?.lastName = name
                model.renameNode(node, to: name)
            }
            guard let section = sections[url], let text = bodies[url] else { continue }
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

struct FolderEmptyState: View {
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

/// The folder as one continuous document: every note's content in a single
/// editor, one scroll view and one caret, with the boundary between two notes
/// drawn as a title over a dotted rule rather than the edge of a box. The
/// notes are rendered like any other text — not embedded editors — so nothing
/// here nests a scroll view inside another that scrolls the same way.
struct FolderNotebook: View {
    let children: [FolderNode]

    @Environment(NotesModel.self) private var model
    @State private var core: FolderNotebookCore?

    private var notes: [FolderNode] { children.filter(\.isNote) }

    var body: some View {
        Group {
            if notes.isEmpty {
                FolderEmptyState(message: "No notes in this folder")
            } else if let core, core.loaded {
                FolderNotebookText(core: core)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: notes.map(\.url)) {
            let core = FolderNotebookCore(model: model)
            self.core = core
            await core.load(notes)
        }
    }
}

#if os(macOS)

/// Draws the rule between two notes. It is painted rather than inserted: a
/// character standing in for the seam would be one more thing an edit could
/// land on, and the boundary rules exist to keep that from happening.
final class NotebookTextView: NSTextView {
    weak var document: NotebookDocument?

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let document,
              let layoutManager = textLayoutManager,
              let contentManager = layoutManager.textContentManager
        else { return }

        let inset = textContainerInset
        PColor.separatorColor.setStroke()

        for location in document.separatorLocations() {
            guard let start = contentManager.location(
                contentManager.documentRange.location,
                offsetBy: location
            ), let fragment = layoutManager.textLayoutFragment(for: start) else { continue }

            // Half the spacing above the title, on a half pixel so a one point
            // line lands on a device pixel instead of straddling two.
            let y = (fragment.layoutFragmentFrame.minY + inset.height - 15).rounded() + 0.5
            guard y >= rect.minY - 20, y <= rect.maxY + 20 else { continue }

            let path = NSBezierPath()
            path.move(to: NSPoint(x: inset.width, y: y))
            path.line(to: NSPoint(x: bounds.width - inset.width, y: y))
            path.lineWidth = 1
            path.setLineDash([1.5, 4], count: 2, phase: 0)
            path.stroke()
        }
    }
}

struct FolderNotebookText: NSViewRepresentable {
    let core: FolderNotebookCore

    func makeCoordinator() -> Coordinator {
        Coordinator(core: core)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NotebookTextView(usingTextLayoutManager: true)
        textView.document = core.document
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
        textView.textContentStorage?.textStorage = core.document.storage

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.automaticallyAdjustsContentInsets = true
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NotebookTextView else { return }
        textView.document = core.document
        if textView.textContentStorage?.textStorage !== core.document.storage {
            textView.textContentStorage?.textStorage = core.document.storage
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
            core.document.allowsEdit(
                in: affectedCharRange,
                replacement: replacementString ?? ""
            )
        }

        func textDidChange(_ notification: Notification) {
            core.scheduleSave()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            textView.typingAttributes = core.document.typingAttributes(
                from: textView.typingAttributes,
                at: textView.selectedRange().location
            )
        }
    }
}

#else

/// The UIKit half of the same thing. The rules, the loading and the writing
/// back are shared — only hosting the text differs.
final class NotebookTextView: UITextView {
    weak var document: NotebookDocument?

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard let document,
              let layoutManager = textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let context = UIGraphicsGetCurrentContext()
        else { return }

        context.setStrokeColor(PColor.separator.cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [1.5, 4])

        for location in document.separatorLocations() {
            guard let start = contentManager.location(
                contentManager.documentRange.location,
                offsetBy: location
            ), let fragment = layoutManager.textLayoutFragment(for: start) else { continue }

            let y = (fragment.layoutFragmentFrame.minY + textContainerInset.top - 15)
                .rounded() + 0.5
            guard y >= rect.minY - 20, y <= rect.maxY + 20 else { continue }
            context.move(to: CGPoint(x: textContainerInset.left, y: y))
            context.addLine(to: CGPoint(x: bounds.width - textContainerInset.right, y: y))
        }
        context.strokePath()
    }
}

struct FolderNotebookText: UIViewRepresentable {
    let core: FolderNotebookCore

    func makeCoordinator() -> Coordinator {
        Coordinator(core: core)
    }

    func makeUIView(context: Context) -> NotebookTextView {
        let textView = NotebookTextView(usingTextLayoutManager: true)
        textView.document = core.document
        textView.isEditable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.autocorrectionType = .default
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.typingAttributes = RichText.attributes(block: .paragraph, marks: [:])
        textView.delegate = context.coordinator
        // The seam is drawn into the content, which scrolls with it; without
        // this the strip revealed by a scroll is never asked to redraw.
        textView.contentMode = .redraw
        textView.textContainer.widthTracksTextView = true
        textView.textContentStorage?.textStorage = core.document.storage
        return textView
    }

    func updateUIView(_ textView: NotebookTextView, context: Context) {
        textView.document = core.document
        if textView.textContentStorage?.textStorage !== core.document.storage {
            textView.textContentStorage?.textStorage = core.document.storage
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let core: FolderNotebookCore

        init(core: FolderNotebookCore) {
            self.core = core
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            core.document.allowsEdit(in: range, replacement: text)
        }

        func textViewDidChange(_ textView: UITextView) {
            core.scheduleSave()
            textView.setNeedsDisplay()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            textView.typingAttributes = core.document.typingAttributes(
                from: textView.typingAttributes,
                at: textView.selectedRange.location
            )
        }
    }
}

#endif
