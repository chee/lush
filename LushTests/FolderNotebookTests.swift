import Foundation
import XCTest
@testable import Lush

/// A two-note notebook laid out as:
///
///     0 ..< 5   body "alpha"
///     5         newline closing Alpha, opening Beta's boundary
///     6         the boundary's own line, empty
///     7 ..< 11  body "beta"
///
/// A note's name is its own first heading, which its content already carries,
/// so nothing between two notes is text: the boundary is the room the rule is
/// drawn in and nothing else.
@MainActor
final class FolderNotebookTests: XCTestCase {
    private let alpha = "automerge:alpha"
    private let beta = "automerge:beta"

    private func makeDocument() -> NotebookDocument {
        let document = NotebookDocument()
        document.rebuild([
            .init(url: alpha, body: body("alpha")),
            .init(url: beta, body: body("beta")),
        ])
        return document
    }

    private func body(_ string: String) -> NSAttributedString {
        NSAttributedString(
            string: string,
            attributes: RichText.attributes(block: .paragraph, marks: [:])
        )
    }

    // MARK: - Layout

    func testConcatenatesBodiesInOrder() {
        let document = makeDocument()
        XCTAssertEqual(document.storage.string, "alpha\n\nbeta")
        XCTAssertEqual(document.order, [alpha, beta])
    }

    /// The first of the folder's own notes starts the document: there is
    /// nothing above it to be separated from.
    func testTheFirstNoteOpensTheDocument() {
        let document = NotebookDocument()
        document.rebuild([.init(url: alpha, body: body("alpha"))])
        XCTAssertEqual(document.storage.string, "alpha")
        XCTAssertEqual(document.owner(at: 0), alpha)
    }

    func testEmptyNoteStillHasSomewhereToPutTheCaret() {
        let document = NotebookDocument()
        document.rebuild([.init(url: alpha, body: NSAttributedString())])
        XCTAssertEqual(document.note(forCaretAt: 0), alpha)
    }

    // MARK: - Ownership

    func testBodyCharactersBelongToTheirNote() {
        let document = makeDocument()
        XCTAssertEqual(document.owner(at: 0), alpha)
        XCTAssertEqual(document.owner(at: 4), alpha)
        XCTAssertEqual(document.owner(at: 7), beta)
        XCTAssertEqual(document.owner(at: 10), beta)
    }

    func testStructureBelongsToNoNote() {
        let document = makeDocument()
        for location in [5, 6] {
            XCTAssertNil(document.owner(at: location), "location \(location)")
            XCTAssertTrue(document.isBoundary(at: location), "location \(location)")
        }
    }

    /// A caret at the head of a note sits just past a boundary, where looking
    /// backwards alone would answer with the note above it.
    func testCaretAtTheHeadOfANoteWritesIntoThatNote() {
        let document = makeDocument()
        XCTAssertEqual(document.note(forCaretAt: 0), alpha)
        XCTAssertEqual(document.note(forCaretAt: 7), beta)
    }

    /// Typing at the very end of a note appends to it rather than falling into
    /// the boundary that follows.
    func testCaretAtTheTailOfANoteWritesIntoThatNote() {
        let document = makeDocument()
        XCTAssertEqual(document.note(forCaretAt: 5), alpha)
        XCTAssertEqual(document.note(forCaretAt: 11), beta)
    }

    func testCaretInTheGapBetweenTwoNotesBelongsToNeither() {
        let document = makeDocument()
        XCTAssertNil(document.note(forCaretAt: 6))
    }

    // MARK: - Edit rules

    func testTypingInsideABodyIsAllowed() {
        let document = makeDocument()
        XCTAssertTrue(document.allowsEdit(in: NSRange(location: 2, length: 0)))
        XCTAssertTrue(document.allowsEdit(in: NSRange(location: 0, length: 5)))
    }

    func testAnEditMayNotSpanTwoNotes() {
        let document = makeDocument()
        XCTAssertFalse(document.allowsEdit(in: NSRange(location: 0, length: 11)))
    }

    func testAnEditMayNotTouchABoundary() {
        let document = makeDocument()
        // The newline that closes Alpha.
        XCTAssertFalse(document.allowsEdit(in: NSRange(location: 5, length: 1)))
        // The boundary's own line.
        XCTAssertFalse(document.allowsEdit(in: NSRange(location: 6, length: 1)))
    }

    /// The case the hard boundary exists for: backspace at the top of a note
    /// must not swallow the note above it.
    func testBackspaceAtTheTopOfANoteIsRefused() {
        let document = makeDocument()
        XCTAssertFalse(document.allowsEdit(in: NSRange(location: 6, length: 1)))
    }

    func testTypingInTheGapIsRefused() {
        let document = makeDocument()
        XCTAssertFalse(document.allowsEdit(in: NSRange(location: 6, length: 0)))
    }

    // MARK: - Typing attributes

    func testTypingAtTheTailOfANoteStaysWithThatNote() {
        let document = makeDocument()
        let attributes = document.typingAttributes(from: [:], at: 5)
        XCTAssertEqual(attributes[notebookNote] as? String, alpha)
    }

    func testTypingAtTheHeadOfANoteStaysWithThatNote() {
        let document = makeDocument()
        let attributes = document.typingAttributes(from: [:], at: 7)
        XCTAssertEqual(attributes[notebookNote] as? String, beta)
    }

    /// Text typed just past a boundary inherits the boundary's stamp, which
    /// has to come off or `bodies()` would drop it on the floor.
    func testTypingClearsTheBoundaryStamp() {
        let document = makeDocument()
        let attributes = document.typingAttributes(from: [notebookBoundary: true], at: 7)
        XCTAssertNil(attributes[notebookBoundary])
        XCTAssertEqual(attributes[notebookNote] as? String, beta)
    }

    // MARK: - Reading back

    func testBodiesSliceBackToTheirOwnNotes() {
        let document = makeDocument()
        let bodies = document.bodies()
        XCTAssertEqual(bodies[alpha]?.string, "alpha")
        XCTAssertEqual(bodies[beta]?.string, "beta")
    }

    /// None of the structure may reach a note's slice — a trailing newline
    /// there would save an empty paragraph onto every note.
    func testBodiesExcludeStructure() {
        let document = makeDocument()
        for text in document.bodies().values {
            XCTAssertFalse(text.string.contains("\n"))
        }
    }

    /// The counterpart, and the property the whole ownership scheme exists
    /// for: typing at a note's tail extends that note, not the one below it.
    func testTextTypedAtTheTailOfANoteBecomesPartOfIt() {
        let document = makeDocument()
        let attributes = document.typingAttributes(from: [:], at: 5)
        document.storage.insert(NSAttributedString(string: "!", attributes: attributes), at: 5)
        XCTAssertEqual(document.bodies()[alpha]?.string, "alpha!")
        XCTAssertEqual(document.bodies()[beta]?.string, "beta")
    }

    // MARK: - Edit targets

    func testAnEditKnowsWhichNoteItIsIn() {
        let document = makeDocument()
        XCTAssertEqual(document.target(forEditIn: NSRange(location: 2, length: 0)), alpha)
        XCTAssertEqual(document.target(forEditIn: NSRange(location: 8, length: 2)), beta)
        XCTAssertEqual(document.target(forEditIn: NSRange(location: 5, length: 0)), alpha)
    }

    func testAnEditInTheGapBelongsToNoNote() {
        let document = makeDocument()
        XCTAssertNil(document.target(forEditIn: NSRange(location: 6, length: 0)))
    }

    // MARK: - Claiming

    /// What paste does: text lands carrying no stamp at all, and reads back
    /// as part of no note until it is claimed.
    func testUnstampedTextIsClaimedByTheNoteItLandedIn() {
        let document = makeDocument()
        let target = document.target(forEditIn: NSRange(location: 2, length: 0))
        document.storage.insert(NSAttributedString(string: "XY"), at: 2)
        XCTAssertEqual(document.bodies()[alpha]?.string, "alpha")

        document.claim(NSRange(location: 2, length: 2), for: target!)
        XCTAssertEqual(document.bodies()[alpha]?.string, "alXYpha")
    }

    /// The worse half: text copied out of one note keeps that note's stamp,
    /// so without claiming it saves into the note it came from.
    func testTextCarryingAnotherNotesStampIsReclaimed() {
        let document = makeDocument()
        let stolen = document.storage.attributedSubstring(from: NSRange(location: 0, length: 5))
        let target = document.target(forEditIn: NSRange(location: 11, length: 0))
        document.storage.insert(stolen, at: 11)
        XCTAssertEqual(document.bodies()[alpha]?.string, "alphaalpha")

        document.claim(NSRange(location: 11, length: stolen.length), for: target!)
        XCTAssertEqual(document.bodies()[alpha]?.string, "alpha")
        XCTAssertEqual(document.bodies()[beta]?.string, "betaalpha")
    }

    // MARK: - Where the caret goes

    /// Adding a note puts the caret at the end of it, which for a note with
    /// nothing in it yet is the only place there is.
    func testANotesRangeIsAllOfItAndNoneOfTheStructure() {
        let document = makeDocument()
        XCTAssertEqual(document.range(of: alpha), NSRange(location: 0, length: 5))
        XCTAssertEqual(document.range(of: beta), NSRange(location: 7, length: 4))
        XCTAssertNil(document.range(of: "automerge:missing"))
    }

    // MARK: - Notes found in subfolders

    /// The layout a nested note gets, and the offsets the rest of these turn
    /// on:
    ///
    ///     0 ..< 4   path "Trip"
    ///     4         newline closing it
    ///     5 ..< 10  body "waves"
    private func makeNested() -> NotebookDocument {
        let document = NotebookDocument()
        document.rebuild([.init(url: alpha, path: "Trip", body: body("waves"))])
        return document
    }

    func testTheFolderPathIsDrawnAboveTheNote() {
        let document = makeNested()
        XCTAssertEqual(document.storage.string, "Trip\nwaves")
    }

    /// The path says where the note is, not what it is called, so it must not
    /// reach the note's own text.
    func testTheFolderPathIsNotPartOfTheNote() {
        let document = makeNested()
        XCTAssertEqual(document.bodies()[alpha]?.string, "waves")
    }

    func testTheFolderPathBelongsToNoNote() {
        let document = makeNested()
        for location in 0..<5 {
            XCTAssertNil(document.owner(at: location), "location \(location)")
            XCTAssertTrue(document.isBoundary(at: location), "location \(location)")
        }
    }

    func testTheFolderPathCannotBeTypedIn() {
        let document = makeNested()
        XCTAssertFalse(document.allowsEdit(in: NSRange(location: 2, length: 0)))
        XCTAssertFalse(document.allowsEdit(in: NSRange(location: 0, length: 4)))
        // and an edit may not reach out of the note into it
        XCTAssertFalse(document.allowsEdit(in: NSRange(location: 4, length: 3)))
    }

    /// A folder's own notes carry no path and open the document directly.
    func testANoteInTheFolderItselfGetsNoPath() {
        let document = NotebookDocument()
        document.rebuild([.init(url: alpha, body: body("alpha"))])
        XCTAssertEqual(document.storage.string, "alpha")
    }

    // MARK: - Separators

    /// One rule between each pair of notes, and none above the first — it has
    /// nothing to be separated from.
    func testSeparatorSitsBetweenNotesOnly() {
        let document = makeDocument()
        XCTAssertEqual(document.separatorLocations(), [6])
    }

    /// The rule goes above the whole boundary line, path and all — drawn under
    /// the path it would cut the note away from where it is kept.
    func testTheSeamSitsAboveTheFolderPath() {
        let document = NotebookDocument()
        document.rebuild([
            .init(url: alpha, body: body("alpha")),
            .init(url: beta, path: "Trip", body: body("waves")),
        ])
        XCTAssertEqual(document.storage.string, "alpha\nTrip\nwaves")
        XCTAssertEqual(document.separatorLocations(), [6])
    }

    func testSingleNoteHasNoSeparator() {
        let document = NotebookDocument()
        document.rebuild([.init(url: alpha, body: body("alpha"))])
        XCTAssertTrue(document.separatorLocations().isEmpty)
    }

    /// A nested note at the top of the notebook still draws its path, and
    /// still gets no rule above it.
    func testANestedFirstNoteHasNoSeparator() {
        let document = makeNested()
        XCTAssertTrue(document.separatorLocations().isEmpty)
    }
}
