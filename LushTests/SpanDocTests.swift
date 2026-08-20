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
