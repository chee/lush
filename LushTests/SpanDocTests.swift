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
}
