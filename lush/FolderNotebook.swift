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
/// Structure rather than content: the gap between one note and the next, and
/// the subfolder a note was found in when it was found in one. The body save
/// pass walks straight past it.
let notebookBoundary = NSAttributedString.Key("lushNotebookBoundary")

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
        /// The subfolders the note was found under, empty for the folder's
        /// own. Drawn in the gap above it and owned by nobody: it is where the
        /// note is, not what it is called.
        var path: String = ""
        let body: NSAttributedString
    }

    /// The room a boundary opens above the note it introduces, with the rule
    /// drawn across the middle of it.
    static let gap: CGFloat = 30

    let storage = NSTextStorage()
    private(set) var order: [String] = []

    private var pathColor: PColor {
        #if os(macOS)
        .tertiaryLabelColor
        #else
        .tertiaryLabel
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
            built.append(boundary(under: section.path, first: urls.isEmpty))
            built.append(body)
            urls.append(section.url)
        }
        storage.setAttributedString(built)
        order = urls
    }

    /// The seam between one note and the next: a newline closing the note
    /// above, then a line of its own.
    ///
    /// The leading newline belongs to the boundary rather than to the note
    /// above it — it keeps that note's last paragraph closed while staying out
    /// of the note's own slice, where a trailing newline would save an empty
    /// paragraph onto every note.
    ///
    /// The line after it holds the subfolder a note was found in, and for the
    /// folder's own notes nothing at all. Empty it is still the room the rule
    /// is drawn in: a note's name is its first heading, which its content
    /// already carries, so there is nothing else left to put here.
    ///
    /// The first note gets no seam — it has nothing above it to be separated
    /// from — and none at all when it is one of the folder's own.
    private func boundary(under path: String, first: Bool) -> NSAttributedString {
        if first, path.isEmpty { return NSAttributedString() }
        var attributes = RichText.attributes(block: .heading(level: 2), marks: [:])
        attributes[notebookBoundary] = true
        attributes[.foregroundColor] = pathColor
        if !first,
           let base = attributes[.paragraphStyle] as? NSParagraphStyle,
           let spaced = base.mutableCopy() as? NSMutableParagraphStyle {
            spaced.paragraphSpacingBefore = Self.gap
            attributes[.paragraphStyle] = spaced
        }
        let line = NSMutableAttributedString()
        if !first {
            line.append(NSAttributedString(string: "\n", attributes: attributes))
        }
        if !path.isEmpty {
            line.append(NSAttributedString(string: path, attributes: attributes))
        }
        line.append(NSAttributedString(string: "\n", attributes: attributes))
        return line
    }

    // MARK: - Ownership

    func owner(at location: Int) -> String? {
        guard location >= 0, location < storage.length else { return nil }
        return storage.attribute(notebookNote, at: location, effectiveRange: nil) as? String
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

    /// Everything a note owns, boundaries excluded — where to put the caret
    /// when the reader asks for a particular note.
    func range(of url: String) -> NSRange? {
        var found: NSRange?
        storage.enumerateAttribute(
            notebookNote,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard value as? String == url else { return }
            found = found.map { NSUnionRange($0, range) } ?? range
        }
        return found
    }

    /// Where the text view draws a rule between two notes: the head of every
    /// boundary but the first, which has nothing above it to be separated
    /// from. One past the newline that opens it — that newline closes the line
    /// above, and the rule belongs over the line below.
    ///
    /// Anchored to the boundary's own line, which is where the room for it
    /// is: the folder path when there is one, and an empty line when there
    /// isn't.
    func separatorLocations() -> [Int] {
        var locations: [Int] = []
        let string = storage.string as NSString
        storage.enumerateAttribute(
            notebookBoundary,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard value != nil, range.location > 0,
                  string.character(at: range.location) == 0x0A
            else { return }
            locations.append(range.location + 1)
        }
        return locations
    }

    /// Typed text inherits the attributes to its left, which at the head of a
    /// note is the boundary above it. Stamping the caret keeps new text with
    /// the note it is being typed into.
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

    /// An edit stays inside one note, and never spans two of them or touches
    /// the newlines holding a boundary together. That is what makes every
    /// character's owner unambiguous, and what stops a backspace at the top of
    /// a note swallowing the one above.
    func allowsEdit(in range: NSRange) -> Bool {
        guard range.length > 0 else {
            // An insertion point belonging to no note at all: the gap between
            // two of them, or an empty notebook.
            return note(forCaretAt: range.location) != nil
        }
        var owners: Set<String> = []
        for location in range.location..<NSMaxRange(range) {
            guard !isBoundary(at: location), let url = owner(at: location) else { return false }
            owners.insert(url)
            if owners.count > 1 { return false }
        }
        return true
    }

    /// Which note an edit over `range` belongs to. `allowsEdit` has already
    /// refused anything spanning two of them, so there is only ever one
    /// answer — but it has to be asked before the edit lands, while the text
    /// it is replacing is still there to answer with.
    func target(forEditIn range: NSRange) -> String? {
        guard range.length > 0 else { return note(forCaretAt: range.location) }
        for location in range.location..<NSMaxRange(range) {
            if let url = owner(at: location) { return url }
        }
        return nil
    }

    /// Puts a run of text into a note whatever it arrived wearing. Typing
    /// carries the caret's stamp on its own, but pasted, dropped and dictated
    /// text comes with the attributes of wherever it came from: none at all,
    /// or — worse, because it reads as fine — the note it was copied out of.
    /// Either way `bodies()` would file it somewhere other than where the
    /// reader can see it.
    func claim(_ range: NSRange, for url: String) {
        guard range.location >= 0, range.location < storage.length else { return }
        let target = NSRange(
            location: range.location,
            length: min(range.length, storage.length - range.location)
        )
        guard target.length > 0 else { return }
        storage.beginEditing()
        storage.removeAttribute(notebookBoundary, range: target)
        storage.addAttribute(notebookNote, value: url, range: target)
        storage.endEditing()
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
}

/// A note the notebook is going to read, and where under the folder it was
/// found.
struct NotebookEntry: Equatable, Identifiable {
    let node: FolderNode
    /// The subfolders between the notebook's folder and this note, empty for
    /// the folder's own notes.
    let path: String

    /// Where the note is as well as which one it is. Moving a note between
    /// subfolders changes what the notebook draws without changing the set of
    /// urls in it, and an identity of urls alone would miss that.
    var id: String { "\(path)/\(node.url)" }
}

/// Every note under a folder, depth first, in the order the sidebar draws
/// them — subfolders first, then the folder's own notes, which is what
/// `orderedChildren` returns at each level.
///
/// A folder that keeps its notes in subfolders is a folder full of notes.
/// Reading only the direct children made the notebook say such a folder was
/// empty, which is the one thing it certainly wasn't.
@MainActor
func notebookEntries(of folderUrl: String, in model: NotesModel) -> [NotebookEntry] {
    func walk(_ url: String, under prefix: [String]) -> [NotebookEntry] {
        let children = model.orderedChildren(model.node(for: url)?.children ?? [], in: url)
        return children.flatMap { child -> [NotebookEntry] in
            if child.kind == "folder" {
                return walk(child.url, under: prefix + [child.displayName])
            }
            guard child.isNote else { return [] }
            return [NotebookEntry(node: child, path: prefix.joined(separator: " / "))]
        }
    }
    return walk(folderUrl, under: [])
}

/// Whether a folder holds a note anywhere under it. Short-circuits, so a
/// folder with a note near the top costs a step or two rather than a walk of
/// everything beneath it.
@MainActor
func folderHoldsANote(_ folderUrl: String, in model: NotesModel) -> Bool {
    guard let children = model.node(for: folderUrl)?.children else { return false }
    for child in children {
        if child.isNote { return true }
        if child.kind == "folder", folderHoldsANote(child.url, in: model) { return true }
    }
    return false
}

/// A folder read as one document: every note's content in one text view, one
/// scroll view, one caret. The notes are not embedded editors — they are
/// rendered like any other text, and the boundary between two of them is a
/// dotted rule rather than the edge of a box.
@MainActor
@Observable
final class FolderNotebookCore: LiveWriter {
    private struct Section {
        var heads: [String]
        var lastJSON: String
    }

    /// Where an edit is about to land, taken down before it happens. After
    /// the fact the new text is simply there, wearing whatever attributes it
    /// arrived with, and only the document as it stood knows whose it is.
    private struct PendingEdit {
        let url: String
        let location: Int
        let removed: Int
        let lengthBefore: Int
    }

    @ObservationIgnored private(set) var document = NotebookDocument()
    private(set) var loaded = false

    /// Bumped when the caret is waiting to be put somewhere, so the text view
    /// is asked to update and can come and collect it.
    private(set) var focusRevision = 0

    /// The note the caret is in, so a new one can be put after the note being
    /// read rather than at the end of the folder.
    @ObservationIgnored private(set) var focusedNote: String?

    @ObservationIgnored private var focusRequest: String?

    @ObservationIgnored private var sections: [String: Section] = [:]
    /// The notes touched since the last write. A folder can hold a great deal
    /// of text and re-encoding all of it on every keystroke would make one
    /// keypress cost the whole folder.
    @ObservationIgnored private var dirty: Set<String> = []
    @ObservationIgnored private var pending: PendingEdit?
    @ObservationIgnored private let cache = AssetCache()
    @ObservationIgnored private let model: NotesModel
    @ObservationIgnored private let origin = UUID()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var writeTask: Task<Void, Never>?

    init(model: NotesModel) {
        self.model = model
        model.registerLiveWriter(self)
    }

    deinit {
        saveTask?.cancel()
        let identity = ObjectIdentifier(self)
        Task { @MainActor [model] in model.unregisterLiveWriter(identity) }
    }

    /// Reads the folder's notes into the document. Called again whenever the
    /// folder's children change, and deliberately in place: the storage the
    /// text view is attached to is the same object either way, so a note
    /// added somewhere else doesn't tear the notebook down and rebuild it.
    func load(_ entries: [NotebookEntry]) async {
        if loaded { await flushNow() }
        var built: [NotebookDocument.Section] = []
        var next: [String: Section] = [:]

        for entry in entries {
            let node = entry.node
            guard let snapshot = await model.spansSnapshot(for: node.url) else { continue }
            let spans = SpanNode.decodeList(snapshot.spansJson)
            built.append(NotebookDocument.Section(
                url: node.url,
                path: entry.path,
                body: RichText.attributed(from: spans, cache: cache)
            ))
            next[node.url] = Section(heads: snapshot.heads, lastJSON: snapshot.spansJson)
        }

        document.rebuild(built)
        sections = next
        dirty = []
        pending = nil
        loaded = true
        // Only once the note is actually in the document: it is created
        // before the tree walk that will find it has finished, so the first
        // reload after asking is as likely as not to be missing it.
        if let url = focusRequest, document.range(of: url) != nil { focusRevision += 1 }
    }

    /// Reads the folder again into a document of its own. Leaving edit mode
    /// puts up a new text view, and on iOS a fresh one over the storage the
    /// outgoing view is still tearing down leaves the two of them fighting
    /// over the same observer slot.
    func restart(_ entries: [NotebookEntry]) async {
        if loaded { await flushNow() }
        loaded = false
        document = NotebookDocument()
        await load(entries)
    }

    // MARK: - The caret

    func caretMoved(to location: Int) {
        // Only ever an answer: a caret resting in the gap between two notes
        // belongs to neither, and forgetting where it last was would send the
        // next new note to the bottom of the folder.
        if let url = document.note(forCaretAt: location) { focusedNote = url }
    }

    /// Put the caret in a note once the notebook has read it. The note is not
    /// in the document yet — it has only just been created, and the reload
    /// that will bring it in is what this is waiting for.
    func requestFocus(on url: String) {
        focusRequest = url
    }

    func takeFocusTarget() -> NSRange? {
        guard let url = focusRequest, let range = document.range(of: url) else { return nil }
        focusRequest = nil
        focusedNote = url
        return NSRange(location: NSMaxRange(range), length: 0)
    }

    // MARK: - Editing

    /// Ask the document whose text this is while it can still answer.
    func willChange(in range: NSRange) {
        guard loaded else { return }
        pending = document.target(forEditIn: range).map { url in
            PendingEdit(
                url: url,
                location: range.location,
                removed: range.length,
                lengthBefore: document.storage.length
            )
        }
    }

    func didChange() {
        defer { pending = nil }
        guard loaded else { return }
        guard let edit = pending else {
            // Something changed the text without going past `willChange` —
            // an undo, most likely. Nothing says what moved, so everything is
            // suspect.
            dirty.formUnion(document.order)
            scheduleSave()
            return
        }
        let inserted = document.storage.length - edit.lengthBefore + edit.removed
        if inserted > 0 {
            document.claim(NSRange(location: edit.location, length: inserted), for: edit.url)
        }
        dirty.insert(edit.url)
        scheduleSave()
    }

    /// Formatting rewrites attributes without a text change, so nothing
    /// passes the delegate that feeds `willChange` — the format bar reports
    /// what it touched by hand.
    func noteFormatted(_ urls: Set<String>) {
        guard loaded, !urls.isEmpty else { return }
        dirty.formUnion(urls)
        scheduleSave()
    }

    // MARK: - Writing

    func scheduleSave() {
        guard loaded else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.saveTask = nil
            self?.beginWrite()
        }
    }

    /// Give up the debounce and start writing. Returns straight away: the
    /// synchronous termination paths have nowhere to await, and
    /// `flushPendingWrites` comes along behind to wait.
    func pushNow() {
        guard loaded else { return }
        saveTask?.cancel()
        saveTask = nil
        beginWrite()
    }

    func flushNow() async {
        guard loaded else { return }
        saveTask?.cancel()
        saveTask = nil
        await beginWrite().value
    }

    /// One write at a time. Two overlapping passes would both read the heads
    /// the first hasn't written back yet, and the second would land against a
    /// base the note has already moved off — a fork of the note rather than
    /// the next edit to it.
    @discardableResult
    private func beginWrite() -> Task<Void, Never> {
        let previous = writeTask
        let task = Task { [weak self] in
            _ = await previous?.value
            await self?.write()
        }
        writeTask = task
        return task
    }

    /// Write each touched note back against the heads it was loaded at, so a
    /// note edited elsewhere in the meantime merges rather than being
    /// clobbered.
    private func write() async {
        guard loaded, !dirty.isEmpty else { return }
        let touched = dirty
        dirty = []
        var retry = false

        let bodies = document.bodies()

        // Renaming rides along with the write: `updateDocument` takes the
        // note's first line as its name, the same way every other editor in
        // the app does. There is nothing else here to rename it from.
        for url in document.order where touched.contains(url) {
            guard let section = sections[url], let text = bodies[url] else { continue }
            let spans = RichText.spans(from: text)
            let json = SpanNode.encodeList(spans)
            guard json != section.lastJSON else { continue }
            let written = await model.updateDocument(
                url,
                json: json,
                title: RichText.title(from: spans),
                heads: section.heads.isEmpty ? nil : section.heads,
                origin: origin
            )
            guard let written else {
                // The write didn't land, so the note is still dirty — marking
                // it clean here is how an edit disappears for good, since
                // nothing else is writing this note. Drop the base it refused
                // and let the retry go in against the doc as it stands, which
                // is what every other snapshot writer does and the one thing
                // that can't fail the same way twice. Once that has been
                // tried, wait for the next edit rather than spinning.
                if !section.heads.isEmpty { retry = true }
                sections[url]?.heads = []
                dirty.insert(url)
                continue
            }
            sections[url]?.lastJSON = json
            sections[url]?.heads = written
        }
        if retry { scheduleSave() }
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
/// drawn as a dotted rule rather than the edge of a box. The notes are
/// rendered like any other text — not embedded editors — so nothing here
/// nests a scroll view inside another that scrolls the same way.
struct FolderNotebook: View {
    let folderUrl: String

    @Environment(NotesModel.self) private var model
    @Environment(ContextTracker.self) private var contextTracker
    @State private var core: FolderNotebookCore?
    #if os(iOS)
    @Environment(\.editMode) private var editMode
    #endif

    /// The whole subtree, not the direct children: a folder's notes are its
    /// notes wherever it keeps them.
    private var notes: [NotebookEntry] { notebookEntries(of: folderUrl, in: model) }

    private var editing: Bool {
        #if os(iOS)
        editMode?.wrappedValue.isEditing == true
        #else
        false
        #endif
    }

    var body: some View {
        content
        // One core for as long as the folder is on screen, reloaded in
        // place when its notes change. Replacing it would take the debounced
        // save down with it and blink the whole notebook back to a spinner
        // over one note being added somewhere else entirely.
        .task {
            let notebook = core ?? FolderNotebookCore(model: model)
            self.core = notebook
            await notebook.load(notes)
        }
        // Not while the notes are being dragged around: every drop moves a
        // note and re-reading the whole folder between two of them costs a
        // snapshot per note for a document nobody is looking at. Leaving edit
        // mode reads it again anyway.
        .onChange(of: notes.map(\.id)) {
            guard let core, !editing else { return }
            Task { await core.load(notes) }
        }
        .onChange(of: editing) { _, isEditing in
            guard let core else { return }
            // Nothing is typed while the notes are being dragged around, so
            // the edit on the way in is the last one the text view took.
            Task {
                if isEditing {
                    await core.flushNow()
                } else {
                    await core.restart(notes)
                }
            }
        }
        .onDisappear {
            guard let core else { return }
            Task { await core.flushNow() }
        }
        .toolbar { notebookToolbar }
    }

    @ViewBuilder
    private var content: some View {
        if notes.isEmpty {
            FolderEmptyState(message: "No notes in this folder")
        } else if editing {
            arrangeList
        } else if let core, core.loaded {
            #if os(iOS)
            FolderNotebookText(core: core, focusRevision: core.focusRevision, addNote: addNote)
            #else
            FolderNotebookText(core: core, focusRevision: core.focusRevision)
            #endif
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var arrangeList: some View {
        #if os(iOS)
        NotebookArrangeList(entries: notes)
        #endif
    }

    @ToolbarContentBuilder
    private var notebookToolbar: some ToolbarContent {
        #if os(iOS)
        ToolbarItem {
            EditButton()
        }
        // The same corner it lives in on the home screen, beside the search
        // bar there and above the format bar here.
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button(action: addNote) {
                Label("New Note", systemImage: "square.and.pencil")
            }
            .help("New note after this one")
            .disabled(editing)
        }
        #else
        ToolbarItem {
            Button(action: addNote) {
                Label("New Note", systemImage: "square.and.pencil")
            }
            .help("New note after this one")
            .disabled(editing)
        }
        #endif
    }

    /// A note straight after the one being read, in whichever folder that one
    /// lives in — a notebook reads out of its subfolders too, and putting the
    /// new note in the folder at the top would file it somewhere the reader
    /// isn't looking. With no caret anywhere it goes on the end.
    private func addNote() {
        let after = core?.focusedNote
        let parent = after.flatMap { model.node(for: $0)?.parentUrl } ?? folderUrl
        Task {
            contextTracker.start()
            guard let url = await model.createNote(
                inFolder: parent,
                snap: contextTracker.snapshot
            ) else { return }
            if let after { model.placeChild(url, after: after, in: parent) }
            core?.requestFocus(on: url)
        }
    }
}

#if os(iOS)

/// The notebook in edit mode: its notes as rows to be dragged into the order
/// they should be read in. A note's place is kept by the folder holding it and
/// there is no order spanning two folders, so a notebook reading out of
/// subfolders gets a section each.
private struct NotebookArrangeList: View {
    let entries: [NotebookEntry]

    @Environment(NotesModel.self) private var model

    private struct Sheaf: Identifiable {
        let folderUrl: String
        let path: String
        var notes: [FolderNode]
        var id: String { folderUrl }
    }

    /// Grouped in the order the notebook reads them, so the rows are in the
    /// same order as the text they came from.
    private var sheaves: [Sheaf] {
        var sheaves: [Sheaf] = []
        for entry in entries {
            guard let parent = entry.node.parentUrl else { continue }
            if let index = sheaves.firstIndex(where: { $0.folderUrl == parent }) {
                sheaves[index].notes.append(entry.node)
            } else {
                sheaves.append(Sheaf(folderUrl: parent, path: entry.path, notes: [entry.node]))
            }
        }
        return sheaves
    }

    var body: some View {
        List {
            ForEach(sheaves) { sheaf in
                Section {
                    ForEach(sheaf.notes) { node in
                        NoteRowView(node: node)
                    }
                    .onMove { from, to in
                        model.moveNotes(
                            in: sheaf.folderUrl,
                            displayed: sheaf.notes.map(\.url),
                            from: from,
                            to: to
                        )
                    }
                } header: {
                    if !sheaf.path.isEmpty { Text(sheaf.path) }
                }
            }
        }
    }
}

#endif

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

            // Half the gap above the boundary line, on a half pixel so a one
            // point line lands on a device pixel instead of straddling two.
            let y = (fragment.layoutFragmentFrame.minY + inset.height - NotebookDocument.gap / 2)
                .rounded() + 0.5
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
    /// Not read here: it changes when the core has a caret waiting to be
    /// placed, which is what gets `updateNSView` called at all.
    let focusRevision: Int

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
        if let caret = core.takeFocusTarget() {
            textView.setSelectedRange(caret)
            textView.window?.makeFirstResponder(textView)
            textView.scrollRangeToVisible(caret)
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
            guard core.document.allowsEdit(in: affectedCharRange) else { return false }
            core.willChange(in: affectedCharRange)
            return true
        }

        func textDidChange(_ notification: Notification) {
            core.didChange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let location = textView.selectedRange().location
            core.caretMoved(to: location)
            textView.typingAttributes = core.document.typingAttributes(
                from: textView.typingAttributes,
                at: location
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

            let y = (
                fragment.layoutFragmentFrame.minY + textContainerInset.top - NotebookDocument.gap / 2
            ).rounded() + 0.5
            guard y >= rect.minY - 20, y <= rect.maxY + 20 else { continue }
            context.move(to: CGPoint(x: textContainerInset.left, y: y))
            context.addLine(to: CGPoint(x: bounds.width - textContainerInset.right, y: y))
        }
        context.strokePath()
    }
}

/// The slice of the editor's formatting the notebook can run on its own
/// storage: block styles and inline marks, applied with the same
/// `RichText.marks`/`RichText.attributes` round-trip the editor uses.
/// Ownership rides on the characters, so every rewritten run keeps its note
/// stamp, and boundary runs are never touched.
@MainActor
@Observable
final class NotebookFormatController {
    @ObservationIgnored weak var textView: NotebookTextView?
    @ObservationIgnored weak var core: FolderNotebookCore?

    var currentStyleKey = "paragraph"
    var strongActive = false
    var emActive = false
    var underlineActive = false
    var strikethroughActive = false
    var codeActive = false
    var highlightActive: String?

    func refreshState() {
        guard let textView, let core else { return }
        let selection = textView.selectedRange
        let storage = core.document.storage
        // With a caret, the buttons must show what the next typed character
        // will be — that's the typing attributes, not the character behind it.
        let attrs: [NSAttributedString.Key: Any]
        if selection.length > 0, selection.location < storage.length {
            attrs = storage.attributes(at: selection.location, effectiveRange: nil)
        } else {
            attrs = textView.typingAttributes
        }
        let block = (attrs[.amBlock] as? BlockBox)?.value ?? .paragraph
        currentStyleKey = block.styleKey
        let marks = RichText.marks(from: attrs, block: block)
        strongActive = marks["strong"] != nil
        emActive = marks["em"] != nil
        underlineActive = marks["underline"] != nil
        strikethroughActive = marks["strikethrough"] != nil
        codeActive = marks["code"] != nil
        if case .string(let name)? = marks["highlight"] {
            highlightActive = name
        } else {
            highlightActive = nil
        }
    }

    func applyStyle(_ key: String) {
        guard let textView, let core else { return }
        let block = BlockValue.fromStyleKey(key)
        let document = core.document
        let storage = document.storage
        let selection = textView.selectedRange
        guard storage.length > 0 else { return }
        let paragraphs = (storage.string as NSString).paragraphRange(for: selection)
        var touched: Set<String> = []
        storage.beginEditing()
        storage.enumerateAttributes(in: paragraphs) { runAttrs, runRange, _ in
            guard runAttrs[notebookBoundary] == nil,
                  let owner = runAttrs[notebookNote] as? String else { return }
            let oldBlock = (runAttrs[.amBlock] as? BlockBox)?.value ?? .paragraph
            guard !oldBlock.isAtomic, runAttrs[.amTableBox] == nil,
                  runAttrs[.amColumnsBox] == nil,
                  runAttrs[.attachment] == nil,
                  runAttrs[.amDisplayOnly] == nil else { return }
            let marks = RichText.marks(from: runAttrs, block: oldBlock)
            var attrs = RichText.attributes(block: block, marks: marks)
            attrs[notebookNote] = owner
            storage.setAttributes(attrs, range: runRange)
            touched.insert(owner)
        }
        storage.endEditing()
        textView.selectedRange = selection
        textView.typingAttributes = document.typingAttributes(
            from: RichText.attributes(block: block, marks: [:]),
            at: selection.location
        )
        textView.setNeedsDisplay()
        core.noteFormatted(touched)
        refreshState()
    }

    func toggleMark(_ mark: String) {
        let active = switch mark {
        case "strong": strongActive
        case "em": emActive
        case "underline": underlineActive
        case "strikethrough": strikethroughActive
        case "code": codeActive
        default: false
        }
        setMark(mark, value: active ? nil : .bool(true))
    }

    func setHighlight(_ name: String?) {
        setMark("highlight", value: name.map { .string($0) })
    }

    func dismissKeyboard() {
        textView?.resignFirstResponder()
    }

    private func setMark(_ mark: String, value: JSONValue?) {
        guard let textView, let core else { return }
        let document = core.document
        let storage = document.storage
        let selection = textView.selectedRange
        if selection.length == 0 {
            let typing = textView.typingAttributes
            let block = (typing[.amBlock] as? BlockBox)?.value ?? .paragraph
            var marks = RichText.marks(from: typing, block: block)
            marks[mark] = value
            textView.typingAttributes = document.typingAttributes(
                from: RichText.attributes(block: block, marks: marks),
                at: selection.location
            )
            refreshState()
            return
        }
        var touched: Set<String> = []
        storage.beginEditing()
        storage.enumerateAttributes(in: selection) { runAttrs, runRange, _ in
            guard runAttrs[notebookBoundary] == nil,
                  let owner = runAttrs[notebookNote] as? String else { return }
            let block = (runAttrs[.amBlock] as? BlockBox)?.value ?? .paragraph
            guard !block.isAtomic, runAttrs[.amTableBox] == nil,
                  runAttrs[.amColumnsBox] == nil else { return }
            var marks = RichText.marks(from: runAttrs, block: block)
            marks[mark] = value
            var attrs = RichText.attributes(block: block, marks: marks)
            if mark != "link", let link = runAttrs[.link], marks["link"] == nil {
                attrs[.link] = link
            }
            attrs[notebookNote] = owner
            storage.setAttributes(attrs, range: runRange)
            touched.insert(owner)
        }
        storage.endEditing()
        textView.selectedRange = selection
        core.noteFormatted(touched)
        refreshState()
    }
}

/// The regular format bar's notebook edition: the same capsule over the
/// keyboard, with the pieces that make sense on concatenated notes — styles,
/// marks and highlights, but no attachments, which need a full editor
/// session behind them.
struct NotebookFormatBar: View {
    let formatter: NotebookFormatController
    let addNote: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            formatCapsule
            // The same corner the compose button keeps everywhere else,
            // riding the keyboard beside the bar while the bottom bar it
            // usually lives in is covered.
            Button(action: addNote) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 44, height: 44)
            }
            .glassEffect(.regular, in: Circle())
            .accessibilityLabel("New Note")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var formatCapsule: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 22) {
                    Menu {
                        ForEach(EditorController.styles, id: \.key) { style in
                            Button {
                                formatter.applyStyle(style.key)
                            } label: {
                                if formatter.currentStyleKey == style.key {
                                    Label(style.label, systemImage: "checkmark")
                                } else {
                                    Text(style.label)
                                }
                            }
                        }
                    } label: {
                        Text("Aa")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.primary)
                    }
                    .accessibilityLabel("Format")
                    markButton("Bold", active: formatter.strongActive) {
                        formatter.toggleMark("strong")
                    } label: {
                        Text("B").font(.system(size: 17, weight: .bold))
                    }
                    markButton("Italic", active: formatter.emActive) {
                        formatter.toggleMark("em")
                    } label: {
                        Text("I").font(.system(size: 17).italic())
                    }
                    markButton("Underline", active: formatter.underlineActive) {
                        formatter.toggleMark("underline")
                    } label: {
                        Text("U").underline().font(.system(size: 17))
                    }
                    markButton("Strikethrough", active: formatter.strikethroughActive) {
                        formatter.toggleMark("strikethrough")
                    } label: {
                        Text("S").strikethrough().font(.system(size: 17))
                    }
                    markButton("Inline Code", active: formatter.codeActive) {
                        formatter.toggleMark("code")
                    } label: {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 15))
                    }
                    Menu {
                        ForEach(Highlight.names, id: \.self) { name in
                            Button {
                                formatter.setHighlight(name)
                            } label: {
                                if formatter.highlightActive == name {
                                    Label(name.capitalized, systemImage: "checkmark")
                                } else {
                                    Text(name.capitalized)
                                }
                            }
                        }
                        Divider()
                        Button("None") { formatter.setHighlight(nil) }
                    } label: {
                        Image(systemName: "highlighter")
                            .foregroundStyle(
                                formatter.highlightActive != nil ? Color.accentColor : Color.primary
                            )
                    }
                    .accessibilityLabel("Highlight")
                    .accessibilityValue(formatter.highlightActive?.capitalized ?? "None")
                    Button {
                        formatter.applyStyle("unordered-list-item")
                    } label: {
                        Image(systemName: "list.bullet").foregroundStyle(Color.primary)
                    }
                    .accessibilityLabel("Bulleted List")
                }
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity)
            }
            Divider()
                .frame(height: 28)
            Button {
                formatter.dismissKeyboard()
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
            }
            .padding(.horizontal, 16)
            .accessibilityLabel("Dismiss Keyboard")
        }
        .font(.system(size: 20))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(Capsule())
        .glassEffect(.regular, in: Capsule())
    }

    private func markButton(
        _ name: String,
        active: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> some View
    ) -> some View {
        Button(action: action) {
            label().foregroundStyle(active ? Color.accentColor : Color.primary)
        }
        .accessibilityLabel(name)
        .accessibilityValue(active ? "On" : "Off")
    }
}

struct FolderNotebookText: UIViewRepresentable {
    let core: FolderNotebookCore
    /// Not read here: it changes when the core has a caret waiting to be
    /// placed, which is what gets `updateUIView` called at all.
    let focusRevision: Int
    let addNote: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(core: core)
    }

    func makeUIView(context: Context) -> NotebookTextView {
        // UITextView caches its `textStorage` in an ivar at init (see the
        // layoutStorage note in RichTextEditor), so the document's storage has
        // to be in the TextKit stack before the view is created. Repointing
        // `contentStorage.textStorage` afterwards leaves UIKit reading
        // character indices from the laid-out storage but attributes from its
        // stale empty one — an NSRangeException the moment DataDetectors asks
        // about a link, or on the first tap in the text.
        let contentStorage = NSTextContentStorage()
        contentStorage.textStorage = core.document.storage
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.textContainer = container
        let textView = NotebookTextView(frame: .zero, textContainer: container)
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

        context.coordinator.formatter.textView = textView
        context.coordinator.formatter.core = core
        context.coordinator.addNote = addNote
        // Through the coordinator rather than captured directly: the view
        // value the closure came from goes stale, the coordinator's copy is
        // refreshed on every update.
        let coordinator = context.coordinator
        let accessory = UIHostingController(
            rootView: NotebookFormatBar(
                formatter: coordinator.formatter,
                addNote: { coordinator.addNote() }
            )
        )
        accessory.view.frame = CGRect(x: 0, y: 0, width: 0, height: 52)
        accessory.view.backgroundColor = .clear
        textView.inputAccessoryView = accessory.view
        context.coordinator.accessory = accessory
        return textView
    }

    func updateUIView(_ textView: NotebookTextView, context: Context) {
        textView.document = core.document
        context.coordinator.formatter.core = core
        context.coordinator.addNote = addNote
        if let caret = core.takeFocusTarget() {
            textView.selectedRange = caret
            textView.becomeFirstResponder()
            textView.scrollRangeToVisible(caret)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        let core: FolderNotebookCore
        let formatter = NotebookFormatController()
        var accessory: UIHostingController<NotebookFormatBar>?
        var addNote: () -> Void = {}

        init(core: FolderNotebookCore) {
            self.core = core
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            guard core.document.allowsEdit(in: range) else { return false }
            core.willChange(in: range)
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            core.didChange()
            textView.setNeedsDisplay()
            formatter.refreshState()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let location = textView.selectedRange.location
            core.caretMoved(to: location)
            textView.typingAttributes = core.document.typingAttributes(
                from: textView.typingAttributes,
                at: location
            )
            formatter.refreshState()
        }
    }
}

#endif
