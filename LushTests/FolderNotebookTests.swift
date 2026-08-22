import Foundation
import XCTest
@testable import Lush

/// A two-note notebook laid out as:
///
///     0 ..< 5   title "Alpha"
///     5         newline closing the title
///     6 ..< 11  body "alpha"
///     11        newline opening Beta's boundary
///     12 ..< 16 title "Beta"
///     16        newline closing the title
///     17 ..< 21 body "beta"
@MainActor
final class FolderNotebookTests: XCTestCase {
    private let alpha = "automerge:alpha"
    private let beta = "automerge:beta"

    private let stuff = "automerge:stuff"

    private func makeDocument() -> NotebookDocument {
        let document = NotebookDocument()
        document.rebuild([
            .note(.init(url: alpha, title: "Alpha", body: body("alpha"))),
            .note(.init(url: beta, title: "Beta", body: body("beta"))),
        ])
        return document
    }

    /// The two-note notebook with a folder row between them:
    ///
    ///     0 ..< 5   title "Alpha"
    ///     5         newline closing the title
    ///     6 ..< 11  body "alpha"
    ///     11        newline opening the link row
    ///     12 ..< 19 the row: icon, space, "Stuff"
    ///     19        newline closing the row
    ///     20        newline opening Beta's boundary
    ///     21 ..< 25 title "Beta"
    ///     25        newline closing the title
    ///     26 ..< 30 body "beta"
    private func makeMixedDocument() -> NotebookDocument {
        let document = NotebookDocument()
        document.rebuild([
            .note(.init(url: alpha, title: "Alpha", body: body("alpha"))),
            .link(.init(url: stuff, title: "Stuff", symbol: "folder")),
            .note(.init(url: beta, title: "Beta", body: body("beta"))),
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

    func testConcatenatesTitlesAndBodiesInOrder() {
        let document = makeDocument()
        XCTAssertEqual(document.storage.string, "Alpha\nalpha\nBeta\nbeta")
        XCTAssertEqual(document.order, [alpha, beta])
    }

    func testEmptyNoteStillHasSomewhereToPutTheCaret() {
        let document = NotebookDocument()
        document.rebuild([.note(.init(url: alpha, title: "Alpha", body: NSAttributedString()))])
        XCTAssertEqual(document.note(forCaretAt: 6), alpha)
    }

    // MARK: - Ownership

    func testBodyCharactersBelongToTheirNote() {
        let document = makeDocument()
        XCTAssertEqual(document.owner(at: 6), alpha)
        XCTAssertEqual(document.owner(at: 10), alpha)
        XCTAssertEqual(document.owner(at: 17), beta)
        XCTAssertEqual(document.owner(at: 20), beta)
    }

    func testStructureBelongsToNoNote() {
        let document = makeDocument()
        for location in [0, 5, 11, 12, 16] {
            XCTAssertNil(document.owner(at: location), "location \(location)")
            XCTAssertTrue(document.isBoundary(at: location), "location \(location)")
        }
    }

    func testTitleCharactersCarryTheirNote() {
        let document = makeDocument()
        XCTAssertEqual(document.titleOwner(at: 0), alpha)
        XCTAssertEqual(document.titleOwner(at: 4), alpha)
        XCTAssertEqual(document.titleOwner(at: 12), beta)
        XCTAssertEqual(document.titleOwner(at: 15), beta)
        XCTAssertNil(document.titleOwner(at: 5))
        XCTAssertNil(document.titleOwner(at: 6))
    }

    /// A caret at the head of a note sits just past a boundary, where looking
    /// backwards alone would answer with the note above it.
    func testCaretAtTheHeadOfANoteWritesIntoThatNote() {
        let document = makeDocument()
        XCTAssertEqual(document.note(forCaretAt: 6), alpha)
        XCTAssertEqual(document.note(forCaretAt: 17), beta)
    }

    /// Typing at the very end of a note appends to it rather than falling into
    /// the boundary that follows.
    func testCaretAtTheTailOfANoteWritesIntoThatNote() {
        let document = makeDocument()
        XCTAssertEqual(document.note(forCaretAt: 11), alpha)
        XCTAssertEqual(document.note(forCaretAt: 21), beta)
    }

    func testCaretInATitleEditsThatTitle() {
        let document = makeDocument()
        XCTAssertEqual(document.title(forCaretAt: 0), alpha)
        XCTAssertEqual(document.title(forCaretAt: 5), alpha)
        XCTAssertEqual(document.title(forCaretAt: 12), beta)
        XCTAssertEqual(document.title(forCaretAt: 16), beta)
        XCTAssertNil(document.title(forCaretAt: 8))
    }

    // MARK: - Edit rules

    func testTypingInsideABodyIsAllowed() {
        let document = makeDocument()
        XCTAssertTrue(document.allowsEdit(in: NSRange(location: 8, length: 0), replacement: "x"))
        XCTAssertTrue(document.allowsEdit(in: NSRange(location: 6, length: 5), replacement: "new"))
    }

    func testAnEditMayNotSpanTwoNotes() {
        let document = makeDocument()
        XCTAssertFalse(document.allowsEdit(in: NSRange(location: 6, length: 15), replacement: ""))
    }

    func testAnEditMayNotTouchABoundary() {
        let document = makeDocument()
        // The newline that closes Alpha's title.
        XCTAssertFalse(document.allowsEdit(in: NSRange(location: 5, length: 1), replacement: ""))
        // The newline that opens Beta's boundary.
        XCTAssertFalse(document.allowsEdit(in: NSRange(location: 11, length: 1), replacement: ""))
    }

    /// The case the hard boundary exists for: backspace at the top of a note
    /// must not swallow the note above it.
    func testBackspaceAtTheTopOfANoteIsRefused() {
        let document = makeDocument()
        XCTAssertFalse(document.allowsEdit(in: NSRange(location: 16, length: 1), replacement: ""))
    }

    func testTypingInsideATitleIsAllowed() {
        let document = makeDocument()
        XCTAssertTrue(document.allowsEdit(in: NSRange(location: 2, length: 0), replacement: "x"))
        XCTAssertTrue(document.allowsEdit(in: NSRange(location: 0, length: 2), replacement: ""))
    }

    func testATitleIsOneLine() {
        let document = makeDocument()
        XCTAssertFalse(document.allowsEdit(in: NSRange(location: 2, length: 0), replacement: "\n"))
        XCTAssertFalse(document.allowsEdit(in: NSRange(location: 0, length: 5), replacement: "a\nb"))
    }

    /// Retyping a whole title is ordinary; emptying one would leave nowhere to
    /// put the caret and no way to name the note again.
    func testAWholeTitleMayBeRetypedButNotDeleted() {
        let document = makeDocument()
        let whole = NSRange(location: 0, length: 5)
        XCTAssertTrue(document.allowsEdit(in: whole, replacement: "Renamed"))
        XCTAssertFalse(document.allowsEdit(in: whole, replacement: ""))
    }

    func testAnEditMayNotSpanATitleAndItsBody() {
        let document = makeDocument()
        XCTAssertFalse(document.allowsEdit(in: NSRange(location: 3, length: 5), replacement: ""))
    }

    // MARK: - Typing attributes

    func testTypingAtTheTailOfANoteStaysWithThatNote() {
        let document = makeDocument()
        let attributes = document.typingAttributes(from: [:], at: 11)
        XCTAssertEqual(attributes[notebookNote] as? String, alpha)
        XCTAssertNil(attributes[notebookTitle])
    }

    func testTypingAtTheHeadOfATitleStaysInTheTitle() {
        let document = makeDocument()
        let attributes = document.typingAttributes(from: [:], at: 12)
        XCTAssertEqual(attributes[notebookTitle] as? String, beta)
        XCTAssertNil(attributes[notebookNote])
    }

    /// Moving from a title into a body has to clear the title stamp, or the
    /// body text would be saved as part of the note's name.
    func testMovingOutOfATitleClearsTheTitleStamp() {
        let document = makeDocument()
        let inTitle = document.typingAttributes(from: [:], at: 12)
        let inBody = document.typingAttributes(from: inTitle, at: 18)
        XCTAssertNil(inBody[notebookTitle])
        XCTAssertEqual(inBody[notebookNote] as? String, beta)
    }

    // MARK: - Reading back

    func testBodiesSliceBackToTheirOwnNotes() {
        let document = makeDocument()
        let bodies = document.bodies()
        XCTAssertEqual(bodies[alpha]?.string, "alpha")
        XCTAssertEqual(bodies[beta]?.string, "beta")
    }

    /// Neither the title nor the newlines around it may reach a note's slice —
    /// a trailing newline there would save an empty paragraph onto every note.
    func testBodiesExcludeTitlesAndStructure() {
        let document = makeDocument()
        for text in document.bodies().values {
            XCTAssertFalse(text.string.contains("\n"))
            XCTAssertFalse(text.string.contains("Alpha"))
            XCTAssertFalse(text.string.contains("Beta"))
        }
    }

    func testTitlesReadBackFromTheirRuns() {
        let document = makeDocument()
        XCTAssertEqual(document.titles(), [alpha: "Alpha", beta: "Beta"])
    }

    /// The whole rename path in miniature: the caret stamps what it is typing
    /// into, and the title reads back with the new text in it.
    func testTextTypedIntoATitleBecomesPartOfTheName() {
        let document = makeDocument()
        let attributes = document.typingAttributes(from: [:], at: 5)
        document.storage.insert(NSAttributedString(string: "!", attributes: attributes), at: 5)
        XCTAssertEqual(document.titles()[alpha], "Alpha!")
        XCTAssertEqual(document.bodies()[alpha]?.string, "alpha")
    }

    /// The counterpart, and the property the whole ownership scheme exists
    /// for: typing at a note's tail extends that note, not the one below it.
    func testTextTypedAtTheTailOfANoteBecomesPartOfIt() {
        let document = makeDocument()
        let attributes = document.typingAttributes(from: [:], at: 11)
        document.storage.insert(NSAttributedString(string: "!", attributes: attributes), at: 11)
        XCTAssertEqual(document.bodies()[alpha]?.string, "alpha!")
        XCTAssertEqual(document.bodies()[beta]?.string, "beta")
    }

    // MARK: - Edit targets

    func testAnEditKnowsWhichNoteItIsIn() {
        let document = makeDocument()
        XCTAssertEqual(document.target(forEditIn: NSRange(location: 8, length: 0))?.url, alpha)
        XCTAssertEqual(document.target(forEditIn: NSRange(location: 18, length: 2))?.url, beta)
        XCTAssertEqual(document.target(forEditIn: NSRange(location: 11, length: 0))?.url, alpha)
    }

    func testAnEditInATitleIsMarkedAsOne() {
        let document = makeDocument()
        XCTAssertEqual(document.target(forEditIn: NSRange(location: 2, length: 0))?.isTitle, true)
        XCTAssertEqual(document.target(forEditIn: NSRange(location: 12, length: 3))?.url, beta)
        XCTAssertEqual(document.target(forEditIn: NSRange(location: 12, length: 3))?.isTitle, true)
        XCTAssertEqual(document.target(forEditIn: NSRange(location: 8, length: 0))?.isTitle, false)
    }

    // MARK: - Claiming

    /// What paste does: text lands carrying no stamp at all, and reads back
    /// as part of no note until it is claimed.
    func testUnstampedTextIsClaimedByTheNoteItLandedIn() {
        let document = makeDocument()
        let target = document.target(forEditIn: NSRange(location: 8, length: 0))
        document.storage.insert(NSAttributedString(string: "XY"), at: 8)
        XCTAssertEqual(document.bodies()[alpha]?.string, "alpha")

        document.claim(
            NSRange(location: 8, length: 2),
            for: target!.url,
            asTitle: target!.isTitle
        )
        XCTAssertEqual(document.bodies()[alpha]?.string, "alXYpha")
    }

    /// The worse half: text copied out of one note keeps that note's stamp,
    /// so without claiming it saves into the note it came from.
    func testTextCarryingAnotherNotesStampIsReclaimed() {
        let document = makeDocument()
        let stolen = document.storage.attributedSubstring(from: NSRange(location: 6, length: 5))
        let target = document.target(forEditIn: NSRange(location: 21, length: 0))
        document.storage.insert(stolen, at: 21)
        XCTAssertEqual(document.bodies()[alpha]?.string, "alphaalpha")

        document.claim(
            NSRange(location: 21, length: stolen.length),
            for: target!.url,
            asTitle: target!.isTitle
        )
        XCTAssertEqual(document.bodies()[alpha]?.string, "alpha")
        XCTAssertEqual(document.bodies()[beta]?.string, "betaalpha")
    }

    func testTextClaimedByATitleBecomesPartOfTheName() {
        let document = makeDocument()
        let target = document.target(forEditIn: NSRange(location: 5, length: 0))
        document.storage.insert(NSAttributedString(string: "!"), at: 5)
        document.claim(
            NSRange(location: 5, length: 1),
            for: target!.url,
            asTitle: target!.isTitle
        )
        XCTAssertEqual(document.titles()[alpha], "Alpha!")
        XCTAssertEqual(document.bodies()[alpha]?.string, "alpha")
    }

    // MARK: - Link rows

    func testLinkRowSitsBetweenNotesInOrder() {
        let document = makeMixedDocument()
        XCTAssertEqual(document.storage.string, "Alpha\nalpha\n\u{FFFC} Stuff\n\nBeta\nbeta")
        // Only notes reach the save pass.
        XCTAssertEqual(document.order, [alpha, beta])
    }

    func testLinkRowIsStructureBelongingToNoNote() {
        let document = makeMixedDocument()
        for location in 11...20 {
            XCTAssertNil(document.owner(at: location), "location \(location)")
            XCTAssertNil(document.titleOwner(at: location), "location \(location)")
            XCTAssertTrue(document.isBoundary(at: location), "location \(location)")
        }
    }

    /// The whole row is the button: its glyphs, and the position a click in
    /// its empty tail resolves to. The row's leading newline carries no link,
    /// so a click resolving to the end of the note above must not open the
    /// folder — that position still writes into the note, per the caret rule.
    func testLinkIsFoundAcrossItsWholeRow() {
        let document = makeMixedDocument()
        XCTAssertEqual(document.link(nearCaretAt: 12), stuff)
        XCTAssertEqual(document.link(nearCaretAt: 15), stuff)
        XCTAssertEqual(document.link(nearCaretAt: 19), stuff)
        XCTAssertNil(document.link(nearCaretAt: 11))
        XCTAssertNil(document.link(nearCaretAt: 21))
    }

    func testEditsInsideALinkRowAreRefused() {
        let document = makeMixedDocument()
        XCTAssertFalse(document.allowsEdit(in: NSRange(location: 14, length: 0), replacement: "x"))
        XCTAssertFalse(document.allowsEdit(in: NSRange(location: 12, length: 7), replacement: ""))
        XCTAssertFalse(document.allowsEdit(in: NSRange(location: 19, length: 1), replacement: ""))
        XCTAssertFalse(document.allowsEdit(in: NSRange(location: 6, length: 15), replacement: ""))
    }

    func testNotesAroundALinkRowStayEditable() {
        let document = makeMixedDocument()
        XCTAssertTrue(document.allowsEdit(in: NSRange(location: 11, length: 0), replacement: "x"))
        XCTAssertTrue(document.allowsEdit(in: NSRange(location: 26, length: 0), replacement: "x"))
        XCTAssertEqual(document.note(forCaretAt: 11), alpha)
        XCTAssertEqual(document.note(forCaretAt: 26), beta)
    }

    func testLinkRowsNeverReachSavedContent() {
        let document = makeMixedDocument()
        let bodies = document.bodies()
        XCTAssertEqual(Set(bodies.keys), [alpha, beta])
        XCTAssertEqual(bodies[alpha]?.string, "alpha")
        XCTAssertEqual(bodies[beta]?.string, "beta")
        XCTAssertEqual(document.titles(), [alpha: "Alpha", beta: "Beta"])
    }

    func testTypingNearALinkDropsTheLinkStamp() {
        let document = makeMixedDocument()
        let attributes = document.typingAttributes(from: [notebookLink: stuff], at: 11)
        XCTAssertNil(attributes[notebookLink])
        XCTAssertEqual(attributes[notebookNote] as? String, alpha)
    }

    /// Text copied out of a link row and pasted into a note arrives wearing
    /// the link stamp; claiming strips it, or the pasted words would still be
    /// a button.
    func testClaimStripsTheLinkStamp() {
        let document = makeMixedDocument()
        let row = document.storage.attributedSubstring(from: NSRange(location: 13, length: 6))
        document.storage.insert(row, at: 8)
        document.claim(NSRange(location: 8, length: 6), for: alpha, asTitle: false)
        XCTAssertNil(document.link(at: 8))
        XCTAssertEqual(document.bodies()[alpha]?.string, "al Stuffpha")
        XCTAssertEqual(document.owner(at: 8), alpha)
    }

    /// A notebook of nothing but links is navigation, not writing surface.
    func testNotebookOfOnlyLinksRefusesTyping() {
        let document = NotebookDocument()
        document.rebuild([.link(.init(url: stuff, title: "Stuff", symbol: "folder"))])
        XCTAssertTrue(document.order.isEmpty)
        for location in 0...document.storage.length {
            XCTAssertFalse(
                document.allowsEdit(in: NSRange(location: location, length: 0), replacement: "x"),
                "location \(location)"
            )
        }
    }

    // MARK: - Separators

    /// One rule between each pair of notes, and none above the first — it has
    /// nothing to be separated from.
    func testSeparatorSitsBetweenNotesOnly() {
        let document = makeDocument()
        XCTAssertEqual(document.separatorLocations(), [12])
    }

    func testSingleNoteHasNoSeparator() {
        let document = NotebookDocument()
        document.rebuild([.note(.init(url: alpha, title: "Alpha", body: body("alpha")))])
        XCTAssertTrue(document.separatorLocations().isEmpty)
    }
}
