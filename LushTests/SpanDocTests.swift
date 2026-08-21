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
