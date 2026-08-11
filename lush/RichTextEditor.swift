import SwiftUI
import Observation
import UniformTypeIdentifiers
import AVFoundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct HtmlBlockHandle: Identifiable {
    let id = UUID()
    let box: BlockBox
    let html: String
}

enum EditorSheet: Identifiable {
    case audio(assetUrl: String, fileURL: URL, name: String)
    case video(fileURL: URL, name: String)
    case html(HtmlBlockHandle)
    case info(assetUrl: String, name: String, image: PImage?, block: BlockBox)
    case patchworkCreate
    case link(initial: String)

    var id: String {
        switch self {
        case .audio(let url, _, _): "audio-\(url)"
        case .video(let url, _): "video-\(url.path)"
        case .html(let handle): "html-\(handle.id)"
        case .info(let url, _, _, _): "info-\(url)"
        case .patchworkCreate: "patchwork-create"
        case .link: "link"
        }
    }
}

struct OutlineItem: Identifiable {
    let location: Int
    let level: Int
    let text: String
    var id: Int { location }
}

enum MinimapKind {
    case heading, code, quote, embed, text
}

struct MinimapRow: Identifiable {
    let id: Int
    let y: CGFloat
    let height: CGFloat
    let kind: MinimapKind
}

struct MinimapViewport: Equatable {
    var y: CGFloat
    var height: CGFloat
}

@MainActor @Observable
final class EditorController {
    static let styles: [(key: String, label: String)] = [
        ("paragraph", "Body"),
        ("heading1", "Title"),
        ("heading2", "Heading"),
        ("heading3", "Subheading"),
        ("unordered-list-item", "Bulleted List"),
        ("ordered-list-item", "Numbered List"),
        ("todo-list-item", "To-do List"),
        ("blockquote", "Quote"),
        ("code-block", "Code"),
    ]

    var currentStyleKey: String = "paragraph"
    var currentCodeLanguage: String = CodeLanguage.plain.id
    var isCodeBlockActive: Bool { currentStyleKey == "code-block" }
    var strongActive = false
    var emActive = false
    var codeActive = false
    var underlineActive = false
    var strikethroughActive = false
    var superscriptActive = false
    var subscriptActive = false
    var highlightActive: String?
    var fontRoleActive: String?
    var linkActive: String?
    var checkedItemsHidden = false
    var recorderVisible = false
    var liveTranscriptionActive = false
    var sheet: EditorSheet?
    var findVisible = false
    var findQuery = ""
    var replaceVisible = false
    var replaceQuery = ""
    var findMatchCount = 0
    var findIndex = 0
    /// Bumped on every storage edit so inspector views recompute.
    var docVersion = 0
    /// Bumped when a paragraph is parked, to bring the scratchpad forward.
    var padded = 0
    /// Which pad the last parked paragraph went to.
    var paddedPocket = false
    var minimapRows: [MinimapRow] = []
    var minimapDocHeight: CGFloat = 0
    var minimapViewport: MinimapViewport?

    func minimapJump(fraction: CGFloat) { core?.scrollToFraction(fraction) }
    #if os(iOS)
    var formatVisible = false {
        didSet {
            (core?.view as? EditorTextView)?.suppressesKeyboard = formatVisible
        }
    }
    var photoPickerVisible = false
    var filePickerVisible = false
    var cameraPickerVisible = false
    #endif
    @ObservationIgnored weak var core: EditorCore?

    func openFind() {
        findVisible = true
        core?.updateFindMatches()
    }

    func openReplace() {
        findVisible = true
        replaceVisible = true
        core?.updateFindMatches()
    }

    func closeFind() {
        findVisible = false
        replaceVisible = false
        findQuery = ""
        replaceQuery = ""
        core?.updateFindMatches()
    }

    var undoManager: UndoManager? { core?.view?.pUndoManager }

    func undo() { undoManager?.undo() }
    func redo() { undoManager?.redo() }

    func findQueryChanged() { core?.updateFindMatches() }
    func findNext() { core?.stepFind(1) }
    func findPrevious() { core?.stepFind(-1) }
    func replaceCurrent() { core?.replaceCurrentFind(with: replaceQuery) }
    func replaceAll() { core?.replaceAllFind(with: replaceQuery) }
    func scrollTo(location: Int) { core?.scrollTo(location: location) }

    /// Formatting reaches whichever text has focus — the note, or a card on the
    /// scratchpad.
    private func format(_ body: @escaping (EditorCore) -> Void) {
        core?.onFocusedText(body)
    }

    func applyStyle(_ key: String) {
        format { $0.applyBlockStyle(BlockValue.fromStyleKey(key)) }
    }

    func applyCodeLanguage(_ language: CodeLanguage) {
        format { $0.setCodeLanguage(language.id) }
    }

    func toggleStrong() { format { $0.toggleMark("strong") } }
    func toggleEm() { format { $0.toggleMark("em") } }
    func toggleCode() { format { $0.toggleMark("code") } }
    func toggleUnderline() { format { $0.toggleMark("underline") } }
    func toggleStrikethrough() { format { $0.toggleMark("strikethrough") } }
    // The two are exclusive: a run of text sits on one baseline.
    func toggleSuperscript() { format { $0.toggleBaseline("superscript") } }
    func toggleSubscript() { format { $0.toggleBaseline("subscript") } }
    func applyHighlight(_ name: String?) { format { $0.setHighlight(name) } }
    func applyLink(_ url: String?) { format { $0.setLink(url) } }
    func editLink() {
        #if os(iOS)
        formatVisible = false
        #endif
        sheet = .link(initial: linkActive ?? "")
    }
    func applyFontRole(_ role: String?) { format { $0.setFontRole(role) } }
    func moveItemUp() { format { $0.moveListItem(by: -1) } }
    func moveItemDown() { format { $0.moveListItem(by: 1) } }
    func moveCheckedToBottom() { core?.moveCheckedToBottom() }
    func toggleHideChecked() { core?.toggleHideCheckedItems() }
    func deleteChecked() { core?.deleteCheckedItems() }
    func indent() { format { _ = $0.nestListItem() } }
    func outdent() { format { _ = $0.unnestListItem() } }
    func indentBlock() { format { $0.indentBlock() } }
    func outdentBlock() { format { $0.outdentBlock() } }
    func insertTable() { core?.insertTable() }
    func insertColumns() { core?.insertColumns() }
    func insertHtmlBlock() { core?.insertHtmlBlock() }
    func insertLogline() { core?.insertLogline() }
    func insertPatchworkDoc() { sheet = .patchworkCreate }
    func startLiveTranscription() { core?.startLiveTranscription() }
    func stopLiveTranscription() { core?.stopLiveTranscription() }

    #if os(iOS)
    func dismissKeyboard() { core?.endEditing() }
    func resumeKeyboard() { core?.view?.pSelf.becomeFirstResponder() }
    func showFormatPanel() {
        guard let view = core?.view else { return }
        let selection = view.pSelectedRange
        formatVisible = true
        view.pSelectedRange = selection
    }
    #endif

    func insertPatchworkEmbed(url: String, tool: String?) {
        core?.insertPatchworkEmbed(url: url, tool: tool)
    }

    func attachImageFromPanel() {
        #if os(macOS)
        core?.attachFromPanel(imagesOnly: true)
        #else
        photoPickerVisible = true
        #endif
    }

    func attachFileFromPanel() {
        #if os(macOS)
        core?.attachFromPanel(imagesOnly: false)
        #else
        filePickerVisible = true
        #endif
    }

    func insertData(_ data: Data, name: String) {
        let ext = (name as NSString).pathExtension.lowercased()
        _ = core?.incomingData(
            data,
            fileExtension: ext.isEmpty ? "bin" : ext,
            suggestedName: name
        )
    }

    func insertRecording(data: Data, name: String) {
        core?.insertAsset(data: data, name: name, fileExtension: "m4a", mime: "audio/mp4")
    }

    func saveHtml(_ handle: HtmlBlockHandle, html: String) {
        core?.updateHtmlBlock(handle.box, html: html)
    }

    func saveImageAltText(_ box: BlockBox, altText: String) {
        core?.updateEmbedAltText(box, altText: altText)
    }

    func replaceTrimmedAudio(assetUrl: String, data: Data, name: String) {
        core?.replaceAsset(
            oldUrl: assetUrl,
            data: data,
            name: name,
            fileExtension: "m4a",
            mime: "audio/mp4"
        )
    }

    func assetVision(_ url: String) async -> AssetVision? {
        guard let core else { return nil }
        return await core.model.assetVision(url)
    }

    func analyzeAssetVision(_ url: String) async -> AssetVision? {
        guard let core else { return nil }
        return await core.model.analyzeAssetVision(url)
    }

    func assetML(_ url: String) async -> AssetMl? {
        guard let core else { return nil }
        return await core.model.assetML(url)
    }

    func updateAssetML(assetUrl: String, summary: String, caption: String, keywords: String) {
        Task { [weak self] in
            await self?.core?.model.updateAssetML(
                assetUrl,
                summary: summary,
                caption: caption,
                keywords: keywords
            )
        }
    }

    func generateAssetML(assetUrl: String, name: String? = nil, choice: ModelChoice? = nil) async -> AssetMl? {
        guard let core else { return nil }
        return await core.model.generateAssetML(assetUrl, name: name, choice: choice)
    }

    func saveTranscript(assetUrl: String, transcript: String) {
        core?.cache.transcripts[assetUrl] = transcript
        Task { [weak self] in
            guard let self else { return }
            let vision = await self.assetVision(assetUrl)
            await self.core?.model.updateAssetVision(assetUrl, description: vision?.description ?? "", ocr: transcript)
            _ = await self.generateAssetML(assetUrl: assetUrl)
        }
    }
}

@MainActor
protocol EditorTextViewLike: AnyObject {
    var pStorage: NSTextStorage? { get }
    var pSelectedRange: NSRange { get set }
    var pSelectedRanges: [NSRange] { get set }
    var pTypingAttributes: [NSAttributedString.Key: Any] { get set }
    var pTextLayoutManager: NSTextLayoutManager? { get }
    var pContentStorage: NSTextContentStorage? { get }
    var pTextContainer: NSTextContainer? { get }
    var pSelf: PView { get }
    var pTextOrigin: CGPoint { get }
    var pUndoManager: UndoManager? { get }
    func pInsertText(_ text: String)
    func pReplace(_ range: NSRange, with attributed: NSAttributedString)
    func pPerformStorageEdit(_ edit: (NSTextStorage) -> Void)
    func pCharacterIndex(atTextContainerPoint point: CGPoint) -> Int?
    func pScrollRangeToVisible(_ range: NSRange)
    func pApplyMaxWidth()
    var pVisibleRect: CGRect { get }
    func pScrollToY(_ y: CGFloat)
}

extension ListMarkerLayoutDelegate {
    /// The trailing empty line's marker comes from whatever the caret at the
    /// end of the document promises to type next.
    @MainActor
    func driveTypingAttributes(from view: any EditorTextViewLike) {
        typingAttributesProvider = { [weak view] in
            guard let view,
                  view.pSelectedRange.location >= (view.pStorage?.length ?? 0)
            else { return nil }
            return view.pTypingAttributes
        }
    }

    @MainActor
    func driveSelection(from view: any EditorTextViewLike) {
        selectionProvider = { [weak view] in
            guard let view, view.pSelectedRange.length > 0 else { return nil }
            return (view.pSelectedRange, view.pSelectionColor)
        }
    }
}

/// A pad card edits the spans a scratchpad holds and writes them back to it.
@MainActor
protocol PadCardEditing: EditorTextViewLike {
    func commit()
    /// Writing to the pad doc on every keystroke would be a change per
    /// character, so a card gathers them first.
    func scheduleCommit()
}

extension EditorTextViewLike {
    var pSelectionColor: PColor {
        #if os(macOS)
        guard let textView = pSelf as? NSTextView else { return .selectedTextBackgroundColor }
        let focused = textView.window?.isKeyWindow == true
            && textView.window?.firstResponder === textView
        guard focused else { return .unemphasizedSelectedTextBackgroundColor }
        return textView.selectedTextAttributes[.backgroundColor] as? PColor
            ?? .selectedTextBackgroundColor
        #else
        return pSelf.tintColor.withAlphaComponent(0.25)
        #endif
    }
}

@MainActor
private final class EditorDocumentSession {
    let noteUrl: String
    let storage = NSTextStorage()
    var heads: [String] = []
    var lastKnownJSON = ""
    var lastKnownEmbeds = 0
    var title = ""
    var isApplyingDocumentState = false
    var loaded = false
    var loadTask: Task<NoteSpansSnapshot?, Never>?

    init(noteUrl: String) {
        self.noteUrl = noteUrl
    }
}

@MainActor
private enum EditorDocumentSessions {
    private static let capacity = 12
    private static var sessions: [String: EditorDocumentSession] = [:]
    private static var recency: [String] = []

    static func session(for noteUrl: String) -> EditorDocumentSession {
        recency.removeAll { $0 == noteUrl }
        recency.append(noteUrl)
        if let session = sessions[noteUrl] {
            return session
        }
        let session = EditorDocumentSession(noteUrl: noteUrl)
        sessions[noteUrl] = session
        while sessions.count > capacity,
              let oldest = recency.first(where: { $0 != noteUrl && sessions[$0] != nil }) {
            sessions.removeValue(forKey: oldest)
            recency.removeAll { $0 == oldest }
        }
        return session
    }
}

private func embedCount(in spans: [SpanNode]) -> Int {
    spans.filter { if case .block(let b) = $0 { return b.isEmbedBlock && b.embedUrl != nil }; return false }.count
}

@MainActor
final class EditorCore {
    private static let softLineBreak = "\u{2028}"
    /// The core that most recently attached for each note. Presence has one
    /// shared session, so a departing core must not leave it out from under a
    /// successor that already claimed the same note.
    private static var presenceOwners: [String: ObjectIdentifier] = [:]

    /// The text an editing command acts on. Normally the note's own view; a
    /// focused pad card takes it over for the length of a command so every
    /// command works the same on a pad as in the note (see onFocusedText).
    weak var view: (any EditorTextViewLike)? {
        didSet {
            if !(view is any PadCardEditing) { noteView = view }
        }
    }
    /// Always the note's own view. Loading, saving and storage attachment read
    /// or write the whole document and must never see a card's copy of it.
    weak var noteView: (any EditorTextViewLike)?
    weak var focusedPadCard: (any PadCardEditing)?
    private var lastCodeSelection = NSRange(location: 0, length: 0)
    let model: NotesModel
    let controller: EditorController
    var noteUrl: String
    private var session: EditorDocumentSession
    var isLoaded: Bool { session.loaded }

    private var saveTask: Task<Void, Never>?
    private var localWriteHeadsTask: Task<[String]?, Never>?
    private var localWritesInFlight = 0
    private var pendingRemoteReload = false
    private var isApplyingDocumentState = false
    private var remoteReloadTask: Task<Void, Never>?
    private var remoteReloadGeneration = 0
    private var placingAttachmentViews = false
    private var pendingTextSplice: PendingTextSplice?
    private var queuedTextSplice: QueuedTextSplice?
    private var textSpliceFlushTask: Task<Void, Never>?
    private var liveTranscriber: LiveTranscriber?
    private var liveTranscriptionID: String?
    private var liveTranscriptionAttributes: [NSAttributedString.Key: Any] = [:]
    private var liveTranscriptionUndo: UndoSnapshot?
    let cache = AssetCache()

    let inline = InlineViewManager()
    let rendering = EditorRenderingAttributes()
    let folding = FoldingContentDelegate()
    private var settingsObserver: (any NSObjectProtocol)?
    private var noteObserverId: UUID?
    private var peersObserverId: UUID?

    init(noteUrl: String, model: NotesModel, controller: EditorController) {
        self.noteUrl = noteUrl
        self.session = EditorDocumentSessions.session(for: noteUrl)
        self.model = model
        self.controller = controller
        controller.core = self
        inline.core = self
        noteObserverId = model.addNoteObserver { [weak self] url in
            self?.remoteChanged(url)
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: EditorSettings.changed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.view?.pApplyMaxWidth()
                guard let self else { return }
                if self.session.loaded {
                    self.apply(spans: SpanNode.decodeList(self.session.lastKnownJSON))
                } else {
                    self.load()
                }
            }
        }
    }

    deinit {
        remoteReloadTask?.cancel()
        textSpliceFlushTask?.cancel()
        saveTask?.cancel()
        caretBroadcastTask?.cancel()
        let identity = ObjectIdentifier(self)
        Task { @MainActor [model, noteObserverId, peersObserverId, noteUrl] in
            if let noteObserverId {
                model.removeNoteObserver(noteObserverId)
            }
            if let peersObserverId {
                model.presence.removePeersObserver(peersObserverId)
            }
            // a successor core for this note may have already claimed the
            // shared presence session; only the still-current owner leaves
            guard EditorCore.presenceOwners[noteUrl] == identity else { return }
            EditorCore.presenceOwners[noteUrl] = nil
            if model.presence.docUrl == noteUrl {
                model.presence.leave()
            }
        }
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        if let storageEditObserver {
            NotificationCenter.default.removeObserver(storageEditObserver)
        }
    }

    // MARK: loading

    func switchTo(_ url: String) {
        cancelLiveTranscription()
        pushNow()
        remoteReloadTask?.cancel()
        textSpliceFlushTask?.cancel()
        caretBroadcastTask?.cancel()
        pendingRemoteReload = false
        pendingTextSplice = nil
        queuedTextSplice = nil
        textSpliceFlushTask = nil
        // undo entries hold snapshots and ranges of the OLD note; replaying
        // them against the next note corrupts it
        view?.pUndoManager?.removeAllActions()
        noteUrl = url
        localWriteHeadsTask = nil
        session = EditorDocumentSessions.session(for: url)
        // fold state is per-note; recompute hidden ranges for the incoming
        // storage BEFORE the swap rebuilds its elements
        folding.foldedHeadings.removeAll()
        folding.hideCheckedTodos = false
        controller.checkedItemsHidden = false
        folding.refresh(storage: layoutStorage)
        inline.resetHosts()
        attachViewToSharedStorage()
        autoLoglineCheckedNoteUrl = nil
        load()
    }

    /// The storage TextKit actually lays out for this view.
    ///
    /// macOS shares one NSTextStorage per note across windows (see the
    /// reclaim dance below). iOS cannot: UITextView caches its `textStorage`
    /// in an ivar at init, so pointing the content storage at a different
    /// storage leaves UIKit's hit-testing reading character indices from the
    /// laid-out storage but attributes from its own stale (empty) one, which
    /// throws NSRangeException on the first tap anywhere in the text. There
    /// the view's own storage is the live one; sessions still cache
    /// `lastKnownJSON`, so switching notes stays a local refill.
    private var layoutStorage: NSTextStorage {
        #if os(macOS)
        session.storage
        #else
        view?.pStorage ?? session.storage
        #endif
    }

    func attachViewToSharedStorage() {
        guard let contentStorage = noteView?.pContentStorage else { return }
        EditorCore.presenceOwners[noteUrl] = ObjectIdentifier(self)
        #if !os(macOS)
        observeStorageEdits()
        registerPresenceObserver()
        #else
        if contentStorage.textStorage !== session.storage {
            contentStorage.textStorage = session.storage
        } else if session.storage.textStorageObserver !== contentStorage {
            // Two windows on one note share this NSTextStorage, and TextKit 2
            // gives a storage exactly one observer slot — whichever content
            // storage attached last owns it, and the other window's element
            // tree goes stale. Pragmatic resolution: the window gaining focus
            // reclaims the slot (the detach/reattach below rebuilds its
            // elements) and windowBecameKey re-syncs its content from the
            // session. Known limitation: the unfocused window is stale until
            // it regains focus, so live simultaneous editing of one note in
            // two windows is unsupported.
            contentStorage.textStorage = NSTextStorage()
            contentStorage.textStorage = session.storage
        }
        observeStorageEdits()
        registerPresenceObserver()
        #endif
    }

    private func registerPresenceObserver() {
        if let peersObserverId {
            model.presence.removePeersObserver(peersObserverId)
        }
        peersObserverId = model.presence.addPeersObserver { [weak self] in
            self?.scheduleRemoteCaretUpdate()
        }
    }

    func windowBecameKey() {
        #if os(macOS)
        if let contentStorage = noteView?.pContentStorage {
            let wasStale = contentStorage.textStorage === session.storage
                && session.storage.textStorageObserver !== contentStorage
            attachViewToSharedStorage()
            if wasStale {
                apply(spans: SpanNode.decodeList(session.lastKnownJSON))
            }
        }
        #endif
        if model.presence.docUrl != noteUrl {
            model.presence.join(noteUrl)
        }
    }

    func detachViewFromSharedStorage() {
        cancelLiveTranscription()
        if let storageEditObserver {
            NotificationCenter.default.removeObserver(storageEditObserver)
            self.storageEditObserver = nil
        }
        if let peersObserverId {
            model.presence.removePeersObserver(peersObserverId)
            self.peersObserverId = nil
        }
        if model.presence.docUrl == noteUrl {
            model.presence.leave()
        }
        #if os(macOS)
        guard let contentStorage = noteView?.pContentStorage,
              contentStorage.textStorage === session.storage
        else { return }
        contentStorage.textStorage = NSTextStorage()
        #endif
    }

    /// The TextKit 1 pump was `didCompleteLayoutFor`; in TextKit 2 the
    /// storage's edit notification drives overlay reconciliation and ordinal
    /// renumbering, and the views trigger reconciles from `layout()`.
    private var storageEditObserver: (any NSObjectProtocol)?

    private func observeStorageEdits() {
        if let storageEditObserver {
            NotificationCenter.default.removeObserver(storageEditObserver)
        }
        storageEditObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: layoutStorage,
            queue: nil
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let storage = note.object as? NSTextStorage else { return }
                // setAttributedString (from apply()) already invalidates the
                // full layout; stale NSTextLocation objects from pre-replace
                // element state would crash background layout if we called
                // invalidateLayout here.
                guard !self.isApplyingDocumentState else { return }
                let editedLocation = storage.editedRange.location
                guard let textLayoutManager = self.view?.pTextLayoutManager else { return }
                Task { @MainActor in
                    invalidateOrderedListRun(
                        around: editedLocation,
                        textLayoutManager: textLayoutManager,
                        storage: storage
                    )
                    invalidateCodeRun(
                        around: editedLocation,
                        textLayoutManager: textLayoutManager,
                        storage: storage
                    )
                    if self.controller.findVisible {
                        self.updateFindMatches(resetIndex: false)
                    }
                    if !self.rendering.globalMatches.isEmpty {
                        self.updateGlobalMatches()
                    }
                    self.controller.docVersion &+= 1
                    self.scheduleMinimapUpdate()
                    // Only typing inside a folded heading can change the
                    // hidden set from here (its key stops matching, so the
                    // section reappears); remote reloads refresh in apply().
                    // With nothing folded and nothing hidden there is nothing
                    // to recompute, so the common keystroke skips the
                    // whole-document walk.
                    if !self.folding.foldedHeadings.isEmpty || !self.folding.hiddenRanges.isEmpty {
                        let hiddenBefore = self.folding.hiddenRanges
                        self.folding.refresh(storage: storage)
                        if hiddenBefore != self.folding.hiddenRanges {
                            self.rebuildHiddenRanges(previous: hiddenBefore)
                        }
                    }
                    self.placePendingAttachmentViews()
                }
            }
        }
    }

    private weak var contextTracker: ContextTracker?
    private var autoLoglineCheckedNoteUrl: String?

    func startContext(_ tracker: ContextTracker) {
        contextTracker = tracker
        tracker.start()
        if session.loaded {
            checkContextChangeOnOpen(in: SpanNode.decodeList(session.lastKnownJSON))
        }
    }

    private func checkContextChangeOnOpen(in spans: [SpanNode], force: Bool = false) {
        guard force || autoLoglineCheckedNoteUrl != noteUrl else { return }
        autoLoglineCheckedNoteUrl = noteUrl
        guard EditorSettings.autoInsertLogline else { return }
        guard let tracker = contextTracker else { return }
        let snap = tracker.snapshot
        guard let previous = spans.reversed().compactMap({ node -> ContextSnapshot? in
            guard case .block(let block) = node else { return nil }
            return ContextSnapshot(block: block)
        }).first else { return }
        guard snap.hasSubstantialChange(from: previous) else { return }
        insertContextBlockAtEnd(BlockValue.contextBlock(from: snap))
        pushNow()
    }

    func checkContextChangeAfterReactivation() {
        guard session.loaded else { return }
        checkContextChangeOnOpen(in: SpanNode.decodeList(session.lastKnownJSON), force: true)
    }

    func insertLogline() {
        let snap = contextTracker?.snapshot ?? ContextSnapshot(timestamp: Date())
        insertBlockAttachment(RichText.contextLine(for: BlockValue.contextBlock(from: snap)))
    }

    private func insertContextBlockAtEnd(_ block: BlockValue) {
        guard let view, let storage = view.pStorage, storage.length > 0 else { return }
        let saved = view.pSelectedRange
        view.pSelectedRange = NSRange(location: max(0, storage.length - 1), length: 0)
        let line = block.type == "context" ? RichText.contextLine(for: block) : RichText.embedAttachment(for: block, cache: cache)
        insertBlockAttachment(line)
        view.pSelectedRange = NSRange(location: min(saved.location, storage.length), length: 0)
    }

    func load() {
        let url = noteUrl
        Task { [weak self] in
            guard let self else { return }
            let session = self.session
            if session.loaded {
                // The session survives across visits but this editor's asset
                // cache does not; reconcile text first, then reclassify embeds.
                let spans = SpanNode.decodeList(session.lastKnownJSON)
                guard self.noteUrl == url, self.session === session else { return }
                self.syncFromSession()
                #if !os(macOS)
                // No storage was swapped in (see layoutStorage), so the
                // incoming note's text has to be filled in before the awaits
                // below — otherwise the previous note stays on screen.
                self.apply(spans: spans)
                #endif
                self.checkContextChangeOnOpen(in: spans)
                let populated = await self.fetchMissingAssets(in: spans)
                guard self.noteUrl == url,
                      self.session === session,
                      self.session.lastKnownJSON == SpanNode.encodeList(spans)
                else { return }
                if populated {
                    self.apply(spans: spans)
                }
                // the cached session can be stale if the doc changed while no
                // editor was attached — revalidate against the core
                guard let snapshot = await self.model.spansSnapshot(for: url),
                      self.noteUrl == url, self.session === session,
                      snapshot.heads != session.heads
                else { return }
                session.heads = snapshot.heads
                let fresh = SpanNode.decodeList(snapshot.spansJson)
                if SpanNode.encodeList(fresh) != session.lastKnownJSON {
                    self.apply(spans: fresh)
                }
                return
            }
            let task: Task<NoteSpansSnapshot?, Never>
            if let loadTask = session.loadTask {
                task = loadTask
            } else {
                task = Task { [model] in await model.spansSnapshot(for: url) }
                session.loadTask = task
            }
            let snapshot = await task.value
            session.loadTask = nil
            guard self.noteUrl == url, self.session === session else { return }
            guard let snapshot else {
                #if !os(macOS)
                self.apply(spans: [])
                #endif
                return
            }
            let json = snapshot.spansJson
            let spans = SpanNode.decodeList(json)
            let canonicalJSON = SpanNode.encodeList(spans)
            session.heads = snapshot.heads
            session.loaded = true
            let shouldFocus = self.model.pendingFocusUrl == url
            if shouldFocus { self.model.pendingFocusUrl = nil }
            self.apply(spans: spans, focus: shouldFocus)
            self.checkContextChangeOnOpen(in: spans)
            guard await self.fetchMissingAssets(in: spans),
                  self.noteUrl == url,
                  self.session === session,
                  self.session.lastKnownJSON == canonicalJSON
            else { return }
            self.apply(spans: spans)
        }
    }

    private func syncFromSession() {
        attachViewToSharedStorage()
        guard let view = noteView else { return }
        let location = min(view.pSelectedRange.location, layoutStorage.length)
        view.pSelectedRange = NSRange(location: location, length: 0)
        refreshFormattingState()
    }

    private func fetchMissingAssets(in spans: [SpanNode]) async -> Bool {
        let urls: [String] = spans.compactMap { node -> String? in
            guard case .block(let block) = node,
                  block.isEmbedBlock,
                  let url = block.embedUrl,
                  url.hasPrefix("automerge:"),
                  cache.images[url] == nil, cache.names[url] == nil,
                  !cache.patchworkDocs.contains(url)
            else { return nil }
            return url
        }
        guard !urls.isEmpty else { return false }
        let model = self.model
        let fetched: [(String, Data?)] = await withTaskGroup(of: (String, Data?).self) { group in
            for url in urls {
                group.addTask {
                    let data = await model.assetBytes(url)
                    return (url, data)
                }
            }
            var results: [(String, Data?)] = []
            for await pair in group { results.append(pair) }
            return results
        }
        var populated = false
        for (url, data) in fetched {
            guard let data else {
                let info = await model.assetInfo(url)
                if (info?.mimeType ?? "").isEmpty {
                    cache.patchworkDocs.insert(url)
                    populated = true
                }
                continue
            }
            populated = true
            if let image = PImage(data: data) {
                cache.images[url] = image
            } else {
                let info = await model.assetInfo(url)
                let name = info?.name.isEmpty == false ? info!.name : "attachment"
                cache.names[url] = name
                switch AssetCache.kind(forName: name) {
                case "video":
                    await prepareVideo(url: url, name: name, data: data)
                case "audio":
                    cache.fileURLs[url] = Self.mediaFile(for: url, name: name, data: data)
                    if let vision = await model.assetVision(url), !vision.ocr.isEmpty {
                        cache.transcripts[url] = vision.ocr
                    }
                default:
                    break
                }
            }
        }
        return populated
    }

    /// The media a copied selection stands for, so a paste outside this app
    /// gets the picture and not a blank line where an image was.
    func copiedMedia(in attributed: NSAttributedString) -> (images: [PImage], files: [URL]) {
        var seen: Set<String> = []
        var images: [PImage] = []
        var files: [URL] = []
        attributed.enumerateAttribute(
            .amBlock,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            guard let box = value as? BlockBox,
                  box.value.isEmbedBlock,
                  let url = box.value.embedUrl,
                  seen.insert(url).inserted
            else { return }
            if let image = cache.images[url] {
                images.append(image)
            } else if let file = cache.fileURLs[url] {
                files.append(file)
            }
        }
        return (images, files)
    }

    func isPatchworkDoc(_ url: String) -> Bool {
        cache.patchworkDocs.contains(url)
    }

    func endEditing() {
        #if os(iOS)
        (view as? UITextView)?.resignFirstResponder()
        #endif
    }

    func inlineVideoSize(for url: String) -> CGSize? {
        guard let thumb = cache.videoThumbs[url] else { return nil }
        return RichText.fitted(thumb.size)
    }

    func videoFileURL(for url: String) -> URL? {
        cache.fileURLs[url]
    }

    func insertPatchworkEmbed(url: String, tool: String?) {
        cache.patchworkDocs.insert(url)
        var block = BlockValue.embed(url: url)
        if let tool, !tool.isEmpty {
            block.attrs["tool"] = .string(tool)
        }
        insertBlockAttachment(RichText.embedAttachment(for: block, cache: cache))
    }

    private func prepareVideo(url: String, name: String, data: Data) async {
        guard let fileURL = Self.mediaFile(for: url, name: name, data: data) else { return }
        cache.fileURLs[url] = fileURL
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 840, height: 680)
        if let (cgImage, _) = try? await generator.image(at: .init(seconds: 0.1, preferredTimescale: 600)) {
            #if os(macOS)
            let poster = NSImage(cgImage: cgImage, size: .zero)
            #else
            let poster = UIImage(cgImage: cgImage)
            #endif
            cache.videoThumbs[url] = PImage.playBadged(poster)
        }
    }

    static func mediaFile(for assetUrl: String, name: String, data: Data) -> URL? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AssetMedia", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = assetUrl.replacingOccurrences(of: "automerge:", with: "")
            .replacingOccurrences(of: "/", with: "_")
        let file = dir.appendingPathComponent("\(safe)-\(name)")
        if !FileManager.default.fileExists(atPath: file.path) {
            guard (try? data.write(to: file)) != nil else { return nil }
        }
        return file
    }

    /// TextKit builds an attachment's view provider while drawing, but only
    /// mounts it on the next viewport pass. Without one, an embed whose asset
    /// is still loading keeps its provider unmounted and shows TextKit's
    /// generic document icon until the next edit.
    private func placePendingAttachmentViews() {
        guard !placingAttachmentViews else { return }
        placingAttachmentViews = true
        let url = noteUrl
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.placingAttachmentViews = false
            guard self.noteUrl == url, let view = self.view else { return }
            #if os(macOS)
            view.pSelf.needsLayout = true
            view.pSelf.needsDisplay = true
            #else
            view.pSelf.setNeedsLayout()
            view.pSelf.setNeedsDisplay()
            #endif
        }
    }

    private func apply(spans: [SpanNode], focus: Bool = false) {
        guard let view = noteView, view.pStorage != nil else { return }
        // write out queued typing before it's discarded — the flush's write
        // merges with whatever this apply brings in
        if queuedTextSplice != nil {
            flushQueuedTextSplice()
        }
        let attributed = RichText.attributed(from: spans, cache: cache)
        let selection = view.pSelectedRange
        isApplyingDocumentState = true
        session.isApplyingDocumentState = true
        pendingTextSplice = nil
        queuedTextSplice = nil
        textSpliceFlushTask?.cancel()
        textSpliceFlushTask = nil
        // substitution decisions bake in at element creation; make sure the
        // hidden set matches the content we're about to lay out
        folding.refresh(storage: attributed)
        defer {
            isApplyingDocumentState = false
            session.isApplyingDocumentState = false
        }
        view.pPerformStorageEdit { storage in
            storage.setAttributedString(attributed)
        }
        var location = min(selection.location, attributed.length)
        if location == 0, attributed.length > 1 {
            let str = attributed.string as NSString
            var loc = 0
            while loc < attributed.length {
                if let box = attributed.attribute(.amBlock, at: loc, effectiveRange: nil) as? BlockBox,
                   box.value.isEmbedBlock {
                    loc = NSMaxRange(str.paragraphRange(for: NSRange(location: loc, length: 0)))
                } else {
                    break
                }
            }
            location = loc
        }
        view.pSelectedRange = NSRange(location: location, length: 0)
        if attributed.length == 0 {
            // Notes-style: an empty note starts with a Title line.
            view.pTypingAttributes = RichText.attributes(block: .heading(level: 1), marks: [:])
        }
        session.lastKnownJSON = SpanNode.encodeList(spans)
        session.lastKnownEmbeds = embedCount(in: spans)
        session.title = RichText.title(from: spans)
        refreshFormattingState()
        updateGlobalMatches()
        if controller.findVisible {
            updateFindMatches(resetIndex: false)
        }
        scheduleMinimapUpdate()
        placePendingAttachmentViews()
        // the edit observer skips its bump while applying document state, so
        // canvas/outline inspectors would otherwise render the old doc
        controller.docVersion &+= 1
        if location == attributed.length, location > 0,
           let lastNonEmbed = spans.reversed().compactMap({ (s: SpanNode) -> BlockValue? in guard case .block(let b) = s, !b.isEmbedBlock else { return nil }; return b }).first {
            view.pTypingAttributes = RichText.attributes(block: lastNonEmbed, marks: [:])
            controller.currentStyleKey = lastNonEmbed.styleKey
            controller.currentCodeLanguage = lastNonEmbed.codeLanguage
        }
        if focus {
            #if os(macOS)
            view.pSelf.window?.makeFirstResponder(view.pSelf)
            #else
            view.pSelf.becomeFirstResponder()
            #endif
        }
    }

    private func remoteChanged(_ url: String) {
        guard url == noteUrl else { return }
        guard session.loaded else {
            session.loadTask = nil
            load()
            return
        }
        // write out anything the user just typed before the reload discards
        // the pending splices; the flush defers the reload via localWrites
        if queuedTextSplice != nil {
            flushQueuedTextSplice()
        }
        guard localWritesInFlight == 0 else {
            pendingRemoteReload = true
            return
        }
        remoteReloadGeneration += 1
        let generation = remoteReloadGeneration
        remoteReloadTask?.cancel()
        remoteReloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard let snapshot = await self.model.spansSnapshot(for: url) else { return }
            guard !Task.isCancelled, self.noteUrl == url, self.remoteReloadGeneration == generation else { return }
            // don't clobber an active IME composition; wait it out briefly
            var markedWaits = 0
            while self.hasMarkedText(), markedWaits < 5 {
                markedWaits += 1
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, self.noteUrl == url,
                      self.remoteReloadGeneration == generation else { return }
            }
            let json = snapshot.spansJson
            let spans = SpanNode.decodeList(json)
            self.session.heads = snapshot.heads
            let canonical = SpanNode.encodeList(spans)
            if canonical != self.session.lastKnownJSON {
                self.apply(spans: spans)
            }
            guard await self.fetchMissingAssets(in: spans),
                  !Task.isCancelled,
                  self.noteUrl == url,
                  self.remoteReloadGeneration == generation,
                  self.session.lastKnownJSON == canonical
            else { return }
            self.apply(spans: spans)
        }
    }

    private func beginLocalWrite() {
        localWritesInFlight += 1
    }

    private func finishLocalWrite(for url: String) {
        localWritesInFlight = max(0, localWritesInFlight - 1)
        guard localWritesInFlight == 0, pendingRemoteReload, noteUrl == url else { return }
        pendingRemoteReload = false
        remoteChanged(url)
    }

    // MARK: saving

    private struct PendingTextSplice {
        let index: UInt64
        let deleteCount: Int64
        let insert: String
        let utf16Location: Int
        let utf16Length: Int
    }

    private struct QueuedTextSplice {
        let url: String
        var index: UInt64
        var deleteCount: Int64
        var insert: String
        var utf16EndLocation: Int
        let heads: [String]
    }

    private struct PreparedTextMark {
        let start: UInt64
        let end: UInt64
        let valueJson: String?
    }

    func prepareTextSplice(range: NSRange, replacement: String) -> Bool {
        pendingTextSplice = nil
        guard let storage = view?.pStorage else { return false }
        guard isPlainTextSpliceCandidate(in: storage, range: range, replacement: replacement) else {
            return false
        }
        let deleteCount = editableScalarCount(in: storage, range: range)
        let index: UInt64
        if range.length == 0,
           !replacement.isEmpty,
           let queued = queuedTextSplice,
           queued.url == noteUrl,
           queued.deleteCount == 0,
           range.location == queued.utf16EndLocation {
            index = queued.index + UInt64(queued.insert.unicodeScalars.count)
        } else if replacement.isEmpty,
                  range.length > 0,
                  let queued = queuedTextSplice,
                  queued.url == noteUrl,
                  queued.insert.isEmpty,
                  range.location == queued.utf16EndLocation {
            index = queued.index
        } else if replacement.isEmpty,
                  range.length > 0,
                  deleteCount > 0,
                  let queued = queuedTextSplice,
                  queued.url == noteUrl,
                  queued.insert.isEmpty,
                  NSMaxRange(range) == queued.utf16EndLocation,
                  queued.index >= UInt64(deleteCount) {
            index = queued.index - UInt64(deleteCount)
        } else {
            guard let resolved = automergeTextPosition(in: storage, at: range.location) else {
                return false
            }
            index = UInt64(resolved)
        }
        pendingTextSplice = PendingTextSplice(
            index: index,
            deleteCount: Int64(deleteCount),
            insert: replacement,
            utf16Location: range.location,
            utf16Length: range.length
        )
        return true
    }

    func preserveTypingAttributes(forReplacement range: NSRange) {
        guard let view,
              let storage = view.pStorage,
              range.length > 0,
              range.location < storage.length
        else { return }
        let attributes = storage.attributes(at: range.location, effectiveRange: nil)
        guard let box = attributes[.amBlock] as? BlockBox, !box.value.isAtomic else { return }
        view.pTypingAttributes = RichText.attributes(
            block: box.value,
            marks: RichText.marks(from: attributes, block: box.value)
        )
    }

    func textDidChange() {
        guard session.loaded, !isApplyingDocumentState, !session.isApplyingDocumentState else { return }
        guard let pending = pendingTextSplice else {
            scheduleSave()
            return
        }
        pendingTextSplice = nil
        guard view?.pStorage != nil else {
            scheduleSave()
            return
        }
        let url = noteUrl
        if pending.deleteCount == 0,
           let queued = queuedTextSplice,
           queued.url == url,
           queued.deleteCount == 0,
           pending.utf16Length == 0,
           pending.utf16Location == queued.utf16EndLocation,
           pending.index == queued.index + UInt64(queued.insert.unicodeScalars.count) {
            queuedTextSplice?.insert += pending.insert
            queuedTextSplice?.utf16EndLocation += (pending.insert as NSString).length
            scheduleQueuedTextSpliceFlush()
            return
        }
        if pending.insert.isEmpty,
           pending.deleteCount > 0,
           let queued = queuedTextSplice,
           queued.url == url,
           queued.insert.isEmpty,
           pending.utf16Location == queued.utf16EndLocation,
           pending.index == queued.index {
            queuedTextSplice?.deleteCount += pending.deleteCount
            scheduleQueuedTextSpliceFlush()
            return
        }
        if pending.insert.isEmpty,
           pending.deleteCount > 0,
           let queued = queuedTextSplice,
           queued.url == url,
           queued.insert.isEmpty,
           NSMaxRange(NSRange(location: pending.utf16Location, length: pending.utf16Length)) == queued.utf16EndLocation,
           pending.index + UInt64(pending.deleteCount) == queued.index {
            queuedTextSplice?.index = pending.index
            queuedTextSplice?.deleteCount += pending.deleteCount
            queuedTextSplice?.utf16EndLocation = pending.utf16Location
            scheduleQueuedTextSpliceFlush()
            return
        }
        flushQueuedTextSplice()
        queuedTextSplice = QueuedTextSplice(
            url: url,
            index: pending.index,
            deleteCount: pending.deleteCount,
            insert: pending.insert,
            utf16EndLocation: pending.utf16Location + (pending.insert as NSString).length,
            heads: session.heads
        )
        scheduleQueuedTextSpliceFlush()
    }

    private func scheduleQueuedTextSpliceFlush() {
        textSpliceFlushTask?.cancel()
        textSpliceFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.flushQueuedTextSplice()
        }
    }

    private func flushQueuedTextSplice() {
        textSpliceFlushTask?.cancel()
        textSpliceFlushTask = nil
        guard let queued = queuedTextSplice else { return }
        queuedTextSplice = nil
        let url = queued.url
        let written = EditorDocumentSessions.session(for: url)
        if url == noteUrl, let storage = view?.pStorage {
            written.title = RichText.title(from: RichText.spans(from: storage))
        }
        let title = written.title
        let heads = queued.heads
        let previousHeadsTask = localWriteHeadsTask
        beginLocalWrite()
        let task = Task { [weak self] () -> [String]? in
            let chainedHeads = await previousHeadsTask?.value
            guard let self else { return nil }
            defer { self.finishLocalWrite(for: url) }
            let writeHeads = chainedHeads ?? heads
            let newHeads = await self.model.spliceNoteText(
                url,
                index: queued.index,
                deleteCount: queued.deleteCount,
                insert: queued.insert,
                title: title,
                spansJson: nil,
                heads: writeHeads,
                origin: self.noteObserverId
            )
            guard let newHeads else {
                if self.noteUrl == url { self.scheduleSave() }
                return nil
            }
            // the note may have switched mid-flight; the heads belong to the
            // written note's session either way
            EditorDocumentSessions.session(for: url).heads = newHeads
            return newHeads
        }
        localWriteHeadsTask = task
    }

    func scheduleSave() {
        guard session.loaded, !isApplyingDocumentState, !session.isApplyingDocumentState else { return }
        flushQueuedTextSplice()
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.pushNow()
        }
    }

    func pushNow() {
        guard session.loaded, !isApplyingDocumentState, !session.isApplyingDocumentState else { return }
        // flush, then still push the snapshot — returning here dropped the
        // structural save entirely, leaving the doc missing the last edits
        if queuedTextSplice != nil {
            flushQueuedTextSplice()
        }
        saveTask?.cancel()
        saveTask = nil
        guard let storage = noteView?.pStorage else { return }
        let typing = typingBlock(in: noteView)
        let spans = RichText.spans(from: storage, trailingBlock: typing.isAtomic ? nil : typing)
        let json = SpanNode.encodeList(spans)
        guard json != session.lastKnownJSON else { return }
        let embeds = embedCount(in: spans)
        if embeds < session.lastKnownEmbeds {
            NSLog("lush save: embed count dropped %d -> %d in %@", session.lastKnownEmbeds, embeds, noteUrl)
        }
        session.lastKnownJSON = json
        session.lastKnownEmbeds = embeds
        let url = noteUrl
        let title = RichText.title(from: spans)
        session.title = title
        let heads = session.heads
        let previousHeadsTask = localWriteHeadsTask
        beginLocalWrite()
        let task = Task { [weak self] () -> [String]? in
            let chainedHeads = await previousHeadsTask?.value
            guard let self else { return nil }
            defer { self.finishLocalWrite(for: url) }
            let writeHeads = chainedHeads ?? (heads.isEmpty ? nil : heads)
            let newHeads = await self.model.updateDocument(
                url,
                json: json,
                title: title,
                heads: writeHeads,
                origin: self.noteObserverId
            )
            if let newHeads {
                EditorDocumentSessions.session(for: url).heads = newHeads
            }
            return newHeads
        }
        localWriteHeadsTask = task
    }

    private func automergeTextPosition(in storage: NSAttributedString, at location: Int) -> Int? {
        let string = storage.string as NSString
        guard location >= 0, location <= string.length else { return nil }
        guard string.length > 0 else { return nil }
        var position = 0
        var cursor = 0
        while cursor < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: cursor, length: 0))
            let contentEnd = paragraphContentEnd(in: string, paragraph: paragraph)
            position += 1
            if location >= paragraph.location, location <= contentEnd {
                let prefix = NSRange(location: paragraph.location, length: location - paragraph.location)
                return position + editableScalarCount(in: storage, range: prefix)
            }
            position += editableScalarCount(
                in: storage,
                range: NSRange(location: paragraph.location, length: contentEnd - paragraph.location)
            )
            cursor = NSMaxRange(paragraph)
        }
        return position
    }

    private func paragraphContentEnd(in string: NSString, paragraph: NSRange) -> Int {
        guard paragraph.length > 0 else { return paragraph.location }
        let end = NSMaxRange(paragraph)
        return string.character(at: end - 1) == 0x0A ? end - 1 : end
    }

    /// Table and columns layouts are one attachment char in storage but many
    /// spans in the doc, so index arithmetic across them is wrong — those
    /// notes take the whole-doc save path instead.
    private func storageHasAtomicLayout(in storage: NSAttributedString, before location: Int) -> Bool {
        let limit = min(max(location, 0), storage.length)
        guard limit > 0 else { return false }
        var found = false
        for key in [NSAttributedString.Key.amTableBox, .amColumnsBox] {
            storage.enumerateAttribute(key, in: NSRange(location: 0, length: limit)) { value, _, stop in
                if value != nil {
                    found = true
                    stop.pointee = true
                }
            }
            if found { return true }
        }
        return false
    }

    private func isPlainTextSpliceCandidate(
        in storage: NSAttributedString,
        range: NSRange,
        replacement: String
    ) -> Bool {
        let string = storage.string as NSString
        guard range.location >= 0,
              range.length >= 0,
              NSMaxRange(range) <= string.length
        else { return false }
        guard !storageHasAtomicLayout(in: storage, before: range.location) else { return false }
        // a pending structural save means the doc hasn't caught up with the
        // storage yet — splice indexes computed now would land wrong
        guard saveTask == nil else { return false }
        guard !hasMarkedText() else { return false }
        guard !replacement.contains("\n"),
              !replacement.contains("\u{FFFC}")
        else { return false }
        if !replacement.isEmpty {
            guard let view else { return false }
            let block = typingBlock()
            guard RichText.marks(from: view.pTypingAttributes, block: block).isEmpty else {
                return false
            }
        }
        if range.length > 0 {
            guard !string.substring(with: range).contains("\n") else { return false }
            let paragraph = string.paragraphRange(for: NSRange(location: range.location, length: 0))
            guard NSMaxRange(range) <= paragraphContentEnd(in: string, paragraph: paragraph) else {
                return false
            }
            guard attributesArePlainEditable(in: storage, range: range) else {
                return false
            }
        } else if storage.length > 0 {
            guard insertionPointIsPlainEditable(in: storage, location: range.location) else {
                return false
            }
        }
        return true
    }

    private func hasMarkedText() -> Bool {
        #if os(macOS)
        if let textView = view as? NSTextView {
            return textView.hasMarkedText()
        }
        #else
        if let textView = view as? UITextView {
            return textView.markedTextRange != nil
        }
        #endif
        return false
    }

    private func insertionPointIsPlainEditable(
        in storage: NSAttributedString,
        location: Int
    ) -> Bool {
        guard storage.length > 0 else { return true }
        let probeLocations = [
            min(location, storage.length - 1),
            max(0, location - 1),
        ]
        for probe in Set(probeLocations) {
            guard attributesArePlainEditable(
                in: storage,
                range: NSRange(location: probe, length: 1)
            ) else { return false }
        }
        return true
    }

    private func attributesArePlainEditable(
        in storage: NSAttributedString,
        range: NSRange
    ) -> Bool {
        guard range.length > 0 else { return true }
        var ok = true
        storage.enumerateAttributes(in: range) { attrs, _, stop in
            if attrs[.amDisplayOnly] != nil
                || attrs[.attachment] != nil
                || attrs[.amTableBox] != nil
                || attrs[.amColumnsBox] != nil
                || (attrs[.amBlock] as? BlockBox)?.value.isAtomic == true {
                ok = false
                stop.pointee = true
                return
            }
            let block = (attrs[.amBlock] as? BlockBox)?.value ?? .paragraph
            if !RichText.marks(from: attrs, block: block).isEmpty {
                ok = false
                stop.pointee = true
            }
        }
        return ok
    }

    private func prepareTextMark(
        range: NSRange,
        value: JSONValue?
    ) -> PreparedTextMark? {
        guard let storage = view?.pStorage else { return nil }
        guard range.length > 0,
              isPlainTextSpliceCandidate(in: storage, range: range, replacement: "")
        else { return nil }
        guard let start = automergeTextPosition(in: storage, at: range.location) else {
            return nil
        }
        let count = editableScalarCount(in: storage, range: range)
        guard count > 0 else { return nil }
        let valueJson: String?
        if let value {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(value),
                  let json = String(data: data, encoding: .utf8)
            else { return nil }
            valueJson = json
        } else {
            valueJson = nil
        }
        return PreparedTextMark(
            start: UInt64(start),
            end: UInt64(start + count),
            valueJson: valueJson
        )
    }

    private func editableScalarCount(in storage: NSAttributedString, range: NSRange) -> Int {
        guard range.length > 0 else { return 0 }
        let string = storage.string as NSString
        return withUnsafeTemporaryAllocation(of: unichar.self, capacity: range.length) { units in
            string.getCharacters(units.baseAddress!, range: range)
            var count = 0
            storage.enumerateAttribute(.amDisplayOnly, in: range) { displayOnly, runRange, _ in
                guard displayOnly == nil else { return }
                let start = runRange.location - range.location
                let end = start + runRange.length
                var i = start
                while i < end {
                    let unit = units[i]
                    if unit == 0xFFFC {
                        i += 1
                        continue
                    }
                    if unit >= 0xD800, unit < 0xDC00 {
                        if i + 1 < end, units[i + 1] >= 0xDC00, units[i + 1] < 0xE000 {
                            count += 1
                            i += 2
                        } else {
                            i += 1
                        }
                        continue
                    }
                    if unit >= 0xDC00, unit < 0xE000 {
                        i += 1
                        continue
                    }
                    count += 1
                    i += 1
                }
            }
            return count
        }
    }

    // MARK: outline

    func outlineItems() -> [OutlineItem] {
        guard let storage = view?.pStorage, storage.length > 0 else { return [] }
        let str = storage.string as NSString
        var items: [OutlineItem] = []
        var location = 0
        while location < storage.length {
            let paragraph = str.paragraphRange(for: NSRange(location: location, length: 0))
            if paragraph.length == 0 { break }
            location = NSMaxRange(paragraph)
            guard let box = storage.attribute(.amBlock, at: paragraph.location, effectiveRange: nil) as? BlockBox,
                  box.value.type == "heading"
            else { continue }
            let text = str.substring(with: paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
            items.append(OutlineItem(
                location: paragraph.location,
                level: box.value.headingLevel ?? 1,
                text: text
            ))
        }
        return items
    }

    func scrollTo(location: Int) {
        guard let view, let storage = view.pStorage, storage.length > 0 else { return }
        let clamped = min(max(0, location), storage.length - 1)
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: clamped, length: 0))
        view.pSelectedRange = NSRange(location: paragraph.location, length: 0)
        view.pScrollRangeToVisible(paragraph)
    }

    // MARK: folding

    /// Rebuild the substituted elements after fold state changes. Pass `previous` when the storage was already edited on the way
    /// here — the edit observer refreshes `folding.hiddenRanges` eagerly,
    /// which would otherwise lose the ranges that need un-substituting.
    func rebuildHiddenRanges(previous: [NSRange]? = nil) {
        guard let view, let storage = view.pStorage else { return }
        let before = previous ?? folding.hiddenRanges
        folding.refresh(storage: storage)
        let union = before + folding.hiddenRanges
        guard !union.isEmpty else { return }
        view.pPerformStorageEdit { storage in
            storage.beginEditing()
            for range in union where NSMaxRange(range) <= storage.length {
                storage.edited([.editedAttributes], range: range, changeInLength: 0)
            }
            storage.endEditing()
        }
    }

    func toggleFold(headingAt location: Int) {
        guard let view, let storage = view.pStorage, storage.length > 0 else { return }
        let clamped = min(max(0, location), storage.length - 1)
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: clamped, length: 0))
        guard paragraph.length > 0,
              let box = storage.attribute(.amBlock, at: paragraph.location, effectiveRange: nil) as? BlockBox,
              box.value.type == "heading"
        else { return }
        let key = HeadingFoldKey(paragraph: paragraph, in: storage, box: box)
        if folding.foldedHeadings.contains(key) {
            folding.foldedHeadings.remove(key)
            rebuildHiddenRanges()
        } else {
            folding.foldedHeadings.insert(key)
            rebuildHiddenRanges()
            let caret = view.pSelectedRange.location
            if folding.isHidden(min(caret, storage.length - 1)) {
                view.pSelectedRange = NSRange(location: paragraph.location, length: 0)
            }
        }
    }

    /// Fold or unfold the section the caret is in.
    func toggleFoldAtSelection() {
        guard let view, let storage = view.pStorage, storage.length > 0 else { return }
        let str = storage.string as NSString
        var cursor = min(view.pSelectedRange.location, storage.length - 1)
        while cursor >= 0 {
            let paragraph = str.paragraphRange(for: NSRange(location: cursor, length: 0))
            if paragraph.length > 0,
               let box = storage.attribute(.amBlock, at: paragraph.location, effectiveRange: nil) as? BlockBox,
               box.value.type == "heading" {
                toggleFold(headingAt: paragraph.location)
                return
            }
            cursor = paragraph.location - 1
        }
    }

    /// A click in the gutter left of a heading toggles its fold.
    func foldHit(at point: CGPoint) -> Bool {
        guard point.x < 0, point.x > -24,
              let storage = view?.pStorage, storage.length > 0,
              let textLayoutManager = view?.pTextLayoutManager,
              let contentManager = textLayoutManager.textContentManager,
              let fragment = textLayoutManager.textLayoutFragment(for: CGPoint(x: 0, y: point.y)),
              let elementRange = fragment.textElement?.elementRange
        else { return false }
        let location = contentManager.offset(from: contentManager.documentRange.location, to: elementRange.location)
        guard location >= 0, location < storage.length,
              let box = storage.attribute(.amBlock, at: location, effectiveRange: nil) as? BlockBox,
              box.value.type == "heading"
        else { return false }
        toggleFold(headingAt: location)
        return true
    }

    private func unfoldIfCaretHidden() {
        guard !folding.hiddenRanges.isEmpty, let view, let storage = view.pStorage else { return }
        let caret = view.pSelectedRange.location
        guard folding.isHidden(caret) else { return }
        let str = storage.string as NSString
        var cursor = min(caret, storage.length - 1)
        while cursor >= 0 {
            let paragraph = str.paragraphRange(for: NSRange(location: cursor, length: 0))
            if paragraph.length > 0,
               let box = storage.attribute(.amBlock, at: paragraph.location, effectiveRange: nil) as? BlockBox,
               box.value.type == "heading",
               folding.foldedHeadings.contains(HeadingFoldKey(paragraph: paragraph, in: storage, box: box)) {
                folding.foldedHeadings.remove(HeadingFoldKey(paragraph: paragraph, in: storage, box: box))
                rebuildHiddenRanges()
                return
            }
            cursor = paragraph.location - 1
        }
        // hidden text with no fold to open — typing there would edit
        // invisible content, so snap the caret past the hidden range
        if let range = folding.hiddenRanges.first(where: { NSLocationInRange(caret, $0) }) {
            view.pSelectedRange = NSRange(location: min(NSMaxRange(range), storage.length), length: 0)
        }
    }

    // MARK: presence carets

    private var caretBroadcastTask: Task<Void, Never>?
    private var remoteCaretViews: [String: PView] = [:]

    func broadcastCaret() {
        guard model.presence.docUrl == noteUrl else { return }
        caretBroadcastTask?.cancel()
        let url = noteUrl
        caretBroadcastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self,
                  self.noteUrl == url,
                  self.model.presence.docUrl == url,
                  let view = self.view,
                  let storage = view.pStorage, let core = self.model.core
            else { return }
            let selection = view.pSelectedRange
            guard !self.storageHasAtomicLayout(in: storage, before: selection.location) else { return }
            guard let anchorIndex = self.automergeTextPosition(in: storage, at: selection.location) else { return }
            let head = selection.length == 0
                ? anchorIndex
                : self.automergeTextPosition(in: storage, at: NSMaxRange(selection))
            guard let headIndex = head else { return }
            // the cursor FFI can block on the doc lock — keep it off main
            let cursors = await Task.detached { () -> (String, String)? in
                guard let anchor = try? core.textCursor(url: url, index: UInt64(anchorIndex)) else { return nil }
                if anchorIndex == headIndex { return (anchor, anchor) }
                guard let head = try? core.textCursor(url: url, index: UInt64(headIndex)) else { return nil }
                return (anchor, head)
            }.value
            guard let cursors, !Task.isCancelled,
                  self.noteUrl == url,
                  self.model.presence.docUrl == url
            else { return }
            self.model.presence.caretChanged(anchor: cursors.0, head: cursors.1)
        }
    }

    /// Inverse of `automergeTextPosition`: binary-search the utf16 offset
    /// whose editable-scalar prefix matches the automerge index.
    private func utf16Position(forAutomergeIndex target: Int, in storage: NSAttributedString) -> Int? {
        let string = storage.string as NSString
        guard string.length > 0 else { return nil }
        var position = 0
        var cursor = 0
        while cursor < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: cursor, length: 0))
            let contentEnd = paragraphContentEnd(in: string, paragraph: paragraph)
            position += 1
            let contentScalars = editableScalarCount(
                in: storage,
                range: NSRange(location: paragraph.location, length: contentEnd - paragraph.location)
            )
            if target <= position + contentScalars {
                let need = target - position
                var low = paragraph.location
                var high = contentEnd
                while low < high {
                    let mid = (low + high) / 2
                    let prefix = editableScalarCount(
                        in: storage,
                        range: NSRange(location: paragraph.location, length: mid - paragraph.location)
                    )
                    if prefix < need { low = mid + 1 } else { high = mid }
                }
                return low
            }
            position += contentScalars
            cursor = NSMaxRange(paragraph)
        }
        return string.length
    }

    private var remoteCaretUpdateScheduled = false

    func scheduleRemoteCaretUpdate() {
        guard !remoteCaretUpdateScheduled else { return }
        remoteCaretUpdateScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            self?.remoteCaretUpdateScheduled = false
            self?.updateRemoteCarets()
        }
    }

    private func removeRemoteCaretViews() {
        guard !remoteCaretViews.isEmpty else { return }
        for bar in remoteCaretViews.values { bar.removeFromSuperview() }
        remoteCaretViews.removeAll()
    }

    func updateRemoteCarets() {
        guard let view, let storage = view.pStorage,
              model.presence.docUrl == noteUrl,
              view.pTextLayoutManager != nil,
              let core = model.core,
              !storageHasAtomicLayout(in: storage, before: storage.length)
        else {
            removeRemoteCaretViews()
            return
        }
        let peersWithCursors = model.presence.peers.values.filter { $0.cursor != nil }
        if peersWithCursors.isEmpty {
            removeRemoteCaretViews()
            return
        }
        let url = noteUrl
        let heads: [(String, String)] = peersWithCursors.compactMap {
            guard let cursor = $0.cursor else { return nil }
            return ($0.senderId, cursor.head)
        }
        // cursorIndex FFI can block on the doc lock — keep it off main
        Task { @MainActor [weak self] in
            let indices = await Task.detached { () -> [String: UInt64] in
                var out: [String: UInt64] = [:]
                for (senderId, head) in heads {
                    if let index = try? core.cursorIndex(url: url, cursor: head) {
                        out[senderId] = index
                    }
                }
                return out
            }.value
            guard let self, self.noteUrl == url else { return }
            self.layoutRemoteCarets(automergeIndices: indices)
        }
    }

    private func layoutRemoteCarets(automergeIndices: [String: UInt64]) {
        guard let view, let storage = view.pStorage,
              model.presence.docUrl == noteUrl,
              let textLayoutManager = view.pTextLayoutManager,
              let contentManager = textLayoutManager.textContentManager
        else {
            removeRemoteCaretViews()
            return
        }
        let peersWithCursors = model.presence.peers.values.filter { $0.cursor != nil }
        if peersWithCursors.isEmpty {
            removeRemoteCaretViews()
            return
        }
        let origin = view.pTextOrigin
        var seen = Set<String>()
        for peer in peersWithCursors {
            guard let headIndex = automergeIndices[peer.senderId],
                  let headOffset = utf16Position(forAutomergeIndex: Int(headIndex), in: storage),
                  let textRange = contentManager.textRange(
                      for: NSRange(location: min(headOffset, storage.length), length: 0)
                  )
            else { continue }
            var rect: CGRect?
            textLayoutManager.enumerateTextSegments(
                in: textRange,
                type: .selection,
                options: [.rangeNotRequired]
            ) { _, frame, _, _ in
                rect = frame
                return false
            }
            guard let rect else { continue }
            seen.insert(peer.senderId)
            let bar: PView
            if let existing = remoteCaretViews[peer.senderId] {
                bar = existing
            } else {
                bar = PView(frame: .zero)
                remoteCaretViews[peer.senderId] = bar
            }
            #if os(macOS)
            bar.wantsLayer = true
            bar.layer?.backgroundColor = PresenceManager.platformColor(peer.color).cgColor
            bar.layer?.cornerRadius = 1.25
            #else
            bar.layer.backgroundColor = PresenceManager.platformColor(peer.color).cgColor
            bar.layer.cornerRadius = 1.25
            #endif
            if bar.superview !== view.pSelf { view.pSelf.addSubview(bar) }
            bar.frame = CGRect(
                x: rect.minX + origin.x - 1,
                y: rect.minY + origin.y,
                width: 2.5,
                height: max(14, rect.height)
            )
        }
        for (id, stale) in remoteCaretViews where !seen.contains(id) {
            stale.removeFromSuperview()
            remoteCaretViews.removeValue(forKey: id)
        }
    }

    // MARK: block reorder

    /// A drag-handle move: delete the paragraph and reinsert it at the drop
    /// boundary. A splice in automerge terms, like any reorder.
    func moveParagraph(fromParagraphAt sourceLocation: Int, toDropIndex dropIndex: Int) {
        guard let view, let storage = view.pStorage, storage.length > 0 else { return }
        let str = storage.string as NSString
        let source = str.paragraphRange(for: NSRange(location: min(sourceLocation, storage.length - 1), length: 0))
        guard let landing = moveSpan(source, toDropIndex: dropIndex) else { return }
        view.pSelectedRange = NSRange(location: landing, length: 0)
    }

    /// Lift a whole number of paragraphs out and reinsert them at a paragraph
    /// boundary. Returns where the moved text now starts.
    @discardableResult
    private func moveSpan(
        _ source: NSRange,
        toDropIndex dropIndex: Int,
        actionName: String = "Move Paragraph"
    ) -> Int? {
        guard let view, let storage = view.pStorage, storage.length > 0 else { return nil }
        let str = storage.string as NSString
        guard source.length > 0, !NSLocationInRange(dropIndex, source) else { return nil }
        // dropping past a final paragraph that has no trailing newline must
        // land after it, not at its paragraph start
        let droppingAtEnd = dropIndex >= storage.length && !str.hasSuffix("\n")
        if droppingAtEnd, NSMaxRange(source) >= storage.length { return nil }
        let undo = undoSnapshot()
        let hiddenBefore = folding.hiddenRanges
        let slice = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: source))
        // the last paragraph carries no trailing newline; without one the
        // moved block merges into its new neighbour
        if !slice.string.hasSuffix("\n"), slice.length > 0 {
            let tail = slice.attributes(at: slice.length - 1, effectiveRange: nil)
            slice.append(NSAttributedString(string: "\n", attributes: tail))
        }
        var target: Int
        var contentOffset = 0
        if droppingAtEnd {
            target = storage.length
            contentOffset = 1
            slice.deleteCharacters(in: NSRange(location: slice.length - 1, length: 1))
            slice.insert(
                NSAttributedString(string: "\n", attributes: endSeparatorAttributes(in: storage)),
                at: 0
            )
        } else {
            target = str.paragraphRange(for: NSRange(location: min(dropIndex, storage.length), length: 0)).location
        }
        view.pPerformStorageEdit { storage in
            storage.beginEditing()
            storage.replaceCharacters(in: source, with: NSAttributedString())
            if target > source.location { target -= source.length }
            storage.insert(slice, at: min(target, storage.length))
            storage.endEditing()
        }
        rebuildHiddenRanges(previous: hiddenBefore)
        registerUndo(from: undo, actionName: actionName)
        scheduleSave()
        return min(target, storage.length) + contentOffset
    }

    struct ParagraphEntry {
        let range: NSRange
        let block: BlockValue
    }

    private func paragraphEntries(in storage: NSTextStorage) -> [ParagraphEntry] {
        let str = storage.string as NSString
        var out: [ParagraphEntry] = []
        var location = 0
        while location < storage.length {
            let paragraph = str.paragraphRange(for: NSRange(location: location, length: 0))
            if paragraph.length == 0 { break }
            location = NSMaxRange(paragraph)
            let box = storage.attribute(.amBlock, at: paragraph.location, effectiveRange: nil) as? BlockBox
            out.append(ParagraphEntry(range: paragraph, block: box?.value ?? .paragraph))
        }
        return out
    }

    /// ⌃⌘↑ / ⌃⌘↓: move the caret's item past its neighbouring sibling,
    /// carrying anything nested under it.
    func moveListItem(by delta: Int) {
        guard let view, let storage = view.pStorage, storage.length > 0 else { return }
        let entries = paragraphEntries(in: storage)
        guard entries.count > 1 else { return }
        let caret = min(view.pSelectedRange.location, storage.length)
        guard let index = entries.lastIndex(where: { $0.range.location <= caret }) else { return }
        let depth = entries[index].block.parents.count
        var end = index + 1
        while end < entries.count, entries[end].block.parents.count > depth { end += 1 }
        let source = NSRange(
            location: entries[index].range.location,
            length: NSMaxRange(entries[end - 1].range) - entries[index].range.location
        )
        let caretOffset = caret - source.location
        let drop: Int
        if delta < 0 {
            guard let previous = entries[..<index].lastIndex(where: { $0.block.parents.count <= depth })
            else { return }
            drop = entries[previous].range.location
        } else {
            guard end < entries.count else { return }
            let siblingDepth = entries[end].block.parents.count
            var after = end + 1
            while after < entries.count, entries[after].block.parents.count > siblingDepth { after += 1 }
            drop = after < entries.count ? entries[after].range.location : storage.length
        }
        guard let landing = moveSpan(source, toDropIndex: drop, actionName: "Move Item") else { return }
        view.pSelectedRange = NSRange(location: min(landing + caretOffset, storage.length), length: 0)
    }

    private struct TodoUnit {
        let range: NSRange
        let checked: Bool
    }

    /// The run of to-do items the caret sits in, split into items at the run's
    /// shallowest depth — each carrying whatever is nested under it.
    private func todoRun(around caret: Int, in storage: NSTextStorage) -> (span: NSRange, units: [TodoUnit])? {
        let entries = paragraphEntries(in: storage)
        guard let index = entries.lastIndex(where: { $0.range.location <= caret }),
              entries[index].block.type == "todo-list-item"
        else { return nil }
        var first = index
        var last = index
        while first > 0, entries[first - 1].block.type == "todo-list-item" { first -= 1 }
        while last + 1 < entries.count, entries[last + 1].block.type == "todo-list-item" { last += 1 }
        let base = entries[first...last].map { $0.block.parents.count }.min() ?? 0
        var units: [TodoUnit] = []
        var cursor = first
        while cursor <= last {
            var next = cursor + 1
            while next <= last, entries[next].block.parents.count > base { next += 1 }
            units.append(TodoUnit(
                range: NSRange(
                    location: entries[cursor].range.location,
                    length: NSMaxRange(entries[next - 1].range) - entries[cursor].range.location
                ),
                checked: entries[cursor].block.isChecked
            ))
            cursor = next
        }
        let span = NSRange(
            location: entries[first].range.location,
            length: NSMaxRange(entries[last].range) - entries[first].range.location
        )
        return (span, units)
    }

    /// Stable partition of the caret's checklist: unticked items keep their
    /// order at the top, ticked ones keep theirs at the bottom.
    func moveCheckedToBottom() {
        guard let view, let storage = view.pStorage, storage.length > 0 else { return }
        let caret = min(view.pSelectedRange.location, storage.length)
        guard let (span, units) = todoRun(around: caret, in: storage) else { return }
        let sorted = units.filter { !$0.checked } + units.filter { $0.checked }
        guard sorted.map({ $0.range.location }) != units.map({ $0.range.location }) else { return }
        let undo = undoSnapshot()
        let hiddenBefore = folding.hiddenRanges
        let endsDocument = NSMaxRange(span) >= storage.length
            && !(storage.string as NSString).hasSuffix("\n")
        let rebuilt = NSMutableAttributedString()
        for unit in sorted {
            let piece = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: unit.range))
            if !piece.string.hasSuffix("\n"), piece.length > 0 {
                let tail = piece.attributes(at: piece.length - 1, effectiveRange: nil)
                piece.append(NSAttributedString(string: "\n", attributes: tail))
            }
            rebuilt.append(piece)
        }
        if endsDocument, rebuilt.length > 0 {
            rebuilt.deleteCharacters(in: NSRange(location: rebuilt.length - 1, length: 1))
        }
        view.pPerformStorageEdit { storage in
            storage.beginEditing()
            storage.replaceCharacters(in: span, with: rebuilt)
            storage.endEditing()
        }
        view.pSelectedRange = NSRange(location: min(span.location, storage.length), length: 0)
        rebuildHiddenRanges(previous: hiddenBefore)
        registerUndo(from: undo, actionName: "Move Checked to Bottom")
        scheduleSave()
    }

    func deleteCheckedItems() {
        guard let view, let storage = view.pStorage, storage.length > 0 else { return }
        let caret = min(view.pSelectedRange.location, storage.length)
        guard let (span, units) = todoRun(around: caret, in: storage) else { return }
        let ticked = units.filter { $0.checked }
        guard !ticked.isEmpty else { return }
        let undo = undoSnapshot()
        let hiddenBefore = folding.hiddenRanges
        view.pPerformStorageEdit { storage in
            storage.beginEditing()
            for unit in ticked.reversed() {
                var range = unit.range
                // a final paragraph carries no newline of its own; deleting it
                // must take the one that ended the paragraph before it
                if NSMaxRange(range) >= storage.length, range.location > 0,
                   !(storage.string as NSString).hasSuffix("\n") {
                    range = NSRange(
                        location: range.location - 1,
                        length: storage.length - range.location + 1
                    )
                }
                storage.replaceCharacters(in: range, with: NSAttributedString())
            }
            storage.endEditing()
        }
        view.pSelectedRange = NSRange(location: min(span.location, storage.length), length: 0)
        rebuildHiddenRanges(previous: hiddenBefore)
        registerUndo(from: undo, actionName: "Delete Checked Items")
        scheduleSave()
    }

    /// Ticked items collapse to nothing in layout only — the doc keeps them.
    func toggleHideCheckedItems() {
        folding.hideCheckedTodos.toggle()
        controller.checkedItemsHidden = folding.hideCheckedTodos
        rebuildHiddenRanges()
    }

    private func endSeparatorAttributes(in storage: NSTextStorage) -> [NSAttributedString.Key: Any] {
        let attrs = storage.attributes(at: storage.length - 1, effectiveRange: nil)
        if attrs[.attachment] != nil || attrs[.amTableBox] != nil || attrs[.amColumnsBox] != nil {
            return RichText.attributes(block: .paragraph, marks: [:])
        }
        return attrs
    }

    // MARK: multicursor

    /// ⌘D: no selection selects the caret's word; with one, adds the next
    /// occurrence as another selection range. Typing edits every range.
    func selectNextOccurrence() {
        guard let view, let storage = view.pStorage, storage.length > 0 else { return }
        let str = storage.string as NSString
        var ranges = view.pSelectedRanges.filter { $0.length > 0 }
        if ranges.isEmpty {
            guard let word = wordRange(at: view.pSelectedRange.location, in: str) else { return }
            view.pSelectedRanges = [word]
            return
        }
        guard let last = ranges.max(by: { $0.location < $1.location }) else { return }
        let needle = str.substring(with: last)
        guard !needle.isEmpty else { return }
        let taken = Set(ranges.map { "\($0.location):\($0.length)" })
        var searchFrom = NSMaxRange(last)
        for _ in 0..<2 {
            let scope = NSRange(location: searchFrom, length: str.length - searchFrom)
            let found = str.range(of: needle, options: [], range: scope)
            if found.location != NSNotFound, !taken.contains("\(found.location):\(found.length)") {
                ranges.append(found)
                ranges.sort { $0.location < $1.location }
                #if os(macOS)
                view.pSelectedRanges = ranges
                #else
                view.pSelectedRange = found
                #endif
                view.pScrollRangeToVisible(found)
                return
            }
            searchFrom = 0
        }
    }

    func addCaret(at index: Int) {
        guard let view, let storage = view.pStorage else { return }
        var ranges = view.pSelectedRanges
        let caret = NSRange(location: min(max(0, index), storage.length), length: 0)
        guard !ranges.contains(caret) else { return }
        ranges.append(caret)
        ranges.sort { $0.location < $1.location }
        view.pSelectedRanges = ranges
    }

    private func wordRange(at index: Int, in str: NSString) -> NSRange? {
        guard str.length > 0 else { return nil }
        let clamped = min(max(0, index), str.length - 1)
        let paragraph = str.paragraphRange(for: NSRange(location: clamped, length: 0))
        var result: NSRange?
        str.enumerateSubstrings(in: paragraph, options: .byWords) { _, wordRange, _, stop in
            if NSLocationInRange(clamped, wordRange) || wordRange.location > clamped {
                result = wordRange
                stop.pointee = true
            }
        }
        return result
    }

    // MARK: scratchpad

    /// Cut the selected paragraphs out of the note and hand back their spans
    /// for a pad to keep. Nothing is left behind: the pad holds the text now.
    func cutSelectionToPad() -> [SpanNode]? {
        guard let view, let storage = view.pStorage, storage.length > 0 else { return nil }
        let str = storage.string as NSString
        let selection = view.pSelectedRange
        guard selection.location < storage.length else { return nil }
        let end = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
        let first = str.paragraphRange(for: NSRange(location: selection.location, length: 0))
        let last = str.paragraphRange(for: NSRange(location: min(end, storage.length - 1), length: 0))
        var range = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        guard range.length > 0 else { return nil }
        // an atomic block is a thing, not a paragraph — take it whole or not at all
        var takeable = true
        storage.enumerateAttribute(.amBlock, in: range) { value, _, _ in
            if let box = value as? BlockBox, box.value.isAtomic, selection.length == 0 {
                takeable = false
            }
        }
        guard takeable else { return nil }
        let slice = storage.attributedSubstring(from: range)
        let spans = RichText.spans(from: slice)
        guard !spans.isEmpty else { return nil }
        let undo = undoSnapshot()
        let hiddenBefore = folding.hiddenRanges
        // the note keeps a paragraph where the text was when it would
        // otherwise end up with none at all
        let replacement = NSMutableAttributedString()
        if range.location == 0, NSMaxRange(range) >= storage.length {
            replacement.append(NSAttributedString(
                string: "\n",
                attributes: RichText.attributes(block: .paragraph, marks: [:])
            ))
        } else if NSMaxRange(range) >= storage.length, range.location > 0 {
            range = NSRange(location: range.location - 1, length: range.length + 1)
        }
        view.pPerformStorageEdit { storage in
            storage.replaceCharacters(in: range, with: replacement)
        }
        view.pSelectedRange = NSRange(location: min(range.location, storage.length), length: 0)
        rebuildHiddenRanges(previous: hiddenBefore)
        registerUndo(from: undo, actionName: "Send to Scratchpad")
        scheduleSave()
        controller.padded &+= 1
        return spans
    }

    /// Cut the selection out of the note and park it on a pad, making the pad
    /// if this is the first thing to land on it.
    func sendSelectionToPad(pocket: Bool) {
        guard let spans = cutSelectionToPad() else { return }
        controller.paddedPocket = pocket
        let store = model.pads
        let noteUrl = self.noteUrl
        Task { @MainActor in
            let pad = pocket
                ? await store.ensurePocketPad()
                : await store.ensureNotePad(for: noteUrl)
            guard let pad else { return }
            store.add(store.textItem(spans: spans, origin: noteUrl, in: pad), to: pad)
        }
    }

    /// Put a card's text back in the note: at a drop point, or at the caret.
    func insertPadSpans(_ spans: [SpanNode], at dropIndex: Int?) {
        guard let view = noteView, let storage = view.pStorage, !spans.isEmpty else { return }
        let slice = NSMutableAttributedString(
            attributedString: RichText.attributed(from: spans, cache: cache)
        )
        guard slice.length > 0 else { return }
        if !slice.string.hasSuffix("\n") {
            let tail = slice.attributes(at: slice.length - 1, effectiveRange: nil)
            slice.append(NSAttributedString(string: "\n", attributes: tail))
        }
        let str = storage.string as NSString
        let caret = dropIndex ?? view.pSelectedRange.location
        let target = str.paragraphRange(
            for: NSRange(location: min(caret, max(0, storage.length - 1)), length: 0)
        ).location
        let undo = undoSnapshot()
        let hiddenBefore = folding.hiddenRanges
        view.pPerformStorageEdit { storage in
            storage.insert(slice, at: min(target, storage.length))
        }
        view.pSelectedRange = NSRange(location: min(target + slice.length, storage.length), length: 0)
        rebuildHiddenRanges(previous: hiddenBefore)
        registerUndo(from: undo, actionName: "Put Back in Note")
        scheduleSave()
    }

    /// Run an editing command against whatever text has focus. A pad card
    /// holds its own copy of the text it parks, so the command runs on that
    /// copy and the result goes back to the pad.
    func onFocusedText(_ body: (EditorCore) -> Void) {
        guard let card = focusedPadCard, card !== view else {
            body(self)
            return
        }
        let note = view
        view = card
        body(self)
        view = note
        card.scheduleCommit()
    }

    // MARK: minimap

    private var minimapUpdateScheduled = false

    func scheduleMinimapUpdate() {
        guard !minimapUpdateScheduled else { return }
        minimapUpdateScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.minimapUpdateScheduled = false
            self?.updateMinimap()
        }
    }

    func updateMinimap() {
        guard EditorSettings.minimapVisible else {
            if !controller.minimapRows.isEmpty { controller.minimapRows = [] }
            return
        }
        guard let view, let textLayoutManager = view.pTextLayoutManager else { return }
        var rows: [MinimapRow] = []
        let documentRange = textLayoutManager.documentRange
        textLayoutManager.enumerateTextLayoutFragments(from: nil, options: [.estimatesSize]) { fragment in
            let frame = fragment.layoutFragmentFrame
            var kind = MinimapKind.text
            if let paragraph = fragment.textElement as? NSTextParagraph,
               let elementRange = paragraph.elementRange,
               documentRange.contains(elementRange),
               paragraph.attributedString.length > 0 {
                let attrs = paragraph.attributedString.attributes(at: 0, effectiveRange: nil)
                if let box = attrs[.amBlock] as? BlockBox {
                    switch box.value.type {
                    case "heading": kind = .heading
                    case "code-block": kind = .code
                    case "blockquote": kind = .quote
                    default: kind = box.value.isAtomic ? .embed : .text
                    }
                } else if attrs[.attachment] != nil {
                    kind = .embed
                }
            }
            rows.append(MinimapRow(id: rows.count, y: frame.minY, height: frame.height, kind: kind))
            return true
        }
        controller.minimapRows = rows
        controller.minimapDocHeight = rows.last.map { $0.y + $0.height } ?? 0
        updateMinimapViewport()
    }

    func updateMinimapViewport() {
        guard let view else { return }
        let visible = view.pVisibleRect
        let viewport = MinimapViewport(y: visible.minY, height: visible.height)
        if controller.minimapViewport != viewport {
            controller.minimapViewport = viewport
        }
    }

    func scrollToFraction(_ fraction: CGFloat) {
        guard let view, controller.minimapDocHeight > 0 else { return }
        let clamped = min(max(fraction, 0), 1)
        view.pScrollToY(clamped * controller.minimapDocHeight - view.pVisibleRect.height / 2)
    }

    // MARK: find

    func updateFindMatches(resetIndex: Bool = true) {
        guard let view, let storage = view.pStorage else { return }
        let query = controller.findQuery
        let previousMatches = rendering.findMatches
        let previousCurrent = rendering.currentFindMatch
        rendering.findMatches = controller.findVisible && !query.isEmpty
            ? allRanges(of: query, in: storage.string)
            : []
        controller.findMatchCount = rendering.findMatches.count
        if resetIndex || rendering.findMatches.isEmpty {
            controller.findIndex = rendering.findMatches.isEmpty ? 0 : 1
        } else if let previousCurrent {
            // edits shift ranges under the ordinal; re-anchor to the nearest
            // occurrence instead of keeping a drifted index
            let nearest = rendering.findMatches.firstIndex { $0.location >= previousCurrent.location }
            controller.findIndex = (nearest ?? rendering.findMatches.count - 1) + 1
        } else if controller.findIndex > controller.findMatchCount || controller.findIndex < 1 {
            controller.findIndex = 1
        }
        rendering.currentFindMatch = currentFindRange
        invalidateRendering(
            ranges: previousMatches + rendering.findMatches
                + [previousCurrent, rendering.currentFindMatch].compactMap { $0 }
        )
        if resetIndex, let current = currentFindRange {
            view.pScrollRangeToVisible(current)
        }
    }

    func stepFind(_ delta: Int) {
        let count = rendering.findMatches.count
        guard count > 0 else { return }
        var index = controller.findIndex + delta
        if index < 1 { index = count }
        if index > count { index = 1 }
        controller.findIndex = index
        let previous = rendering.currentFindMatch
        rendering.currentFindMatch = currentFindRange
        invalidateRendering(ranges: [previous, rendering.currentFindMatch].compactMap { $0 })
        if let current = currentFindRange, let view {
            view.pSelectedRange = current
            view.pScrollRangeToVisible(current)
        }
    }

    func replaceCurrentFind(with replacement: String) {
        guard let view, let storage = view.pStorage, let range = currentFindRange else { return }
        let undo = undoSnapshot()
        let attributes = range.location < storage.length
            ? storage.attributes(at: range.location, effectiveRange: nil)
            : view.pTypingAttributes
        view.pPerformStorageEdit { storage in
            storage.replaceCharacters(
                in: range,
                with: NSAttributedString(string: replacement, attributes: attributes)
            )
        }
        view.pSelectedRange = NSRange(location: range.location, length: (replacement as NSString).length)
        registerUndo(from: undo, actionName: "Replace")
        scheduleSave()
        updateFindMatches(resetIndex: false)
    }

    func replaceAllFind(with replacement: String) {
        guard let view, view.pStorage != nil else { return }
        let ranges = rendering.findMatches
        guard !ranges.isEmpty else { return }
        let undo = undoSnapshot()
        view.pPerformStorageEdit { storage in
            for range in ranges.reversed() {
                let attributes = range.location < storage.length
                    ? storage.attributes(at: range.location, effectiveRange: nil)
                    : view.pTypingAttributes
                storage.replaceCharacters(
                    in: range,
                    with: NSAttributedString(string: replacement, attributes: attributes)
                )
            }
        }
        registerUndo(from: undo, actionName: "Replace All")
        scheduleSave()
        updateFindMatches()
    }

    private var currentFindRange: NSRange? {
        let index = controller.findIndex
        guard index >= 1, index <= rendering.findMatches.count else { return nil }
        return rendering.findMatches[index - 1]
    }

    func updateGlobalMatches() {
        guard let storage = view?.pStorage else { return }
        let query = model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = rendering.globalMatches
        rendering.globalMatches = query.count >= 2
            ? allRanges(of: query, in: storage.string)
            : []
        invalidateRendering(ranges: previous + rendering.globalMatches)
    }

    private func allRanges(of query: String, in text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        var location = 0
        while location < ns.length {
            let match = ns.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: NSRange(location: location, length: ns.length - location)
            )
            guard match.location != NSNotFound, match.length > 0 else { break }
            out.append(match)
            location = NSMaxRange(match)
        }
        return out
    }

    private func invalidateRendering() {
        guard let textLayoutManager = view?.pTextLayoutManager else { return }
        textLayoutManager.invalidateRenderingAttributes(for: textLayoutManager.documentRange)
        renderInvalidated()
    }

    /// Invalidating only marks attributes stale — the validator doesn't run
    /// until the viewport lays out again, so a match painted while typing
    /// stays invisible until some other edit forces a pass.
    private func renderInvalidated() {
        view?.pTextLayoutManager?.textViewportLayoutController.layoutViewport()
        refreshEditorDisplay()
    }

    private func invalidateRendering(ranges: [NSRange]) {
        guard !ranges.isEmpty else { return }
        guard ranges.count <= 200 else {
            invalidateRendering()
            return
        }
        guard let textLayoutManager = view?.pTextLayoutManager,
              let contentManager = textLayoutManager.textContentManager,
              let storage = view?.pStorage
        else { return }
        let bounds = NSRange(location: 0, length: storage.length)
        for range in ranges {
            let clipped = NSIntersectionRange(range, bounds)
            guard clipped.length > 0,
                  let textRange = contentManager.textRange(for: clipped)
            else { continue }
            textLayoutManager.invalidateRenderingAttributes(for: textRange)
        }
        renderInvalidated()
    }

    // MARK: formatting

    private func refreshEditorDisplay() {
        guard let view else { return }
        #if os(macOS)
        view.pSelf.needsDisplay = true
        #else
        view.pSelf.setNeedsDisplay()
        #endif
    }

    func refreshFormattingState() {
        guard let view else { return }
        var typing = view.pTypingAttributes
        if typing[.amTableBox] != nil || typing[.amColumnsBox] != nil
            || typing[.attachment] != nil
            || (typing[.amBlock] as? BlockBox)?.value.isAtomic == true {
            // typing next to an attachment must never inherit its attributes,
            // or the typed text would vanish into the atomic block on save
            view.pTypingAttributes = RichText.attributes(block: .paragraph, marks: [:])
        } else if typing[.amDisplayOnly] != nil {
            typing.removeValue(forKey: .amDisplayOnly)
            view.pTypingAttributes = typing
        }
        #if os(iOS)
        // iOS strips custom typing attributes on selection changes; text
        // typed without .amBlock breaks its paragraph's list rendering.
        // AppKit preserves them, and rebuilding attributes mid-edit on macOS
        // interferes with block conversions (bullets vanishing on indent).
        if view.pTypingAttributes[.amBlock] == nil, view.pStorage?.length ?? 0 > 0 {
            view.pTypingAttributes = RichText.attributes(
                block: blockAtSelection(),
                marks: marksAtSelection()
            )
        }
        #endif
        let block = blockAtSelection()
        controller.currentStyleKey = block.styleKey
        controller.currentCodeLanguage = block.codeLanguage
        // With a caret, the buttons must show what the next typed character
        // will be — that's the typing attributes, not the character behind it.
        let marks = view.pSelectedRange.length > 0
            ? marksAtSelection()
            : RichText.marks(from: view.pTypingAttributes, block: block)
        controller.strongActive = marks["strong"] != nil
        controller.emActive = marks["em"] != nil
        controller.codeActive = marks["code"] != nil
        controller.underlineActive = marks["underline"] != nil
        controller.strikethroughActive = marks["strikethrough"] != nil
        controller.superscriptActive = marks["superscript"] != nil
        controller.subscriptActive = marks["subscript"] != nil
        controller.highlightActive = marks["highlight"]?.stringValue
        controller.fontRoleActive = marks["font"]?.stringValue
        controller.linkActive = marks["link"]?.stringValue
        refreshTrailingMarker()
        unfoldIfCaretHidden()
        broadcastCaret()
        redrawCodeSelection()
    }

    /// Code cards paint over the selection, so the fragments redraw it —
    /// which only happens if the run they cover is invalidated.
    private func redrawCodeSelection() {
        guard let view,
              let textLayoutManager = view.pTextLayoutManager,
              let storage = view.pStorage
        else { return }
        let selection = view.pSelectedRange
        let previous = lastCodeSelection
        lastCodeSelection = selection
        guard previous.length > 0 || selection.length > 0 else { return }
        for location in [previous.location, NSMaxRange(previous), selection.location, NSMaxRange(selection)] {
            invalidateCodeRun(around: location, textLayoutManager: textLayoutManager, storage: storage)
        }
    }

    private func marksAtSelection() -> [String: JSONValue] {
        guard let view else { return [:] }
        let selection = view.pSelectedRange
        let block = blockAtSelection()
        if let storage = view.pStorage, storage.length > 0,
           selection.location > 0 || selection.length > 0 {
            let index = selection.length > 0
                ? min(selection.location, storage.length - 1)
                : min(selection.location - 1, storage.length - 1)
            return RichText.marks(
                from: storage.attributes(at: index, effectiveRange: nil),
                block: block
            )
        }
        return RichText.marks(from: view.pTypingAttributes, block: block)
    }

    /// What the format buttons show: with a caret that's the typing
    /// attributes, not the character behind it. Toggling has to read the same
    /// state it displays, or a mark set at a run boundary never turns back off.
    private func activeMarks() -> [String: JSONValue] {
        guard let view else { return [:] }
        if view.pSelectedRange.length > 0 { return marksAtSelection() }
        return RichText.marks(from: view.pTypingAttributes, block: blockAtSelection())
    }

    func blockAtSelection() -> BlockValue {
        guard let view, let storage = view.pStorage else { return .paragraph }
        let selection = view.pSelectedRange
        if storage.length == 0 { return typingBlock() }
        if selection.location >= storage.length {
            // Caret at the very end. Unless the doc ends with a newline (an
            // empty final paragraph, where only typing attributes exist), the
            // caret is inside the last paragraph — read its block from the
            // text, not from typing attributes, which iOS likes to strip.
            if (storage.string as NSString).hasSuffix("\n") {
                return typingBlock()
            }
            if let box = storage.attribute(.amBlock, at: storage.length - 1, effectiveRange: nil) as? BlockBox {
                return box.value
            }
            return typingBlock()
        }
        let index = min(selection.location, storage.length - 1)
        if let box = storage.attribute(.amBlock, at: index, effectiveRange: nil) as? BlockBox {
            return box.value
        }
        return typingBlock()
    }

    private func typingBlock(in target: (any EditorTextViewLike)? = nil) -> BlockValue {
        guard let view = target ?? view,
              let box = view.pTypingAttributes[.amBlock] as? BlockBox else {
            return .paragraph
        }
        return box.value
    }

    private struct UndoSnapshot {
        let attributed: NSAttributedString
        let selection: NSRange
        let typingAttributes: [NSAttributedString.Key: Any]
    }

    private func undoSnapshot(of target: (any EditorTextViewLike)? = nil) -> UndoSnapshot? {
        guard let view = target ?? view, let storage = view.pStorage else { return nil }
        return UndoSnapshot(
            attributed: NSAttributedString(attributedString: storage),
            selection: view.pSelectedRange,
            typingAttributes: view.pTypingAttributes
        )
    }

    /// The view is carried along: a snapshot taken in a pad card must not be
    /// restored into the note when the caret has moved on.
    private func restoreUndoSnapshot(
        _ snapshot: UndoSnapshot,
        actionName: String,
        in view: any EditorTextViewLike
    ) {
        guard let current = undoSnapshot(of: view) else { return }
        view.pUndoManager?.registerUndo(withTarget: self) { [weak view] target in
            guard let view else { return }
            target.restoreUndoSnapshot(current, actionName: actionName, in: view)
        }
        view.pUndoManager?.setActionName(actionName)
        view.pPerformStorageEdit { storage in
            storage.setAttributedString(snapshot.attributed)
        }
        let location = min(snapshot.selection.location, snapshot.attributed.length)
        view.pSelectedRange = NSRange(
            location: location,
            length: min(snapshot.selection.length, snapshot.attributed.length - location)
        )
        view.pTypingAttributes = snapshot.typingAttributes
        refreshFormattingState()
        updateGlobalMatches()
        scheduleMinimapUpdate()
        refreshEditorDisplay()
        if let card = view as? any PadCardEditing {
            card.commit()
        } else {
            scheduleSave()
        }
    }

    private func registerUndo(from before: UndoSnapshot?, actionName: String) {
        guard let view,
              let before,
              view.pUndoManager?.isUndoing != true,
              view.pUndoManager?.isRedoing != true
        else { return }
        view.pUndoManager?.registerUndo(withTarget: self) { [weak view] target in
            guard let view else { return }
            target.restoreUndoSnapshot(before, actionName: actionName, in: view)
        }
        view.pUndoManager?.setActionName(actionName)
    }

    /// The character in a to-do item whose box sits under this point in the
    /// text container — the marker gutter is the indent the item's own
    /// paragraph style asks for.
    func todoBoxHit(at point: CGPoint) -> Int? {
        guard let storage = view?.pStorage, storage.length > 0,
              let rawIndex = view?.pCharacterIndex(atTextContainerPoint: point)
        else { return nil }
        let index = min(max(rawIndex, 0), storage.length - 1)
        guard index >= 0,
              let style = storage.attribute(.paragraphStyle, at: index, effectiveRange: nil)
                as? NSParagraphStyle,
              point.x >= 0, point.x < style.firstLineHeadIndent,
              let box = storage.attribute(.amBlock, at: index, effectiveRange: nil) as? BlockBox,
              box.value.type == "todo-list-item"
        else { return nil }
        return index
    }

    /// A click on a calendar box: its trailing glyph opens Calendar.app, the
    /// rest of the box goes to that day in Lush's own Calendar view.
    @discardableResult
    func calendarEmbedHit(at point: CGPoint) -> Bool {
        guard let storage = view?.pStorage,
              let charIndex = attachmentIndex(at: point),
              let box = storage.attribute(.amBlock, at: charIndex, effectiveRange: nil) as? BlockBox,
              box.value.type == "calendar-event"
        else { return false }
        let attachment = storage.attribute(.attachment, at: charIndex, effectiveRange: nil) as? NSTextAttachment
        let ideal = attachment?.bounds.width ?? 420
        let padding = view?.pTextContainer?.lineFragmentPadding ?? 5
        let available = (view?.pTextContainer?.size.width ?? ideal) - padding * 2
        let width = available > 40 ? min(ideal, available) : ideal
        let zone = CalendarEventInlineView.buttonZone * width / max(ideal, 1)
        let value = box.value
        if point.x >= padding + width - zone {
            Task { @MainActor in
                if await value.openExternally() { return }
                AppRouter.shared.pending = .calendar(
                    day: value.calendarEventDay,
                    item: value.attrs["event"]?.stringValue
                )
            }
            return true
        }
        AppRouter.shared.pending = .calendar(
            day: value.calendarEventDay,
            item: value.attrs["event"]?.stringValue
        )
        return true
    }

    /// The attachment character whose laid-out rect contains this point in
    /// the text container.
    func attachmentIndex(at point: CGPoint) -> Int? {
        guard let storage = view?.pStorage, storage.length > 0 else { return nil }
        let index = view?.pCharacterIndex(atTextContainerPoint: point) ?? NSNotFound
        for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
            if storage.attribute(.attachment, at: candidate, effectiveRange: nil) != nil {
                return candidate
            }
        }
        return nil
    }

    /// The trailing empty line's marker comes from typing attributes, which
    /// leave no trace in the storage — redraw the last fragment whenever they
    /// may have changed.
    func refreshTrailingMarker() {
        guard let view, let storage = view.pStorage, storage.length > 0,
              (storage.string as NSString).hasSuffix("\n"),
              let textLayoutManager = view.pTextLayoutManager,
              let contentManager = textLayoutManager.textContentManager
        else { return }
        let str = storage.string as NSString
        let last = str.paragraphRange(for: NSRange(location: storage.length - 1, length: 0))
        guard let textRange = contentManager.textRange(for: last) else { return }
        textLayoutManager.invalidateLayout(for: textRange)
    }

    /// Tick or untick the to-do item containing a character. Returns false
    /// when that character isn't in one, so a click can fall through.
    @discardableResult
    func toggleTodo(at character: Int) -> Bool {
        guard let state = todoState(at: character) else { return false }
        return setTodoState(state == .open ? .checked : .open, at: character)
    }

    func todoState(at character: Int) -> TodoState? {
        guard let storage = view?.pStorage, character >= 0, character < storage.length else { return nil }
        let str = storage.string as NSString
        let paragraph = str.paragraphRange(for: NSRange(location: character, length: 0))
        guard paragraph.length > 0,
              let box = storage.attribute(.amBlock, at: paragraph.location, effectiveRange: nil) as? BlockBox,
              box.value.type == "todo-list-item"
        else { return nil }
        return box.value.todoState
    }

    @discardableResult
    func setTodoState(_ state: TodoState, at character: Int) -> Bool {
        guard let view, let storage = view.pStorage, character < storage.length else { return false }
        let str = storage.string as NSString
        let paragraph = str.paragraphRange(for: NSRange(location: character, length: 0))
        guard paragraph.length > 0,
              let box = storage.attribute(.amBlock, at: paragraph.location, effectiveRange: nil) as? BlockBox,
              box.value.type == "todo-list-item"
        else { return false }
        let undo = undoSnapshot()
        var block = box.value
        block.setTodoState(state)
        let selection = view.pSelectedRange
        view.pPerformStorageEdit { storage in
            storage.beginEditing()
            storage.enumerateAttributes(in: paragraph) { runAttrs, runRange, _ in
                let marks = RichText.marks(from: runAttrs, block: box.value)
                storage.setAttributes(RichText.attributes(block: block, marks: marks), range: runRange)
            }
            storage.endEditing()
        }
        view.pSelectedRange = selection
        refreshFormattingState()
        registerUndo(from: undo, actionName: "Set To-do State")
        scheduleSave()
        return true
    }

    func applyBlockStyle(_ block: BlockValue) {
        guard let view, let storage = view.pStorage else { return }
        let undo = undoSnapshot()
        let str = storage.string as NSString
        let selection = view.pSelectedRange
        let newTypingAttributes = RichText.attributes(block: block, marks: [:])
        if storage.length == 0 {
            view.pTypingAttributes = newTypingAttributes
            refreshFormattingState()
            refreshEditorDisplay()
            registerUndo(from: undo, actionName: "Format Block")
            return
        }
        let paragraphRange = str.paragraphRange(for: selection)
        if paragraphRange.length > 0 {
            view.pPerformStorageEdit { storage in
                storage.beginEditing()
                storage.enumerateAttributes(in: paragraphRange) { runAttrs, runRange, _ in
                    let oldBlock = (runAttrs[.amBlock] as? BlockBox)?.value ?? .paragraph
                    guard !oldBlock.isAtomic, runAttrs[.amTableBox] == nil,
                          runAttrs[.amColumnsBox] == nil,
                          runAttrs[.attachment] == nil,
                          runAttrs[.amDisplayOnly] == nil else { return }
                    let marks = RichText.marks(from: runAttrs, block: oldBlock)
                    storage.setAttributes(
                        RichText.attributes(block: block, marks: marks),
                        range: runRange
                    )
                }
                storage.endEditing()
            }
        }
        view.pTypingAttributes = newTypingAttributes
        view.pSelectedRange = selection
        refreshFormattingState()
        registerUndo(from: undo, actionName: "Format Block")
        scheduleSave()
    }

    func toggleMark(_ mark: String) {
        let turningOn = activeMarks()[mark] == nil
        applyMark(mark, value: turningOn ? .bool(true) : nil)
    }

    func setHighlight(_ name: String?) {
        applyMark("highlight", value: name.map { .string($0) })
    }

    func setLink(_ url: String?) {
        if let view, view.pSelectedRange.length == 0, let range = linkRangeAtCaret() {
            view.pSelectedRange = range
        }
        applyMark("link", value: url.map { .string($0) })
    }

    private func linkRangeAtCaret() -> NSRange? {
        guard let view, let storage = view.pStorage, storage.length > 0 else { return nil }
        let caret = view.pSelectedRange.location
        let probe = min(caret, storage.length - 1)
        var range = NSRange(location: 0, length: 0)
        let whole = NSRange(location: 0, length: storage.length)
        guard storage.attribute(.link, at: probe, longestEffectiveRange: &range, in: whole) != nil
        else { return nil }
        return range
    }

    func setFontRole(_ role: String?) {
        applyMark("font", value: role.map { .string($0) })
    }

    func setCodeLanguage(_ language: String) {
        guard let view, let storage = view.pStorage else { return }
        let undo = undoSnapshot()
        let normalized = CodeLanguage.named(language).id
        let selection = view.pSelectedRange
        var block = blockAtSelection()
        guard block.type == "code-block" else { return }
        if normalized == CodeLanguage.plain.id {
            block.attrs.removeValue(forKey: "language")
        } else {
            block.attrs["language"] = .string(normalized)
        }
        let newTypingAttributes = RichText.attributes(block: block, marks: [:])
        if storage.length == 0 {
            view.pTypingAttributes = newTypingAttributes
            controller.currentCodeLanguage = normalized
            refreshFormattingState()
            refreshEditorDisplay()
            registerUndo(from: undo, actionName: "Set Code Language")
            return
        }
        let str = storage.string as NSString
        // the whole visual block, not just the caret's line
        let run = CodeHighlight.codeRun(
            containing: str.paragraphRange(for: selection),
            language: nil,
            in: storage,
            str: str
        )
        view.pPerformStorageEdit { storage in
            storage.beginEditing()
            storage.enumerateAttributes(in: run) { runAttrs, runRange, _ in
                guard var oldBlock = (runAttrs[.amBlock] as? BlockBox)?.value,
                      oldBlock.type == "code-block"
                else { return }
                if normalized == CodeLanguage.plain.id {
                    oldBlock.attrs.removeValue(forKey: "language")
                } else {
                    oldBlock.attrs["language"] = .string(normalized)
                }
                let marks = RichText.marks(from: runAttrs, block: oldBlock)
                storage.setAttributes(RichText.attributes(block: oldBlock, marks: marks), range: runRange)
            }
            storage.endEditing()
        }
        view.pTypingAttributes = newTypingAttributes
        view.pSelectedRange = selection
        controller.currentCodeLanguage = normalized
        refreshFormattingState()
        registerUndo(from: undo, actionName: "Set Code Language")
        scheduleSave()
    }

    /// Superscript and subscript are one axis: turning one on turns the other
    /// off, since text can only sit on one baseline.
    func toggleBaseline(_ mark: String) {
        let other = mark == "superscript" ? "subscript" : "superscript"
        let currentMarks = activeMarks()
        let turningOn = currentMarks[mark] == nil
        // Clearing the other baseline unconditionally: a selection spanning
        // mixed runs can carry it even when the read at its start doesn't.
        let groupsSwap = turningOn
        if groupsSwap {
            view?.pUndoManager?.beginUndoGrouping()
        }
        defer {
            if groupsSwap {
                view?.pUndoManager?.endUndoGrouping()
                view?.pUndoManager?.setActionName("Format Text")
            }
        }
        if groupsSwap {
            applyMark(other, value: nil)
        }
        applyMark(mark, value: turningOn ? .bool(true) : nil)
    }

    private func applyMark(_ mark: String, value: JSONValue?) {
        guard session.loaded, let view, let storage = view.pStorage else { return }
        let undo = undoSnapshot()
        let selection = view.pSelectedRange
        if selection.length == 0 {
            let block = typingBlock()
            var marks = RichText.marks(from: view.pTypingAttributes, block: block)
            marks[mark] = value
            view.pTypingAttributes = RichText.attributes(block: block, marks: marks)
            refreshFormattingState()
            registerUndo(from: undo, actionName: "Format Text")
            return
        }
        let prepared = prepareTextMark(range: selection, value: value)
        view.pPerformStorageEdit { storage in
            storage.beginEditing()
            storage.enumerateAttributes(in: selection) { runAttrs, runRange, _ in
                let block = (runAttrs[.amBlock] as? BlockBox)?.value ?? .paragraph
                guard !block.isAtomic, runAttrs[.amTableBox] == nil,
                      runAttrs[.amColumnsBox] == nil else { return }
                var marks = RichText.marks(from: runAttrs, block: block)
                marks[mark] = value
                var newAttrs = RichText.attributes(block: block, marks: marks)
                if mark != "link", let link = runAttrs[.link], marks["link"] == nil {
                    newAttrs[.link] = link
                }
                storage.setAttributes(newAttrs, range: runRange)
            }
            storage.endEditing()
        }
        view.pSelectedRange = selection
        refreshFormattingState()
        registerUndo(from: undo, actionName: "Format Text")
        guard let prepared else {
            scheduleSave()
            return
        }
        let typing = typingBlock()
        let spans = RichText.spans(from: storage, trailingBlock: typing.isAtomic ? nil : typing)
        let json = SpanNode.encodeList(spans)
        let previousJSON = session.lastKnownJSON
        let previousEmbeds = session.lastKnownEmbeds
        session.lastKnownJSON = json
        session.lastKnownEmbeds = embedCount(in: spans)
        let title = RichText.title(from: spans)
        let url = noteUrl
        let heads = session.heads
        let previousHeadsTask = localWriteHeadsTask
        beginLocalWrite()
        let task = Task { [weak self] () -> [String]? in
            let chainedHeads = await previousHeadsTask?.value
            guard let self else { return nil }
            defer { self.finishLocalWrite(for: url) }
            let writeHeads = chainedHeads ?? heads
            let newHeads = await self.model.applyNoteMark(
                url,
                start: prepared.start,
                end: prepared.end,
                name: mark,
                valueJson: prepared.valueJson,
                title: title,
                spansJson: json,
                heads: writeHeads,
                origin: self.noteObserverId
            )
            guard let newHeads else {
                // the optimistic lastKnownJSON would make the fallback push a
                // no-op; roll it back so pushNow sees the difference
                let session = EditorDocumentSessions.session(for: url)
                if session.lastKnownJSON == json {
                    session.lastKnownJSON = previousJSON
                    session.lastKnownEmbeds = previousEmbeds
                }
                if self.noteUrl == url { self.scheduleSave() }
                return nil
            }
            // the note may have switched mid-flight; the heads belong to the
            // written note's session either way
            EditorDocumentSessions.session(for: url).heads = newHeads
            return newHeads
        }
        localWriteHeadsTask = task
    }

    /// Custom Return behavior. Returns true when handled.
    func handleReturn() -> Bool {
        guard let view, let storage = view.pStorage else { return false }
        let block = blockAtSelection()
        let str = storage.string as NSString
        let paragraph = str.paragraphRange(for: view.pSelectedRange)
        let paragraphText = (paragraph.length > 0 ? str.substring(with: paragraph) : "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if block.type == "code-block" {
            insertParagraphBreak(currentBlock: block, nextBlock: block)
            return true
        }
        if let blockquotePath = block.blockquotePath {
            if paragraphText.isEmpty {
                applyBlockStyle(BlockValue(type: "paragraph", parents: Array(blockquotePath.dropLast())))
                return true
            }
            let nextBlock = block.type == "blockquote"
                ? BlockValue(type: "paragraph", parents: blockquotePath)
                : block
            insertParagraphBreak(currentBlock: block, nextBlock: nextBlock)
            return true
        }
        if block.type == "paragraph" || block.type == "serif" || block.type == "hand" {
            insertParagraphBreak(currentBlock: block, nextBlock: block)
            return true
        }
        let continuing = block.type == "unordered-list-item"
            || block.type == "ordered-list-item"
            || block.type == "todo-list-item"
            || block.type == "blockquote"
        if continuing, paragraphText.isEmpty {
            // Return on an empty continuing block leaves it, like Notes.
            applyBlockStyle(.paragraph)
            return true
        }
        // A new to-do starts unticked, however the one above it stands.
        if block.type == "todo-list-item" {
            insertParagraphBreak(currentBlock: block, nextBlock: .todo(checked: false))
            return true
        }
        if block.type == "context" || block.type == "calendar-event" {
            let selection = view.pSelectedRange
            let paragraphStart = paragraph.location
            if selection.length == 0 && selection.location == paragraphStart {
                view.pPerformStorageEdit { storage in
                    storage.insert(
                        NSAttributedString(
                            string: "\n",
                            attributes: RichText.attributes(block: .paragraph, marks: [:])
                        ),
                        at: paragraphStart
                    )
                }
                view.pSelectedRange = NSRange(location: paragraphStart, length: 0)
                view.pTypingAttributes = RichText.attributes(block: .paragraph, marks: [:])
                refreshFormattingState()
                scheduleSave()
            } else {
                insertParagraphBreak(currentBlock: block, nextBlock: .paragraph)
            }
            return true
        }
        if block.type == "heading" || block.isAtomic {
            insertParagraphBreak(currentBlock: block, nextBlock: .paragraph)
            return true
        }
        // paragraphs and lists continue their block. On iOS, UITextView does
        // not reliably carry custom block attributes across paragraph
        // boundaries when it handles the newline internally.
        #if os(iOS)
        if continuing {
            insertParagraphBreak(currentBlock: block, nextBlock: block)
            return true
        }
        #endif
        return false
    }

    private func insertParagraphBreak(currentBlock: BlockValue, nextBlock: BlockValue) {
        guard let view else { return }
        view.pTypingAttributes = RichText.attributes(block: currentBlock, marks: [:])
        view.pInsertText("\n")
        view.pTypingAttributes = RichText.attributes(block: nextBlock, marks: [:])
        restyleCaretParagraph(as: nextBlock)
        refreshFormattingState()
    }

    func insertSoftLineBreak() {
        guard let view else { return }
        view.pInsertText(Self.softLineBreak)
        refreshFormattingState()
    }

    @discardableResult
    func moveToBlockquoteSoftLineBoundary(end: Bool) -> Bool {
        guard blockAtSelection().blockquotePath != nil,
              let view,
              let storage = view.pStorage,
              storage.length > 0
        else { return false }

        let selection = view.pSelectedRange
        let str = storage.string as NSString
        let anchor = min(max(selection.location, 0), storage.length - 1)
        let paragraph = str.paragraphRange(for: NSRange(location: anchor, length: 0))
        let contentEnd = paragraphContentEnd(in: str, paragraph: paragraph)
        let caret = min(max(selection.location, paragraph.location), contentEnd)
        let softBreak: unichar = 0x2028
        let target: Int

        if end {
            var cursor = caret
            target = {
                while cursor < contentEnd {
                    if str.character(at: cursor) == softBreak { return cursor }
                    cursor += 1
                }
                return contentEnd
            }()
        } else {
            var cursor = caret
            target = {
                while cursor > paragraph.location {
                    if str.character(at: cursor - 1) == softBreak { return cursor }
                    cursor -= 1
                }
                return paragraph.location
            }()
        }

        view.pSelectedRange = NSRange(location: target, length: 0)
        view.pScrollRangeToVisible(view.pSelectedRange)
        return true
    }

    func leaveCodeBlock() -> Bool {
        guard blockAtSelection().type == "code-block", let view else { return false }
        guard handleReturn() else { return false }
        applyBlockStyle(.paragraph)
        let paragraphAttributes = RichText.attributes(block: .paragraph, marks: [:])
        let newlineLocation = view.pSelectedRange.location - 1
        if let storage = view.pStorage,
           newlineLocation >= 0,
           newlineLocation < storage.length {
            view.pPerformStorageEdit { storage in
                storage.setAttributes(paragraphAttributes, range: NSRange(location: newlineLocation, length: 1))
            }
        }
        view.pTypingAttributes = paragraphAttributes
        refreshFormattingState()
        return true
    }

    /// After return splits a paragraph, the caret's new paragraph starts with
    /// the old one's terminator newline — which still carries the finished
    /// block's attributes (a ticked checkbox, a heading). Rebadge it.
    private func restyleCaretParagraph(as block: BlockValue) {
        guard let view, let storage = view.pStorage else { return }
        let caret = view.pSelectedRange.location
        guard caret <= storage.length else { return }
        let str = storage.string as NSString
        let paragraph = str.paragraphRange(for: NSRange(location: caret, length: 0))
        guard paragraph.length > 0 else { return }
        view.pPerformStorageEdit { storage in
            storage.beginEditing()
            storage.enumerateAttributes(in: paragraph) { runAttrs, runRange, _ in
                // never rewrite attachment runs — restyling would strip the
                // .attachment/table/columns attributes and delete the embed
                guard runAttrs[.attachment] == nil,
                      runAttrs[.amTableBox] == nil,
                      runAttrs[.amColumnsBox] == nil,
                      runAttrs[.amDisplayOnly] == nil
                else { return }
                let oldBlock = (runAttrs[.amBlock] as? BlockBox)?.value ?? .paragraph
                let marks = RichText.marks(from: runAttrs, block: oldBlock)
                storage.setAttributes(RichText.attributes(block: block, marks: marks), range: runRange)
            }
            storage.endEditing()
        }
    }

    /// Markdown-style prefixes: typing a space after `-`, `1.`, `#`…`###`
    /// or `>` at the start of a paragraph converts the block.
    func handleMarkdownTrigger(at location: Int) -> Bool {
        guard let view, let storage = view.pStorage else { return false }
        guard blockAtSelection().type != "code-block" else { return false }
        guard view.pSelectedRange.length == 0 else {
            NSLog("lush md-trigger: skipped, selection not empty")
            return false
        }
        let str = storage.string as NSString
        let paragraph = str.paragraphRange(for: NSRange(location: location, length: 0))
        guard location > paragraph.location else {
            NSLog("lush md-trigger: skipped, caret at paragraph start")
            return false
        }
        let prefixRange = NSRange(
            location: paragraph.location,
            length: location - paragraph.location
        )
        guard prefixRange.length <= 4 else { return false }
        let prefix = str.substring(with: prefixRange)
        let newBlock: BlockValue
        switch prefix {
        case "-", "*": newBlock = BlockValue(type: "unordered-list-item")
        case "[]", "[ ]": newBlock = .todo(state: .open)
        case "[x]", "[X]": newBlock = .todo(state: .checked)
        case "[-]": newBlock = .todo(state: .canceled)
        case "[/]": newBlock = .todo(state: .pending)
        case ">": newBlock = BlockValue(type: "blockquote")
        case "#": newBlock = .heading(level: 1)
        case "##": newBlock = .heading(level: 2)
        case "###": newBlock = .heading(level: 3)
        default:
            guard prefix.count >= 2, prefix.hasSuffix("."),
                  prefix.dropLast().allSatisfy(\.isNumber)
            else { return false }
            newBlock = BlockValue(type: "ordered-list-item")
        }
        view.pReplace(prefixRange, with: NSAttributedString(
            string: "",
            attributes: view.pTypingAttributes
        ))
        view.pSelectedRange = NSRange(location: paragraph.location, length: 0)
        applyBlockStyle(newBlock)
        return true
    }

    private static let nestableListTypes: Set<String> = [
        "unordered-list-item", "ordered-list-item", "todo-list-item",
    ]

    /// Tab in a list: increase indent by one level. Returns true when handled.
    @discardableResult
    func nestListItem() -> Bool {
        adjustListNesting(deeper: true)
    }

    /// Shift+Tab in a list: decrease indent by one level. Returns true when handled.
    @discardableResult
    func unnestListItem() -> Bool {
        adjustListNesting(deeper: false)
    }

    func indentBlock() {
        var block = blockAtSelection()
        switch block.type {
        case "unordered-list-item", "ordered-list-item", "todo-list-item":
            nestListItem()
        default:
            let level = block.indentLevel + 1
            block.attrs["indent"] = .int(Int64(level))
            applyBlockStyle(block)
        }
    }

    func outdentBlock() {
        var block = blockAtSelection()
        switch block.type {
        case "unordered-list-item", "ordered-list-item", "todo-list-item":
            if block.parents.isEmpty {
                applyBlockStyle(.paragraph)
            } else {
                unnestListItem()
            }
        default:
            let level = max(0, block.indentLevel - 1)
            if level == 0 {
                block.attrs.removeValue(forKey: "indent")
            } else {
                block.attrs["indent"] = .int(Int64(level))
            }
            applyBlockStyle(block)
        }
    }

    private func adjustListNesting(deeper: Bool) -> Bool {
        guard let view, let storage = view.pStorage else { return false }
        let selection = view.pSelectedRange
        if selection.length == 0 || storage.length == 0 {
            let block = blockAtSelection()
            guard Self.nestableListTypes.contains(block.type) else { return false }
            if !deeper, block.parents.isEmpty { return false }
            var adjusted = block
            if deeper {
                adjusted.parents.append(block.type)
            } else {
                adjusted.parents.removeLast()
            }
            applyBlockStyle(adjusted)
            return true
        }
        // a selection spanning paragraphs adjusts each item's own depth;
        // applyBlockStyle would flatten them all to the first item's block
        let str = storage.string as NSString
        let paragraphs = str.paragraphRange(for: selection)
        let undo = undoSnapshot()
        var changed = false
        view.pPerformStorageEdit { storage in
            storage.beginEditing()
            var location = paragraphs.location
            while location < NSMaxRange(paragraphs) {
                let paragraph = str.paragraphRange(for: NSRange(location: location, length: 0))
                if paragraph.length == 0 { break }
                location = NSMaxRange(paragraph)
                guard let box = storage.attribute(.amBlock, at: paragraph.location, effectiveRange: nil) as? BlockBox,
                      Self.nestableListTypes.contains(box.value.type)
                else { continue }
                var adjusted = box.value
                if deeper {
                    adjusted.parents.append(adjusted.type)
                } else {
                    guard !adjusted.parents.isEmpty else { continue }
                    adjusted.parents.removeLast()
                }
                storage.enumerateAttributes(in: paragraph) { runAttrs, runRange, _ in
                    guard runAttrs[.attachment] == nil,
                          runAttrs[.amTableBox] == nil,
                          runAttrs[.amColumnsBox] == nil,
                          runAttrs[.amDisplayOnly] == nil
                    else { return }
                    let marks = RichText.marks(from: runAttrs, block: box.value)
                    storage.setAttributes(RichText.attributes(block: adjusted, marks: marks), range: runRange)
                }
                changed = true
            }
            storage.endEditing()
        }
        guard changed else { return false }
        view.pSelectedRange = selection
        refreshFormattingState()
        registerUndo(from: undo, actionName: deeper ? "Indent" : "Outdent")
        scheduleSave()
        return true
    }

    // MARK: attachment interaction

    func isImageAttachment(at charIndex: Int) -> Bool {
        guard let storage = view?.pStorage, charIndex < storage.length,
              let box = storage.attributes(at: charIndex, effectiveRange: nil)[.amBlock] as? BlockBox,
              box.value.isEmbedBlock,
              let url = box.value.embedUrl
        else { return false }
        return cache.images[url] != nil
    }

    @discardableResult
    func openAttachment(at charIndex: Int, includeImages: Bool = true) -> Bool {
        guard let storage = view?.pStorage, charIndex < storage.length else { return false }
        let attrs = storage.attributes(at: charIndex, effectiveRange: nil)
        guard attrs[.amTableBox] == nil else { return false }
        guard let box = attrs[.amBlock] as? BlockBox, box.value.isEmbedBlock else { return false }
        let block = box.value
        if block.type == "html" {
            controller.sheet = .html(HtmlBlockHandle(box: box, html: block.htmlSource ?? ""))
            return true
        }
        guard let url = block.embedUrl else { return false }
        if let image = cache.images[url] {
            guard includeImages else { return false }
            controller.sheet = .info(
                assetUrl: url,
                name: cache.names[url] ?? "Image",
                image: image,
                block: box
            )
            return true
        }
        let name = cache.names[url] ?? "attachment"
        let kind = AssetCache.kind(forName: name)
        guard kind == "audio" || kind == "video" else { return false }
        Task { [weak self] in
            guard let self else { return }
            var fileURL = self.cache.fileURLs[url]
            if fileURL == nil, let data = await self.model.assetBytes(url) {
                fileURL = Self.mediaFile(for: url, name: name, data: data)
                self.cache.fileURLs[url] = fileURL
            }
            guard let fileURL else { return }
            self.controller.sheet = kind == "audio"
                ? .audio(assetUrl: url, fileURL: fileURL, name: name)
                : .video(fileURL: fileURL, name: name)
        }
        return true
    }

    func updateHtmlBlock(_ box: BlockBox, html: String) {
        guard let view, let storage = view.pStorage else { return }
        guard let range = range(whereBlockBox: box, in: storage) else { return }
        let undo = undoSnapshot()
        let newBlock = BlockValue.html(html)
        view.pPerformStorageEdit { storage in
            storage.replaceCharacters(
                in: range,
                with: RichText.embedAttachment(for: newBlock, cache: cache)
            )
        }
        registerUndo(from: undo, actionName: "Edit HTML")
        scheduleSave()
    }

    func removeEmbed(_ box: BlockBox) {
        guard let view, let storage = view.pStorage else { return }
        guard let range = range(whereBlockBox: box, in: storage) else { return }
        NSLog("lush embed removed by user: %@", box.value.embedUrl ?? "?")
        let undo = undoSnapshot()
        view.pPerformStorageEdit { storage in
            storage.replaceCharacters(in: range, with: NSAttributedString())
        }
        registerUndo(from: undo, actionName: "Remove Embed")
        scheduleSave()
    }

    func updateEmbedTool(_ box: BlockBox, tool: String?) {
        var newBlock = box.value
        if let tool, !tool.isEmpty {
            newBlock.attrs["tool"] = .string(tool)
        } else {
            newBlock.attrs["tool"] = nil
        }
        replaceEmbedBlock(box, with: newBlock)
    }

    func updateEmbedAltText(_ box: BlockBox, altText: String) {
        guard let view, let storage = view.pStorage,
              let range = range(whereBlockBox: box, in: storage)
        else { return }
        var newBlock = box.value
        newBlock.attrs["alt"] = altText.isEmpty ? nil : .string(altText)
        guard newBlock != box.value else { return }
        let undo = undoSnapshot()
        view.pPerformStorageEdit { storage in
            storage.replaceCharacters(
                in: range,
                with: RichText.embedAttachment(for: newBlock, cache: cache)
            )
        }
        registerUndo(from: undo, actionName: "Edit Alt Text")
        scheduleSave()
    }

    /// Mutates the box in place and re-measures so the hosted webview resizes
    /// live, exactly like a window resize — replacing the attachment would
    /// tear the webview down and boot a new one. The doc write happens once,
    /// when the drag ends.
    func updateEmbedSize(_ box: BlockBox, width: Double, height: Double, commit: Bool) {
        box.value.attrs["width"] = .number(width)
        box.value.attrs["height"] = .number(height)
        inline.embedChanged(box)
        if commit { scheduleSave() }
    }

    private func replaceEmbedBlock(_ box: BlockBox, with newBlock: BlockValue) {
        guard let view, let storage = view.pStorage else { return }
        guard let range = range(whereBlockBox: box, in: storage) else { return }
        view.pPerformStorageEdit { storage in
            storage.replaceCharacters(
                in: range,
                with: RichText.embedAttachment(for: newBlock, cache: cache)
            )
        }
        scheduleSave()
    }

    func replaceAsset(oldUrl: String, data: Data, name: String, fileExtension: String, mime: String) {
        Task { [weak self] in
            guard let self else { return }
            guard let newUrl = await self.model.createAsset(
                data: data,
                name: name,
                fileExtension: fileExtension,
                mimeType: mime
            ) else { return }
            self.cache.names[newUrl] = name
            self.cache.fileURLs[newUrl] = Self.mediaFile(for: newUrl, name: name, data: data)
            guard let view = self.view, let storage = view.pStorage else { return }
            var target: NSRange?
            storage.enumerateAttribute(
                .amBlock,
                in: NSRange(location: 0, length: storage.length)
            ) { value, range, stop in
                guard let box = value as? BlockBox,
                      box.value.isEmbedBlock,
                      box.value.embedUrl == oldUrl
                else { return }
                target = range
                stop.pointee = true
            }
            guard let target else { return }
            let newBlock = BlockValue.embed(url: newUrl)
            view.pPerformStorageEdit { storage in
                storage.replaceCharacters(
                    in: target,
                    with: RichText.embedAttachment(for: newBlock, cache: self.cache)
                )
            }
            self.scheduleSave()
            self.transcribeIfAudio(url: newUrl, data: data, name: name)
        }
    }

    private func range(whereBlockBox box: BlockBox, in storage: NSTextStorage) -> NSRange? {
        var found: NSRange?
        storage.enumerateAttribute(
            .amBlock,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            if (value as? BlockBox) === box {
                found = range
                stop.pointee = true
            }
        }
        return found
    }


    // MARK: attachments

    /// Route pasted/dropped data. Returns true when consumed.
    func incomingData(_ data: Data, fileExtension: String, suggestedName: String?) -> Bool {
        let ext = fileExtension.lowercased()
        let name = suggestedName
            ?? "attachment-\(Int(Date().timeIntervalSince1970)).\(ext)"
        insertAsset(data: data, name: name, fileExtension: ext, mime: Self.mime(for: ext))
        return true
    }

    static func mime(for ext: String) -> String {
        UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    func attachFromPanel(imagesOnly: Bool) {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = imagesOnly ? [.image] : [.item]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let data = try? Data(contentsOf: url)
            else { return }
            let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension.lowercased()
            Task { @MainActor in
                _ = self?.incomingData(data, fileExtension: ext, suggestedName: url.lastPathComponent)
            }
        }
        #endif
    }

    func insertAsset(data: Data, name: String, fileExtension: String, mime: String) {
        let targetNoteUrl = noteUrl
        Task { [weak self] in
            guard let self else { return }
            guard let url = await self.model.createAsset(
                data: data,
                name: name,
                fileExtension: fileExtension,
                mimeType: mime
            ) else { return }
            if let image = PImage(data: data) {
                self.cache.images[url] = image
                // vision metadata in the background; searchable once written
                Task.detached { [weak model = self.model] in
                    if let result = await VisionAnalyzer.analyze(data) {
                        await model?.updateAssetVision(
                            url,
                            description: result.description,
                            ocr: result.ocr
                        )
                        await model?.generateAssetML(url, name: name)
                    }
                }
            } else {
                self.cache.names[url] = name
                switch AssetCache.kind(forName: name) {
                case "video":
                    await self.prepareVideo(url: url, name: name, data: data)
                case "audio":
                    self.cache.fileURLs[url] = Self.mediaFile(for: url, name: name, data: data)
                default:
                    break
                }
                self.transcribeIfAudio(url: url, data: data, name: name)
            }
            guard self.noteUrl == targetNoteUrl else {
                NSLog("lush insertAsset: note switched during upload, not embedding %@", url)
                return
            }
            self.insertEmbedBlock(url: url)
        }
    }

    private func transcribeIfAudio(url: String, data: Data, name: String) {
        guard AssetCache.kind(forName: name) == "audio" else { return }
        let ext = (name as NSString).pathExtension.lowercased()
        Task.detached { [weak model, weak self] in
            guard let transcript = await Transcriber.transcribe(data, fileExtension: ext),
                  !transcript.isEmpty
            else { return }
            await model?.updateAssetVision(url, description: "voice recording", ocr: transcript)
            await model?.generateAssetML(url, name: name)
            await self?.transcriptReady(url: url, transcript: transcript)
        }
    }

    private func transcriptReady(url: String, transcript: String) {
        cache.transcripts[url] = transcript
        inline.resetHosts()
    }

    func insertTable() {
        let box = TableBox(raw: nil, grid: .empty(rows: 3, columns: 3))
        insertBlockAttachment(RichText.tableAttachment(for: box))
    }

    func tableChanged(_ box: TableBox) {
        scheduleSave()
        inline.embedChanged(box)
    }

    func insertColumns() {
        let box = ColumnsBox(
            raw: nil,
            columns: [[.block(.paragraph)], [.block(.paragraph)]]
        )
        insertBlockAttachment(RichText.columnsAttachment(for: box))
    }

    func columnsChanged(_ box: ColumnsBox) {
        scheduleSave()
        inline.embedChanged(box)
    }

    func insertHtmlBlock() {
        let html = "<p>hello</p>"
        let block = BlockValue.html(html)
        let attachment = RichText.embedAttachment(for: block, cache: cache)
        guard let range = insertBlockAttachment(attachment),
              let storage = view?.pStorage,
              range.location < storage.length,
              let box = storage.attribute(.amBlock, at: range.location, effectiveRange: nil) as? BlockBox,
              box.value.type == "html"
        else { return }
        controller.sheet = .html(HtmlBlockHandle(box: box, html: html))
    }

    func startLiveTranscription() {
        guard liveTranscriber == nil, let view = noteView, let storage = view.pStorage else { return }
        let id = UUID().uuidString
        let location = min(view.pSelectedRange.location, storage.length)
        var attributes = view.pTypingAttributes
        attributes.removeValue(forKey: .attachment)
        attributes.removeValue(forKey: .amDisplayOnly)
        attributes.removeValue(forKey: .amLiveTranscription)
        let marker = NSMutableAttributedString(
            attachment: EmbedAttachment(box: LiveTranscriptionBox(id: id))
        )
        marker.addAttributes(attributes, range: NSRange(location: 0, length: marker.length))
        marker.addAttributes([
            .amDisplayOnly: true,
            .amLiveTranscription: "\(id):marker",
        ], range: NSRange(location: 0, length: marker.length))
        liveTranscriptionUndo = undoSnapshot(of: view)
        view.pPerformStorageEdit { storage in
            storage.insert(marker, at: location)
        }
        view.pSelectedRange = NSRange(location: location + marker.length, length: 0)
        liveTranscriptionID = id
        liveTranscriptionAttributes = attributes
        controller.liveTranscriptionActive = true
        let transcriber = LiveTranscriber()
        liveTranscriber = transcriber
        Task { [weak self, weak transcriber] in
            guard let self, let transcriber else { return }
            let started = await transcriber.start { [weak self] text in
                self?.updateLiveTranscription(text, id: id)
            }
            if !started {
                self.finishLiveTranscription(id: id, registerUndo: false)
            }
        }
    }

    func stopLiveTranscription() {
        guard let id = liveTranscriptionID, let transcriber = liveTranscriber else { return }
        Task { [weak self, weak transcriber] in
            await transcriber?.stop()
            self?.finishLiveTranscription(id: id, registerUndo: true)
        }
    }

    private func updateLiveTranscription(_ text: String, id: String) {
        guard id == liveTranscriptionID, let view = noteView, let storage = view.pStorage,
              let marker = liveTranscriptionMarker(id, in: storage)
        else { return }
        let start = NSMaxRange(marker)
        var old = NSRange(location: start, length: 0)
        if start < storage.length,
           storage.attribute(.amLiveTranscription, at: start, effectiveRange: &old) as? String != id {
            old = NSRange(location: start, length: 0)
        }
        let replacement = NSMutableAttributedString(string: text, attributes: liveTranscriptionAttributes)
        replacement.addAttribute(
            .amLiveTranscription,
            value: id,
            range: NSRange(location: 0, length: replacement.length)
        )
        let selection = view.pSelectedRange
        flushQueuedTextSplice()
        guard let index = automergeTextPosition(in: storage, at: old.location) else { return }
        pendingTextSplice = PendingTextSplice(
            index: UInt64(index),
            deleteCount: Int64(editableScalarCount(in: storage, range: old)),
            insert: text,
            utf16Location: old.location,
            utf16Length: old.length
        )
        view.pPerformStorageEdit { storage in
            storage.replaceCharacters(in: old, with: replacement)
        }
        textDidChange()
        flushQueuedTextSplice()
        let delta = replacement.length - old.length
        if selection.location >= NSMaxRange(old) {
            view.pSelectedRange = NSRange(
                location: max(start + replacement.length, selection.location + delta),
                length: selection.length
            )
        } else if NSIntersectionRange(selection, old).length > 0 {
            view.pSelectedRange = NSRange(location: start + replacement.length, length: 0)
        }
    }

    private func finishLiveTranscription(id: String, registerUndo shouldRegisterUndo: Bool) {
        guard id == liveTranscriptionID else { return }
        if let view = noteView, let storage = view.pStorage,
           let marker = liveTranscriptionMarker(id, in: storage) {
            let selection = view.pSelectedRange
            view.pPerformStorageEdit { storage in
                storage.deleteCharacters(in: marker)
                let range = NSRange(location: 0, length: storage.length)
                storage.removeAttribute(.amLiveTranscription, range: range)
            }
            if selection.location > marker.location {
                view.pSelectedRange = NSRange(
                    location: max(marker.location, selection.location - marker.length),
                    length: selection.length
                )
            }
            if shouldRegisterUndo {
                registerUndo(from: liveTranscriptionUndo, actionName: "Live Transcription")
            }
        }
        liveTranscriber = nil
        liveTranscriptionID = nil
        liveTranscriptionAttributes = [:]
        liveTranscriptionUndo = nil
        controller.liveTranscriptionActive = false
    }

    private func cancelLiveTranscription() {
        guard let id = liveTranscriptionID else { return }
        let transcriber = liveTranscriber
        finishLiveTranscription(id: id, registerUndo: true)
        Task {
            await transcriber?.stop()
        }
    }

    private func liveTranscriptionMarker(_ id: String, in storage: NSTextStorage) -> NSRange? {
        var marker: NSRange?
        storage.enumerateAttribute(
            .amLiveTranscription,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            guard value as? String == "\(id):marker",
                  storage.attribute(.amDisplayOnly, at: range.location, effectiveRange: nil) != nil
            else { return }
            marker = NSRange(location: range.location, length: 1)
            stop.pointee = true
        }
        return marker
    }

    private func insertEmbedBlock(url: String) {
        let block = BlockValue.embed(url: url)
        insertBlockAttachment(RichText.embedAttachment(for: block, cache: cache))
    }

    @discardableResult
    private func insertBlockAttachment(_ attachment: NSAttributedString) -> NSRange? {
        guard let view, let storage = view.pStorage else { return nil }
        let undo = undoSnapshot()
        let insertion = NSMutableAttributedString()
        let str = storage.string as NSString
        // insert after the current paragraph so it never splits text into
        // the embed block
        let paragraph = str.paragraphRange(for: view.pSelectedRange)
        let location = NSMaxRange(paragraph)
        let atParagraphStart = location == 0 || str.character(at: location - 1) == 0x0A
        if !atParagraphStart {
            insertion.append(NSAttributedString(
                string: "\n",
                attributes: view.pTypingAttributes
            ))
        }
        let attachmentStart = location + (atParagraphStart ? 0 : 1)
        insertion.append(attachment)
        insertion.append(NSAttributedString(
            string: "\n",
            attributes: RichText.attributes(block: .paragraph, marks: [:])
        ))
        view.pPerformStorageEdit { storage in
            storage.insert(insertion, at: location)
        }
        view.pSelectedRange = NSRange(location: location + insertion.length, length: 0)
        view.pTypingAttributes = RichText.attributes(block: .paragraph, marks: [:])
        registerUndo(from: undo, actionName: "Insert Block")
        scheduleSave()
        return NSRange(location: attachmentStart, length: attachment.length)
    }

    #if os(iOS)
    /// AppKit routes pReplace through shouldChangeText/didChangeText, which
    /// registers undo; UIKit has no such hook, so snapshot it like the other
    /// storage mutations do.
    func pReplaceRegisteringUndo(_ range: NSRange, with attributed: NSAttributedString) {
        guard let view, view.pStorage != nil else { return }
        let undo = undoSnapshot()
        view.pPerformStorageEdit { storage in
            storage.replaceCharacters(in: range, with: attributed)
        }
        registerUndo(from: undo, actionName: "Edit")
        scheduleSave()
    }
    #endif
}

@MainActor
func editorPlainText(_ slice: NSAttributedString) -> String {
    let str = slice.string as NSString
    var out = ""
    slice.enumerateAttributes(in: NSRange(location: 0, length: slice.length)) { attrs, range, _ in
        guard attrs[.amDisplayOnly] == nil else { return }
        out += str.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
    }
    return out
}

@MainActor
func editorCopyRange(
    _ selection: NSRange,
    in storage: NSTextStorage,
    core: EditorCore?
) -> NSRange? {
    if selection.length > 0 { return selection }
    guard let core else { return nil }
    let locations = [selection.location, selection.location - 1]
    for location in locations where location >= 0 && location < storage.length {
        let attributes = storage.attributes(at: location, effectiveRange: nil)
        guard attributes[.attachment] != nil,
              let box = attributes[.amBlock] as? BlockBox,
              let url = box.value.embedUrl,
              core.cache.images[url] != nil
        else { continue }
        return NSRange(location: location, length: 1)
    }
    return nil
}

// MARK: - macOS

#if os(macOS)

class EditorTextView: NSTextView, EditorTextViewLike {
    weak var core: EditorCore?

    private var windowKeyObserver: (any NSObjectProtocol)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowKeyObserver {
            NotificationCenter.default.removeObserver(windowKeyObserver)
            self.windowKeyObserver = nil
        }
        guard let window else { return }
        windowKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.core?.windowBecameKey()
            }
        }
    }

    deinit {
        if let windowKeyObserver {
            NotificationCenter.default.removeObserver(windowKeyObserver)
        }
    }


    /// `textStorage` can go stale after the content storage adopts the shared
    /// session storage, so everything resolves through the content storage.
    var pStorage: NSTextStorage? { pContentStorage?.textStorage }
    var pSelectedRange: NSRange {
        get { selectedRange() }
        set { setSelectedRange(newValue) }
    }
    var pTypingAttributes: [NSAttributedString.Key: Any] {
        get { typingAttributes }
        set { typingAttributes = newValue }
    }
    var pSelectedRanges: [NSRange] {
        get { selectedRanges.map(\.rangeValue) }
        set {
            guard !newValue.isEmpty else { return }
            setSelectedRanges(
                newValue.map { NSValue(range: $0) },
                affinity: .downstream,
                stillSelecting: false
            )
        }
    }
    var pTextLayoutManager: NSTextLayoutManager? { textLayoutManager }
    var pContentStorage: NSTextContentStorage? { textContentStorage }
    var pTextContainer: NSTextContainer? { textContainer }
    var pSelf: PView { self }
    var pTextOrigin: CGPoint { textContainerOrigin }

    func pInsertText(_ text: String) {
        insertText(text, replacementRange: selectedRange())
    }

    func pReplace(_ range: NSRange, with attributed: NSAttributedString) {
        if shouldChangeText(in: range, replacementString: attributed.string) {
            textStorage?.replaceCharacters(in: range, with: attributed)
            didChangeText()
        }
    }

    func pScrollRangeToVisible(_ range: NSRange) {
        scrollRangeToVisible(range)
    }

    /// The container tracks the view's width, so a wide window is narrowed by
    /// growing the side insets equally, which centres the text.
    func pApplyMaxWidth() {
        let limit = EditorSettings.maxNoteWidth
        let width = enclosingScrollView?.contentSize.width ?? bounds.width
        let inset = limit > 0 ? max(20, (width - limit) / 2) : 20
        guard abs(textContainerInset.width - inset) > 0.5 else { return }
        textContainerInset = NSSize(width: inset, height: textContainerInset.height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        pApplyMaxWidth()
    }

    var pVisibleRect: CGRect { visibleRect }
    var pUndoManager: UndoManager? { undoManager }

    func pScrollToY(_ y: CGFloat) {
        guard let scroll = enclosingScrollView else { return }
        let visibleHeight = scroll.contentView.bounds.height
        guard visibleHeight > 0 else { return }
        let minY = -scroll.contentInsets.top
        let maxY = max(minY, bounds.height - visibleHeight)
        let target = min(max(y, minY), maxY)
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func pPerformStorageEdit(_ edit: (NSTextStorage) -> Void) {
        guard let storage = pStorage else { return }
        if let contentStorage = pContentStorage {
            contentStorage.performEditingTransaction {
                edit(storage)
            }
        } else {
            edit(storage)
        }
    }

    func pCharacterIndex(atTextContainerPoint point: CGPoint) -> Int? {
        // NSTextContainer.layoutManager is nil under TextKit 2; go through
        // the view's insertion-point API instead
        let viewPoint = CGPoint(
            x: point.x + textContainerOrigin.x,
            y: point.y + textContainerOrigin.y
        )
        let index = characterIndexForInsertion(at: viewPoint)
        guard index < (textStorage?.length ?? 0) else { return nil }
        return index
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift),
           core?.leaveCodeBlock() == true {
            return
        }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command {
            if event.charactersIgnoringModifiers == "]" {
                core?.indentBlock()
                return
            } else if event.charactersIgnoringModifiers == "[" {
                core?.outdentBlock()
                return
            }
        }
        super.keyDown(with: event)
    }

    /// Automerge rich-text spans as JSON — the same shape automerge's spans
    /// API speaks, so other automerge apps can interchange with it. Consumers
    /// should skip block types they don't know.
    static let spansPasteboardType = NSPasteboard.PasteboardType(RichTextClipboard.spansTypeIdentifier)
    static let htmlPasteboardType = NSPasteboard.PasteboardType(RichTextClipboard.htmlTypeIdentifier)
    static let markdownPasteboardType = NSPasteboard.PasteboardType(RichTextClipboard.markdownTypeIdentifier)

    /// Copy rich selections in every interchange format we can produce.
    /// The app-specific span JSON is lossless; HTML and Markdown are for
    /// moving content through other editors.
    private func copySelectionAsSpans(cut: Bool) -> Bool {
        guard let storage = textStorage else { return false }
        guard let range = editorCopyRange(selectedRange(), in: storage, core: core) else { return false }
        let slice = storage.attributedSubstring(from: range)
        let spans = RichText.spans(from: slice)
        let json = SpanNode.encodeList(spans)
        let media: (images: [PImage], files: [URL]) = core?.copiedMedia(in: slice) ?? (images: [], files: [])
        var inlineImages: [String: Data] = [:]
        for span in spans {
            guard case .block(let block) = span,
                  let url = block.embedUrl,
                  let image = core?.cache.images[url],
                  let data = Self.pngData(image)
            else { continue }
            inlineImages[url] = data
        }
        let attachmentLabel: (BlockValue, Int) -> String = { block, _ in
            guard let url = block.embedUrl, inlineImages[url] != nil else { return "[attachment]" }
            return block.altText
        }
        let markdown = RichTextClipboard.markdown(from: spans, attachmentLabel: attachmentLabel)
        let visibleText = editorPlainText(slice)
        let plain = visibleText.isEmpty ? markdown : visibleText
        let item = NSPasteboardItem()
        item.setString(json, forType: Self.spansPasteboardType)
        item.setString(
            RichTextClipboard.html(from: spans, inlineImages: inlineImages),
            forType: Self.htmlPasteboardType
        )
        item.setString(markdown, forType: Self.markdownPasteboardType)
        for (type, data) in RichTextClipboard.webCustomItems(spansJSON: json) {
            item.setData(data, forType: .init(type))
        }
        item.setString(plain, forType: .string)
        // an app that takes none of our rich types still gets the picture,
        // and it rides on the same item so a one-image copy pastes as one
        if let png = media.images.first.flatMap(Self.pngData) {
            item.setData(png, forType: .png)
        }
        var objects: [NSPasteboardWriting] = [item]
        for image in media.images.dropFirst() { objects.append(image) }
        for file in media.files { objects.append(file as NSURL) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(objects)
        if cut {
            pReplace(range, with: NSAttributedString())
        }
        return true
    }

    nonisolated static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }

    override func copy(_ sender: Any?) {
        if copySelectionAsSpans(cut: false) { return }
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        if copySelectionAsSpans(cut: true) { return }
        super.cut(sender)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let core, selectedRange().length > 0,
           let url = RichTextClipboard.loneURL(pasteboard.string(forType: .string)) {
            core.setLink(url)
            return
        }
        if let core,
           let json = pasteboard.string(forType: Self.spansPasteboardType),
           let attributed = RichTextClipboard.attributed(fromSpansJSON: json, cache: core.cache) {
            pReplace(selectedRange(), with: attributed)
            return
        }
        if let core,
           let mapData = pasteboard.data(forType: .init(RichTextClipboard.webCustomMapIdentifier)),
           let json = RichTextClipboard.spansJSON(webCustomMap: mapData, payload: {
               pasteboard.data(forType: .init($0))
           }),
           let attributed = RichTextClipboard.attributed(fromSpansJSON: json, cache: core.cache) {
            pReplace(selectedRange(), with: attributed)
            return
        }
        if consumeAttachment(from: pasteboard) { return }
        if let core,
           let html = pasteboard.string(forType: Self.htmlPasteboardType),
           let attributed = RichTextClipboard.attributed(fromHTML: html, cache: core.cache) {
            pReplace(selectedRange(), with: attributed)
            return
        }
        if let core,
           let markdown = pasteboard.string(forType: Self.markdownPasteboardType)
                ?? pasteboard.string(forType: .string),
           let attributed = RichTextClipboard.attributed(fromMarkdown: markdown, cache: core.cache) {
            pReplace(selectedRange(), with: attributed)
            return
        }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            super.pasteAsPlainText(sender)
            return
        }
        insertText(text, replacementRange: selectedRange())
    }

    /// Sidebar drags carry automerge urls as strings inside SwiftUI's private
    /// pasteboard items. AppKit's legacy-filenames shim sends `path` to those
    /// items and dies, so anything that might consult it — NSTextView's own
    /// drag validation, NSURL reading — is kept away from text-only drags.
    private func isTextOnlyDrag(_ sender: NSDraggingInfo) -> Bool {
        guard (sender.draggingSource as AnyObject?) !== self else { return false }
        let types = sender.draggingPasteboard.types ?? []
        let hasText = types.contains { $0 == .string || $0.rawValue.contains("utf8-plain-text") }
        let hasFiles = types.contains {
            $0 == .fileURL || $0.rawValue == "NSFilenamesPboardType"
        }
        return hasText && !hasFiles
    }

    /// `string(forType:)` can come back nil for lazily-promised SwiftUI items;
    /// asking each item for its own text types resolves them directly.
    private func dragString(_ pasteboard: NSPasteboard) -> String? {
        if let text = pasteboard.string(forType: .string) { return text }
        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types
            where type.rawValue.contains("utf8-plain-text") || type.rawValue.contains("public.text") {
                if let text = item.string(forType: type) { return text }
            }
        }
        return nil
    }

    /// A card coming back from a pad is a move — the badgeless one, and the
    /// operation its drag source offers.
    private func textDragOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let text = dragString(sender.draggingPasteboard) else { return .copy }
        return text.hasPrefix(PadDrag.prefix) ? .move : .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isTextOnlyDrag(sender) { return textDragOperation(sender) }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isTextOnlyDrag(sender) { return textDragOperation(sender) }
        return super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if isTextOnlyDrag(sender) { return true }
        return super.prepareForDragOperation(sender)
    }

    /// NSTextView refreshes drag previews on a timer by enumerating the items
    /// as image URLs, which sends `path` to SwiftUI's pasteboard items and
    /// crashes — the one AppKit entry point the other overrides don't cover.
    override func updateDraggingItemsForDrag(_ sender: NSDraggingInfo?) {
        if let sender, isTextOnlyDrag(sender) { return }
        super.updateDraggingItemsForDrag(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if let core,
           let text = dragString(pasteboard),
           let drag = PadDrag(text) {
            let point = convert(sender.draggingLocation, from: nil)
            let dropIndex = characterIndexForInsertion(at: point)
            let store = core.model.pads
            guard let item = store.items(of: drag.padUrl).first(where: { $0.id == drag.itemId })
            else { return false }
            core.insertPadSpans(item.spans, at: dropIndex)
            if !NSEvent.modifierFlags.contains(.option) {
                store.remove(drag.itemId, from: drag.padUrl)
            }
            return true
        }
        if let core,
           let text = dragString(pasteboard),
           text.contains("automerge:") {
            let urls = text.split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { $0.hasPrefix("automerge:") }
            if !urls.isEmpty {
                let point = convert(sender.draggingLocation, from: nil)
                let index = characterIndexForInsertion(at: point)
                setSelectedRange(NSRange(location: min(index, textStorage?.length ?? 0), length: 0))
                for url in urls {
                    core.insertPatchworkEmbed(url: url, tool: nil)
                }
                return true
            }
        }
        if consumeAttachment(from: pasteboard) { return true }
        return super.performDragOperation(sender)
    }

    /// Media/table/html attachments open on click; images open their info
    /// sheet on double-click so a single click still places the selection.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option,
           let core {
            // only a clean click adds a caret; an option-drag falls through
            // to NSTextView's rectangular selection
            guard let window,
                  let next = window.nextEvent(
                      matching: [.leftMouseUp, .leftMouseDragged],
                      until: .distantFuture,
                      inMode: .eventTracking,
                      dequeue: true
                  )
            else {
                super.mouseDown(with: event)
                return
            }
            if next.type == .leftMouseUp {
                let point = convert(event.locationInWindow, from: nil)
                core.addCaret(at: characterIndexForInsertion(at: point))
                return
            }
            window.postEvent(next, atStart: true)
            super.mouseDown(with: event)
            return
        }
        if event.clickCount <= 2, let core {
            let point = convert(event.locationInWindow, from: nil)
            let containerPoint = CGPoint(
                x: point.x - textContainerOrigin.x,
                y: point.y - textContainerOrigin.y
            )
            if event.clickCount == 1, core.foldHit(at: containerPoint) {
                return
            }
            if event.clickCount == 1,
               let todo = core.todoBoxHit(at: containerPoint),
               core.toggleTodo(at: todo) {
                return
            }
            if event.clickCount == 1, core.calendarEmbedHit(at: containerPoint) {
                return
            }
            if let charIndex = core.attachmentIndex(at: containerPoint),
               core.openAttachment(at: charIndex, includeImages: event.clickCount == 2) {
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// Double-clicking an image opens its info, but nothing advertises that.
    /// Right-click is where a mac user looks for it.
    override func menu(for event: NSEvent) -> NSMenu? {
        let standard = super.menu(for: event)
        let point = convert(event.locationInWindow, from: nil)
        let containerPoint = CGPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        guard let core else { return standard }
        if let todo = core.todoBoxHit(at: containerPoint),
           let state = core.todoState(at: todo) {
            let menu = NSMenu()
            for candidate in TodoState.allCases {
                let item = NSMenuItem(
                    title: candidate.label,
                    action: #selector(setTodoState(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = todo
                item.representedObject = candidate.rawValue
                item.state = candidate == state ? .on : .off
                menu.addItem(item)
            }
            return menu
        }
        guard let charIndex = core.attachmentIndex(at: containerPoint),
              core.isImageAttachment(at: charIndex)
        else { return standard }
        let menu = standard ?? NSMenu()
        let item = NSMenuItem(
            title: "Get Info",
            action: #selector(showAttachmentInfo(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = charIndex
        menu.insertItem(item, at: 0)
        if standard != nil {
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    @objc private func setTodoState(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let state = TodoState(rawValue: raw)
        else { return }
        core?.setTodoState(state, at: sender.tag)
    }

    @objc private func showAttachmentInfo(_ sender: NSMenuItem) {
        guard let charIndex = sender.representedObject as? Int else { return }
        core?.openAttachment(at: charIndex)
    }

    /// Files and images win over the stray strings browsers put alongside
    /// copied images; plain text still pastes as text.
    private func consumeAttachment(from pasteboard: NSPasteboard) -> Bool {
        guard let core else { return false }
        let files = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        if !files.isEmpty {
            var embedded = false
            for url in files {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { continue }
                let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension.lowercased()
                embedded = core.incomingData(
                    data,
                    fileExtension: ext,
                    suggestedName: url.lastPathComponent
                ) || embedded
            }
            if embedded { return true }
        }
        if let data = pasteboard.data(forType: .png) {
            return core.incomingData(data, fileExtension: "png", suggestedName: nil)
        }
        if let data = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: data),
           let png = rep.representation(using: .png, properties: [:]) {
            return core.incomingData(png, fileExtension: "png", suggestedName: nil)
        }
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)) {
            return core.incomingData(data, fileExtension: "jpg", suggestedName: nil)
        }
        return false
    }
}

struct RichTextEditor: NSViewRepresentable {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openInTab) private var openInTab

    let noteUrl: String
    let model: NotesModel
    let controller: EditorController
    let contextTracker: ContextTracker

    func makeCoordinator() -> Coordinator {
        Coordinator(
            core: EditorCore(noteUrl: noteUrl, model: model, controller: controller),
            openInTab: openInTab
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = EditorTextView(usingTextLayoutManager: true)
        textView.textLayoutManager?.delegate = context.coordinator.markers
        textView.textLayoutManager?.renderingAttributesValidator = context.coordinator.core.rendering.validator
        textView.textContentStorage?.delegate = context.coordinator.core.folding
        context.coordinator.markers.foldedHeadingsProvider = { [weak core = context.coordinator.core] in
            core?.folding.foldedHeadings ?? []
        }
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = true
        // image-only pasteboards (screenshots) otherwise fail paste
        // validation and ⌘V just beeps; our paste override intercepts the
        // image before NSTextView's own graphics handling runs
        textView.importsGraphics = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.typingAttributes = RichText.attributes(block: .paragraph, marks: [:])
        textView.linkTextAttributes = [
            .foregroundColor: PColor.pTint,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        textView.delegate = context.coordinator
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.core = context.coordinator.core
        textView.registerForDraggedTypes(textView.registeredDraggedTypes + [.fileURL])
        context.coordinator.markers.driveTypingAttributes(from: textView)
        context.coordinator.markers.driveSelection(from: textView)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        // the editor extends under the toolbar; content rests below it
        scroll.automaticallyAdjustsContentInsets = true
        scroll.documentView = textView
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: nil
        ) { [weak core = context.coordinator.core] _ in
            MainActor.assumeIsolated {
                core?.updateMinimapViewport()
                core?.scheduleRemoteCaretUpdate()
            }
        }

        context.coordinator.core.view = textView
        context.coordinator.core.attachViewToSharedStorage()
        context.coordinator.core.load()
        context.coordinator.core.startContext(contextTracker)
        return scroll
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.core.detachViewFromSharedStorage()
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.openInTab = openInTab
        if context.coordinator.core.noteUrl != noteUrl {
            context.coordinator.core.switchTo(noteUrl)
        }
        context.coordinator.scenePhaseChanged(to: scenePhase)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let core: EditorCore
        let markers = ListMarkerLayoutDelegate()
        var scrollObserver: (any NSObjectProtocol)?
        var openInTab: ((String) -> Void)?
        private var lastScenePhase: ScenePhase?

        init(core: EditorCore, openInTab: ((String) -> Void)?) {
            self.core = core
            self.openInTab = openInTab
        }

        deinit {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }

        func scenePhaseChanged(to phase: ScenePhase) {
            defer { lastScenePhase = phase }
            guard phase == .active, lastScenePhase != nil, lastScenePhase != .active else { return }
            core.checkContextChangeAfterReactivation()
        }

        func textDidChange(_ notification: Notification) {
            core.textDidChange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            core.refreshFormattingState()
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL)?.absoluteString ?? link as? String
            guard let url, url.hasPrefix("automerge:") else { return false }
            if NSEvent.modifierFlags.contains(.command), let openInTab {
                openInTab(url)
                return true
            }
            core.model.pendingFocusUrl = url
            AppRouter.shared.pending = .note(url)
            return true
        }

        func textView(_ view: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let handled = core.handleReturn()
                return handled
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
            if commandSelector == #selector(NSStandardKeyBindingResponding.moveToBeginningOfLine(_:))
                || commandSelector == #selector(NSStandardKeyBindingResponding.moveToBeginningOfParagraph(_:)) {
                return core.moveToBlockquoteSoftLineBoundary(end: false)
            }
            if commandSelector == #selector(NSStandardKeyBindingResponding.moveToEndOfLine(_:))
                || commandSelector == #selector(NSStandardKeyBindingResponding.moveToEndOfParagraph(_:)) {
                return core.moveToBlockquoteSoftLineBoundary(end: true)
            }
            return false
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextInRanges affectedRanges: [NSValue],
            replacementStrings: [String]?
        ) -> Bool {
            guard core.isLoaded else { return false }
            // multi-caret edits skip the splice pipeline; textDidChange falls
            // back to a whole-doc save, which automerge handles fine
            guard affectedRanges.count == 1, let range = affectedRanges.first?.rangeValue else {
                return true
            }
            return self.textView(textView, shouldChangeTextIn: range, replacementString: replacementStrings?.first)
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard core.isLoaded else { return false }
            if replacementString == " ",
               affectedCharRange.length == 0,
               core.handleMarkdownTrigger(at: affectedCharRange.location) {
                return false
            }
            _ = core.prepareTextSplice(
                range: affectedCharRange,
                replacement: replacementString ?? ""
            )
            return true
        }
    }
}

#else

// MARK: - iOS

extension EditorTextView: UIEditMenuInteractionDelegate {
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        takePendingTodoMenu()
    }
}

private final class SuppressedKeyboardInputView: UIInputView {
    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        CGSize(width: targetSize.width, height: 1)
    }
}

final class EditorTextView: UITextView, EditorTextViewLike {
    weak var core: EditorCore?

    var editorAccessoryView: UIView?
    private lazy var keyboardSuppressingInputView: UIInputView = {
        let view = SuppressedKeyboardInputView(frame: .zero, inputViewStyle: .keyboard)
        view.allowsSelfSizing = true
        return view
    }()
    /// The format panel floats where the keyboard was, so the text view keeps
    /// first responder — and its selection — while the keyboard stands down.
    var suppressesKeyboard = false {
        didSet {
            guard oldValue != suppressesKeyboard else { return }
            let selection = selectedRange
            inputView = suppressesKeyboard ? keyboardSuppressingInputView : nil
            inputAccessoryView = suppressesKeyboard ? nil : editorAccessoryView
            reloadInputViews()
            selectedRange = selection
        }
    }

    /// `textStorage` can go stale after the content storage adopts the shared
    /// session storage, so everything resolves through the content storage.
    var pStorage: NSTextStorage? { pContentStorage?.textStorage }
    var pSelectedRange: NSRange {
        get { selectedRange }
        set { selectedRange = clampedRange(newValue) }
    }
    var pTypingAttributes: [NSAttributedString.Key: Any] {
        get { typingAttributes }
        set { typingAttributes = newValue }
    }
    var pSelectedRanges: [NSRange] {
        get { [selectedRange] }
        set { if let first = newValue.first { selectedRange = first } }
    }
    var pTextLayoutManager: NSTextLayoutManager? { textLayoutManager }
    var pContentStorage: NSTextContentStorage? {
        textLayoutManager?.textContentManager as? NSTextContentStorage
    }
    var pTextContainer: NSTextContainer? { textContainer }
    var pSelf: PView { self }
    var pTextOrigin: CGPoint {
        CGPoint(x: textContainerInset.left, y: textContainerInset.top)
    }

    func pInsertText(_ text: String) {
        insertText(text)
    }

    private lazy var todoMenu: UIEditMenuInteraction = {
        let interaction = UIEditMenuInteraction(delegate: self)
        addInteraction(interaction)
        return interaction
    }()

    private var pendingTodoMenu: UIMenu?

    func showTodoMenu(_ menu: UIMenu, at point: CGPoint) {
        pendingTodoMenu = menu
        todoMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }

    func takePendingTodoMenu() -> UIMenu? {
        defer { pendingTodoMenu = nil }
        return pendingTodoMenu
    }

    func pReplace(_ range: NSRange, with attributed: NSAttributedString) {
        core?.pReplaceRegisteringUndo(clampedRange(range), with: attributed)
    }

    func pScrollRangeToVisible(_ range: NSRange) {
        scrollRangeToVisible(range)
    }

    func scrollSelectionAboveSheet(height: CGFloat) {
        let range = pSelectedRange
        guard range.location != NSNotFound else { return }
        let saved = contentInset.bottom
        contentInset.bottom = max(saved, height)
        scrollRangeToVisible(range)
        contentInset.bottom = saved
    }

    /// The container tracks the view's width, so a wide window is narrowed by
    /// growing the side insets equally, which centres the text.
    func pApplyMaxWidth() {
        let limit = EditorSettings.maxNoteWidth
        let width = bounds.width - adjustedContentInset.left - adjustedContentInset.right
        let inset = limit > 0 ? max(16, (width - limit) / 2) : 16
        guard abs(textContainerInset.left - inset) > 0.5 else { return }
        textContainerInset = UIEdgeInsets(
            top: textContainerInset.top,
            left: inset,
            bottom: textContainerInset.bottom,
            right: inset
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        pApplyMaxWidth()
    }

    var pVisibleRect: CGRect {
        CGRect(origin: contentOffset, size: bounds.size)
    }
    var pUndoManager: UndoManager? { undoManager }

    func pScrollToY(_ y: CGFloat) {
        let visibleHeight = bounds.height - adjustedContentInset.top - adjustedContentInset.bottom
        guard visibleHeight > 0 else { return }
        // contentSize lags the edit that moved the caret; the layout
        // manager's usage bounds are current
        var contentHeight = contentSize.height
        if let textLayoutManager {
            contentHeight = max(
                contentHeight,
                textLayoutManager.usageBoundsForTextContainer.maxY
                    + textContainerInset.top + textContainerInset.bottom
            )
        }
        let minY = -adjustedContentInset.top
        let maxY = max(minY, contentHeight - visibleHeight + adjustedContentInset.bottom)
        let target = min(max(y, minY), maxY)
        setContentOffset(CGPoint(x: contentOffset.x, y: target), animated: false)
    }

    func pPerformStorageEdit(_ edit: (NSTextStorage) -> Void) {
        guard let storage = pStorage else { return }
        if let contentStorage = pContentStorage {
            contentStorage.performEditingTransaction {
                edit(storage)
            }
        } else {
            edit(storage)
        }
    }

    func pCharacterIndex(atTextContainerPoint point: CGPoint) -> Int? {
        let viewPoint = CGPoint(
            x: point.x + textContainerInset.left,
            y: point.y + textContainerInset.top
        )
        guard let position = closestPosition(to: viewPoint) else { return nil }
        let index = offset(from: beginningOfDocument, to: position)
        guard index >= 0, index < (pStorage?.length ?? 0) else { return nil }
        return index
    }

    private func clampedRange(_ range: NSRange) -> NSRange {
        let length = pStorage?.length ?? 0
        let location = min(max(range.location, 0), length)
        let end = min(max(NSMaxRange(range), location), length)
        return NSRange(location: location, length: end - location)
    }

    override var keyCommands: [UIKeyCommand]? {
        let type = core?.blockAtSelection().type
        var commands = [
            UIKeyCommand(input: "[", modifierFlags: .command, action: #selector(handleOutdentBlock)),
            UIKeyCommand(input: "]", modifierFlags: .command, action: #selector(handleIndentBlock)),
        ]
        if type == "unordered-list-item" || type == "ordered-list-item" {
            commands += [
                UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(handleTabKey)),
                UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(handleShiftTabKey)),
            ]
        }
        return commands
    }

    @objc private func handleTabKey() { core?.nestListItem() }
    @objc private func handleShiftTabKey() { core?.unnestListItem() }
    @objc private func handleIndentBlock() { core?.indentBlock() }
    @objc private func handleOutdentBlock() { core?.outdentBlock() }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            // contains(pasteboardTypes:) checks metadata only — reading
            // values here would raise the paste-permission banner
            let pasteboard = UIPasteboard.general
            if pasteboard.hasImages || pasteboard.contains(pasteboardTypes: [
                Self.spansPasteboardType,
                RichTextClipboard.webCustomMapIdentifier,
                RichTextClipboard.htmlTypeIdentifier,
                RichTextClipboard.markdownTypeIdentifier,
            ]) {
                return true
            }
        }
        return super.canPerformAction(action, withSender: sender)
    }

    static let spansPasteboardType = RichTextClipboard.spansTypeIdentifier

    private func copySelectionAsSpans(cut: Bool) -> Bool {
        guard let storage = pStorage,
              let range = editorCopyRange(selectedRange, in: storage, core: core)
        else { return false }
        let slice = storage.attributedSubstring(from: range)
        let spans = RichText.spans(from: slice)
        let json = SpanNode.encodeList(spans)
        let media: (images: [PImage], files: [URL]) = core?.copiedMedia(in: slice) ?? (images: [], files: [])
        var inlineImages: [String: Data] = [:]
        for span in spans {
            guard case .block(let block) = span,
                  let url = block.embedUrl,
                  let image = core?.cache.images[url],
                  let data = image.pngData()
            else { continue }
            inlineImages[url] = data
        }
        let attachmentLabel: (BlockValue, Int) -> String = { block, _ in
            guard let url = block.embedUrl, inlineImages[url] != nil else { return "[attachment]" }
            return block.altText
        }
        let markdown = RichTextClipboard.markdown(from: spans, attachmentLabel: attachmentLabel)
        let visibleText = editorPlainText(slice)
        var item: [String: Any] = [
            Self.spansPasteboardType: json,
            RichTextClipboard.htmlTypeIdentifier: RichTextClipboard.html(
                from: spans,
                inlineImages: inlineImages
            ),
            RichTextClipboard.markdownTypeIdentifier: markdown,
            UTType.utf8PlainText.identifier: visibleText.isEmpty ? markdown : visibleText,
        ]
        for (type, data) in RichTextClipboard.webCustomItems(spansJSON: json) {
            item[type] = data
        }
        // an app that takes none of our rich types still gets the picture,
        // and it rides on the same item so a one-image copy pastes as one
        if let png = media.images.first?.pngData() {
            item[UTType.png.identifier] = png
        }
        var items: [[String: Any]] = [item]
        for image in media.images.dropFirst() {
            guard let png = image.pngData() else { continue }
            items.append([UTType.png.identifier: png])
        }
        for file in media.files {
            guard let data = try? Data(contentsOf: file) else { continue }
            items.append([UTType.data.identifier: data])
        }
        UIPasteboard.general.items = items
        if cut {
            pReplace(range, with: NSAttributedString())
        }
        return true
    }

    override func copy(_ sender: Any?) {
        if copySelectionAsSpans(cut: false) { return }
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        if copySelectionAsSpans(cut: true) { return }
        super.cut(sender)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = UIPasteboard.general
        if let core, selectedRange.length > 0,
           let url = RichTextClipboard.loneURL(pasteboard.string) {
            core.setLink(url)
            return
        }
        if let value = pasteboard.value(forPasteboardType: Self.spansPasteboardType),
           let json = (value as? String) ?? (value as? Data).flatMap({ String(data: $0, encoding: .utf8) }),
           let core,
           let attributed = RichTextClipboard.attributed(fromSpansJSON: json, cache: core.cache) {
            pReplace(selectedRange, with: attributed)
            return
        }
        if let mapData = pasteboard.data(forPasteboardType: RichTextClipboard.webCustomMapIdentifier),
           let json = RichTextClipboard.spansJSON(webCustomMap: mapData, payload: {
               pasteboard.data(forPasteboardType: $0)
           }),
           let core,
           let attributed = RichTextClipboard.attributed(fromSpansJSON: json, cache: core.cache) {
            pReplace(selectedRange, with: attributed)
            return
        }
        if pasteboard.hasImages, let core {
            if let data = pasteboard.data(forPasteboardType: UTType.png.identifier) {
                if core.incomingData(data, fileExtension: "png", suggestedName: nil) { return }
            }
            if let data = pasteboard.data(forPasteboardType: UTType.jpeg.identifier) {
                if core.incomingData(data, fileExtension: "jpg", suggestedName: nil) { return }
            }
            if let image = pasteboard.image, let data = image.pngData() {
                if core.incomingData(data, fileExtension: "png", suggestedName: nil) { return }
            }
        }
        if let value = pasteboard.value(forPasteboardType: RichTextClipboard.htmlTypeIdentifier),
           let html = (value as? String) ?? (value as? Data).flatMap({ String(data: $0, encoding: .utf8) }),
           let core,
           let attributed = RichTextClipboard.attributed(fromHTML: html, cache: core.cache) {
            pReplace(selectedRange, with: attributed)
            return
        }
        if let markdown = pasteboard.value(forPasteboardType: RichTextClipboard.markdownTypeIdentifier)
            .flatMap({ ($0 as? String) ?? ($0 as? Data).flatMap { String(data: $0, encoding: .utf8) } })
            ?? pasteboard.string,
           let core,
           let attributed = RichTextClipboard.attributed(fromMarkdown: markdown, cache: core.cache) {
            pReplace(selectedRange, with: attributed)
            return
        }
        super.paste(sender)
    }

    override func pasteAndMatchStyle(_ sender: Any?) {
        guard let text = UIPasteboard.general.string else {
            super.pasteAndMatchStyle(sender)
            return
        }
        insertText(text)
    }
}

struct RichTextEditor: UIViewRepresentable {
    @Environment(\.scenePhase) private var scenePhase

    let noteUrl: String
    let model: NotesModel
    let controller: EditorController
    let contextTracker: ContextTracker

    func makeCoordinator() -> Coordinator {
        Coordinator(core: EditorCore(noteUrl: noteUrl, model: model, controller: controller))
    }

    func makeUIView(context: Context) -> EditorTextView {
        let textView = EditorTextView(usingTextLayoutManager: true)
        textView.textLayoutManager?.delegate = context.coordinator.markers
        textView.textLayoutManager?.renderingAttributesValidator = context.coordinator.core.rendering.validator
        textView.pContentStorage?.delegate = context.coordinator.core.folding
        context.coordinator.markers.foldedHeadingsProvider = { [weak core = context.coordinator.core] in
            core?.folding.foldedHeadings ?? []
        }
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.typingAttributes = RichText.attributes(block: .paragraph, marks: [:])
        textView.linkTextAttributes = [
            .foregroundColor: PColor.pTint,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        textView.delegate = context.coordinator
        textView.core = context.coordinator.core
        textView.alwaysBounceVertical = true
        context.coordinator.markers.driveTypingAttributes(from: textView)
        context.coordinator.markers.driveSelection(from: textView)

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        textView.addGestureRecognizer(tap)

        let press = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTodoPress(_:))
        )
        press.delegate = context.coordinator
        press.cancelsTouchesInView = false
        textView.addGestureRecognizer(press)

        let accessory = UIHostingController(
            rootView: FormatAccessoryBar(controller: controller)
        )
        accessory.view.frame = CGRect(x: 0, y: 0, width: 0, height: 52)
        accessory.view.backgroundColor = .clear
        textView.editorAccessoryView = accessory.view
        textView.inputAccessoryView = accessory.view
        context.coordinator.accessory = accessory

        context.coordinator.core.view = textView
        context.coordinator.core.attachViewToSharedStorage()
        context.coordinator.core.load()
        context.coordinator.core.startContext(contextTracker)
        return textView
    }

    static func dismantleUIView(_ uiView: EditorTextView, coordinator: Coordinator) {
        coordinator.core.detachViewFromSharedStorage()
    }

    func updateUIView(_ uiView: EditorTextView, context: Context) {
        if context.coordinator.core.noteUrl != noteUrl {
            context.coordinator.core.switchTo(noteUrl)
        }
        uiView.suppressesKeyboard = controller.formatVisible
        context.coordinator.scenePhaseChanged(to: scenePhase)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        let core: EditorCore
        let markers = ListMarkerLayoutDelegate()

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView = gesture.view as? EditorTextView else { return }
            let point = gesture.location(in: textView)
            guard !core.inline.hasLiveView(at: point) else { return }
            NotificationCenter.default.post(name: .lushDeactivateEmbeds, object: nil)
            let containerPoint = CGPoint(
                x: point.x - textView.textContainerInset.left,
                y: point.y - textView.textContainerInset.top
            )
            if core.foldHit(at: containerPoint) { return }
            if let todo = core.todoBoxHit(at: containerPoint),
               core.toggleTodo(at: todo) {
                return
            }
            if core.calendarEmbedHit(at: containerPoint) { return }
            guard let charIndex = core.attachmentIndex(at: containerPoint) else { return }
            core.openAttachment(at: charIndex)
        }

        /// The touch equivalent of right-clicking the box: hold it to pick a
        /// state instead of just ticking it.
        @objc func handleTodoPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  let textView = gesture.view as? EditorTextView
            else { return }
            let point = gesture.location(in: textView)
            let containerPoint = CGPoint(
                x: point.x - textView.textContainerInset.left,
                y: point.y - textView.textContainerInset.top
            )
            guard let todo = core.todoBoxHit(at: containerPoint),
                  let state = core.todoState(at: todo)
            else { return }
            let menu = UIMenu(children: TodoState.allCases.map { candidate in
                UIAction(
                    title: candidate.label,
                    state: candidate == state ? .on : .off
                ) { [core] _ in
                    core.setTodoState(candidate, at: todo)
                }
            })
            textView.showTodoMenu(menu, at: point)
        }

        var accessory: UIHostingController<FormatAccessoryBar>?
        private var lastScenePhase: ScenePhase?

        init(core: EditorCore) {
            self.core = core
        }

        func scenePhaseChanged(to phase: ScenePhase) {
            defer { lastScenePhase = phase }
            guard phase == .active, lastScenePhase != nil, lastScenePhase != .active else { return }
            core.windowBecameKey()
            core.checkContextChangeAfterReactivation()
        }

        func textViewDidChange(_ textView: UITextView) {
            core.textDidChange()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            core.refreshFormattingState()
        }

        func textView(
            _ textView: UITextView,
            shouldInteractWith url: URL,
            in characterRange: NSRange,
            interaction: UITextItemInteraction
        ) -> Bool {
            guard url.scheme == "automerge" else { return true }
            core.model.pendingFocusUrl = url.absoluteString
            AppRouter.shared.pending = .note(url.absoluteString)
            return false
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            core.updateMinimapViewport()
            core.scheduleRemoteCaretUpdate()
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            guard core.isLoaded else { return false }
            if text == "\n", core.handleReturn() {
                return false
            }
            if text == " ", range.length == 0,
               core.handleMarkdownTrigger(at: range.location) {
                return false
            }
            if !text.isEmpty {
                core.preserveTypingAttributes(forReplacement: range)
            }
            _ = core.prepareTextSplice(range: range, replacement: text)
            return true
        }

    }
}

/// Slim bar above the keyboard. Formatting lives behind "Aa".
struct FormatAccessoryBar: View {
    let controller: EditorController

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 22) {
                    // the bar rides the keyboard, so the sheet is presented by
                    // the screen instead — dismissing the keyboard takes the
                    // bar and anything it presents with it
                    Button {
                        controller.showFormatPanel()
                    } label: {
                        Text("Aa")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.primary)
                    }
                    .accessibilityLabel("Format")
                    Menu {
                        Button {
                            controller.attachImageFromPanel()
                        } label: {
                            Label("Choose Photo…", systemImage: "photo.on.rectangle")
                        }
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button {
                                controller.cameraPickerVisible = true
                            } label: {
                                Label("Take Photo", systemImage: "camera")
                            }
                        }
                        Button {
                            controller.recorderVisible.toggle()
                        } label: {
                            Label("Record Audio", systemImage: "waveform")
                        }
                        Button {
                            controller.startLiveTranscription()
                        } label: {
                            Label("Live Transcription", systemImage: "mic.fill")
                        }
                        .disabled(controller.liveTranscriptionActive)
                        Button {
                            controller.attachFileFromPanel()
                        } label: {
                            Label("Attach File…", systemImage: "doc")
                        }
                        Divider()
                        Button {
                            controller.insertTable()
                        } label: {
                            Label("Table", systemImage: "tablecells")
                        }
                        Button {
                            controller.insertColumns()
                        } label: {
                            Label("Columns", systemImage: "rectangle.split.2x1")
                        }
                        Button {
                            controller.insertLogline()
                        } label: {
                            Label("Logline", systemImage: "clock")
                        }
                        Button {
                            controller.insertPatchworkDoc()
                        } label: {
                            Label("Patchwork Doc…", systemImage: "shippingbox")
                        }
                    } label: {
                        Image(systemName: "paperclip").foregroundStyle(Color.primary)
                    }
                    .accessibilityLabel("Attach")
                    Menu {
                        ForEach(Highlight.names, id: \.self) { name in
                            Button {
                                controller.applyHighlight(name)
                            } label: {
                                if controller.highlightActive == name {
                                    Label(name.capitalized, systemImage: "checkmark")
                                } else {
                                    Text(name.capitalized)
                                }
                            }
                        }
                        Divider()
                        Button("None") { controller.applyHighlight(nil) }
                    } label: {
                        Image(systemName: "highlighter")
                            .foregroundStyle(controller.highlightActive != nil ? Color.accentColor : Color.primary)
                    }
                    .accessibilityLabel("Highlight")
                    .accessibilityValue(controller.highlightActive?.capitalized ?? "None")
                    barButton("list.bullet", label: "Bulleted List") { controller.applyStyle("unordered-list-item") }
                    barButton("decrease.indent", label: "Decrease Indent") { controller.outdentBlock() }
                    barButton("increase.indent", label: "Increase Indent") { controller.indentBlock() }
                }
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity)
            }
            Divider()
                .frame(height: 28)
            Button {
                controller.dismissKeyboard()
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
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func barButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle(Color.primary)
        }
        .accessibilityLabel(label)
    }
}

/// Notes-style format panel — block styles, marks, and indent.
struct FormatPanel: View {
    let controller: EditorController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(EditorController.styles, id: \.key) { style in
                        let active = controller.currentStyleKey == style.key
                        Button {
                            controller.applyStyle(style.key)
                        } label: {
                            Text(style.label)
                                .font(.system(size: 14, weight: active ? .semibold : .regular))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(active ? Color.accentColor : Color(.secondarySystemFill))
                                .foregroundStyle(active ? Color.white : Color.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                                .contentShape(RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(active ? "Selected" : "Not selected")
                        .accessibilityAddTraits(active ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 20)
            }

            HStack(spacing: 0) {
                markCell("Bold", active: controller.strongActive, action: controller.toggleStrong) {
                    Text("B").font(.system(size: 16, weight: .bold))
                }
                markCell("Italic", active: controller.emActive, action: controller.toggleEm) {
                    Text("I").font(.system(size: 16).italic())
                }
                markCell("Underline", active: controller.underlineActive, action: controller.toggleUnderline) {
                    Text("U").underline().font(.system(size: 16))
                }
                markCell("Strikethrough", active: controller.strikethroughActive, action: controller.toggleStrikethrough) {
                    Text("S").strikethrough().font(.system(size: 16))
                }
                markCell("Inline Code", active: controller.codeActive, action: controller.toggleCode) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 13))
                }
                markCell("Superscript", active: controller.superscriptActive, action: controller.toggleSuperscript) {
                    Image(systemName: "textformat.superscript").font(.system(size: 13))
                }
                markCell("Subscript", active: controller.subscriptActive, action: controller.toggleSubscript) {
                    Image(systemName: "textformat.subscript").font(.system(size: 13))
                }
                markCell("Link", active: controller.linkActive != nil, action: controller.editLink) {
                    Image(systemName: "link").font(.system(size: 13))
                }
                Menu {
                    ForEach(Highlight.names, id: \.self) { name in
                        Button {
                            controller.applyHighlight(name)
                        } label: {
                            if controller.highlightActive == name {
                                Label(name.capitalized, systemImage: "checkmark")
                            } else {
                                Text(name.capitalized)
                            }
                        }
                    }
                    Divider()
                    Button("None") { controller.applyHighlight(nil) }
                } label: {
                    Image(systemName: "highlighter")
                        .font(.system(size: 15))
                        .foregroundStyle(controller.highlightActive != nil ? Color.accentColor : Color.primary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .accessibilityLabel("Highlight")
                .accessibilityValue(controller.highlightActive?.capitalized ?? "None")
            }
            .frame(height: 44)
            .background(Color(.secondarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 20)

            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    indentCell("increase.indent", label: "Increase Indent") { controller.indentBlock() }
                    indentCell("decrease.indent", label: "Decrease Indent") { controller.outdentBlock() }
                }
                .frame(height: 44)
                .background(Color(.secondarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                Spacer()
            }
            .padding(.horizontal, 20)

            if controller.isCodeBlockActive {
                Menu {
                    ForEach(CodeLanguage.all) { language in
                        Button {
                            controller.applyCodeLanguage(language)
                        } label: {
                            if controller.currentCodeLanguage == language.id {
                                Label(language.name, systemImage: "checkmark")
                            } else {
                                Text(language.name)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text("Language").foregroundStyle(Color.secondary)
                        Spacer()
                        Text(CodeLanguage.named(controller.currentCodeLanguage).name)
                        Image(systemName: "chevron.up.chevron.down").uiFont(.caption2)
                    }
                    .font(.system(size: 15))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .background(Color(.secondarySystemFill))
                    .foregroundStyle(Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .padding(.horizontal, 20)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private func markCell(_ name: String, active: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button(action: action) {
            label()
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityValue(active ? "Selected" : "Not selected")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func indentCell(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(Color.primary)
                .frame(width: 52)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

#endif
