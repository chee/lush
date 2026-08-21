import Foundation
import XCTest
@testable import Lush

final class SpanDocTests: XCTestCase {
    func testStrayEmbedTextPreservesLineSeparatorAtMarkBoundary() {
        let text = NSMutableAttributedString(string: "before\u{2028}after\u{FFFC}\n")
        text.addAttribute(
            .amBlock,
            value: BlockBox(BlockValue.embed(url: "automerge:test")),
            range: NSRange(location: 0, length: text.length)
        )
        text.addAttribute(
            .amCode,
            value: true,
            range: NSRange(location: 0, length: ("before\u{2028}" as NSString).length)
        )

        let roundTripped = RichText.spans(from: text).compactMap { node -> String? in
            guard case .text(let value, _) = node else { return nil }
            return value
        }.joined()

        XCTAssertEqual(roundTripped, "before\u{2028}after")
    }

    /// A logline draws itself from its attrs, so its own characters are
    /// display-only and are not encoded. Words typed onto the same line are
    /// not the block's, and the encoder used to drop the paragraph whole.
    func testWordsTypedOntoALoglineSurviveEncoding() {
        let rendered = "12:04 | Glasgow"
        let text = NSMutableAttributedString(string: rendered + "and my own words")
        text.addAttribute(
            .amBlock,
            value: BlockBox(BlockValue(type: "context")),
            range: NSRange(location: 0, length: text.length)
        )
        text.addAttribute(
            .amDisplayOnly,
            value: true,
            range: NSRange(location: 0, length: (rendered as NSString).length)
        )

        let spans = RichText.spans(from: text)
        let encoded = spans.compactMap { node -> String? in
            guard case .text(let value, _) = node else { return nil }
            return value
        }.joined()

        XCTAssertEqual(encoded, "and my own words")
    }

    private func logline(zone: String) -> String? {
        BlockValue(
            type: "context",
            attrs: ["ts": .string("2026-08-21T04:04:00Z"), "tz": .string(zone)],
            isEmbed: true
        ).contextDisplayStamp
    }

    /// A logline is a record of a moment somewhere, so it reads back in the
    /// zone it was stamped in. Rendering it in the reader's zone would rewrite
    /// every entry in the notebook the first time you flew home.
    func testALoglineReadsBackInTheZoneItWasStampedIn() {
        guard let tokyo = logline(zone: "Asia/Tokyo"),
              let losAngeles = logline(zone: "America/Los_Angeles")
        else { return XCTFail("a stamped logline should say when it was written") }

        XCTAssertNotEqual(tokyo, losAngeles, "the stored zone should decide how a stamp reads")
    }

    /// The stamped logline used to carry the time alone, so a note read a month
    /// later couldn't say which day it was written on.
    func testAStampedLoglineCarriesTheWholeDate() {
        guard let stamp = logline(zone: "UTC") else {
            return XCTFail("a stamped logline should say when it was written")
        }

        XCTAssertTrue(stamp.contains("2026"), stamp)
        XCTAssertTrue(stamp.contains("21"), stamp)
    }

    /// Falling back to the reader's zone is fine; silently printing a time in
    /// one zone under the name of another is not.
    func testALoglineWithNoStoredZoneUsesTheReadersOwn() {
        let stamp = BlockValue(
            type: "context",
            attrs: ["ts": .string("2026-08-21T04:04:00Z")],
            isEmbed: true
        ).contextDisplayStamp

        XCTAssertEqual(stamp, logline(zone: TimeZone.current.identifier))
    }

    private func contextBlock(_ attrs: [String: JSONValue]) -> BlockValue {
        BlockValue(type: "context", attrs: attrs, isEmbed: true)
    }

    /// The form covers when and where; the tracker stamps more than that. An
    /// edit must not quietly drop what it can't show.
    func testEditingALoglineKeepsWhatTheFormDoesNotCover() {
        let existing = contextBlock([
            "ts": .string("2026-08-21T04:04:00Z"),
            "tz": .string("UTC"),
            "nowPlaying": .string("Aphex Twin"),
        ])
        var draft = LoglineDraft(block: existing)
        draft.location = "Glasgow"

        let saved = draft.applied(to: existing)

        XCTAssertEqual(saved.attrs["nowPlaying"]?.stringValue, "Aphex Twin")
        XCTAssertEqual(saved.attrs["location"]?.stringValue, "Glasgow")
    }

    /// A lone or impossible coordinate would put a Maps pin somewhere the
    /// logline never was, which is worse than having no pin at all.
    func testAnUnusableCoordinateIsNotSaved() {
        var half = LoglineDraft(block: nil)
        half.latitude = "55.86"
        var outOfRange = LoglineDraft(block: nil)
        outOfRange.latitude = "155.0"
        outOfRange.longitude = "4.2"

        XCTAssertTrue(half.coordinateIsBroken)
        XCTAssertTrue(outOfRange.coordinateIsBroken)
        XCTAssertNil(half.applied(to: nil).attrs["lat"])
        XCTAssertNil(outOfRange.applied(to: nil).attrs["lat"])
    }

    func testAUsableCoordinateIsSavedAsAPair() {
        var draft = LoglineDraft(block: nil)
        draft.latitude = "55.86"
        draft.longitude = "-4.25"

        let saved = draft.applied(to: nil)

        XCTAssertFalse(draft.coordinateIsBroken)
        XCTAssertEqual(saved.attrs["lat"]?.doubleValue, 55.86)
        XCTAssertEqual(saved.attrs["lon"]?.doubleValue, -4.25)
    }

    /// A note has one opening logline. Editing it must not turn it into an
    /// ordinary stamp, which would leave the note with none.
    func testEditingACreationLoglineLeavesItACreationLogline() {
        let existing = contextBlock(["created": .string("2026-08-21T04:04:00Z")])
        var draft = LoglineDraft(block: existing)
        draft.location = "Glasgow"

        let saved = draft.applied(to: existing)

        XCTAssertNotNil(saved.attrs["created"])
        XCTAssertNil(saved.attrs["ts"])
    }

    /// Filled in by hand, so there is nothing for a refresh to chase — and a
    /// spinner that never stops is what would be left otherwise.
    func testAHandWrittenLoglineIsNotPending() {
        let existing = contextBlock([
            "ts": .string("2026-08-21T04:04:00Z"),
            "pending": .bool(true),
        ])

        XCTAssertFalse(LoglineDraft(block: existing).applied(to: existing).isPendingContext)
    }

    func testALoglineNobodyTypedOnEncodesToItsBlockAlone() {
        let text = NSMutableAttributedString(string: "12:04 | Glasgow")
        text.addAttribute(
            .amBlock,
            value: BlockBox(BlockValue(type: "context")),
            range: NSRange(location: 0, length: text.length)
        )
        text.addAttribute(
            .amDisplayOnly,
            value: true,
            range: NSRange(location: 0, length: text.length)
        )

        let spans = RichText.spans(from: text)

        XCTAssertEqual(spans.count, 1)
        guard case .block(let block) = spans.first else {
            return XCTFail("expected the logline's block")
        }
        XCTAssertEqual(block.type, "context")
    }
}
