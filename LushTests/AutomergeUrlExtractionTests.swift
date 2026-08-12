import XCTest
@testable import Lush

final class AutomergeUrlExtractionTests: XCTestCase {
    let doc = "automerge:2XoPZihn6Vo2aqeVu2WN39W8cdAN"
    let doc2 = "automerge:4ZrZFcjeYBUkRtGVJ2HXHtxQJmBs"
    let docLeadingOne = "automerge:1Bhh3pU9gLXZiNDL6PEa1Gs9fh"
    let head1 = "uDo9wptmjhvh4jKULRPSkhQvnF3unJfNB6CZSSCXkbYE3HDL6"
    let head2 = "V5tTZrf9kHjunP2eKvQS1JoC9bCoFgwUwn2Pyuws4LARaVwex"

    func testPlainUrl() {
        let found = AutomergeUrlExtraction.extract(from: doc)
        XCTAssertEqual(found, ExtractedAutomergeUrl(url: doc, heads: []))
    }

    func testEmbeddedMidSentence() {
        let found = AutomergeUrlExtraction.extract(
            from: "check this out (\(doc)), it's great"
        )
        XCTAssertEqual(found?.url, doc)
    }

    func testLeadingOneDocId() {
        let found = AutomergeUrlExtraction.extract(from: "see [\(docLeadingOne)] please")
        XCTAssertEqual(found?.url, docLeadingOne)
    }

    func testHeadsSuffix() {
        let found = AutomergeUrlExtraction.extract(from: "at \(doc)#\(head1)|\(head2) then")
        XCTAssertEqual(found?.url, doc)
        XCTAssertEqual(found?.heads, [head1, head2])
        XCTAssertEqual(found?.display, "\(doc)#\(head1)|\(head2)")
    }

    func testFirstOfMultipleWins() {
        let found = AutomergeUrlExtraction.extract(from: "\(doc2) and \(doc)")
        XCTAssertEqual(found?.url, doc2)
    }

    func testBadChecksumRejected() {
        let mutated = String(doc.dropLast()) + "M"
        XCTAssertNil(AutomergeUrlExtraction.extract(from: mutated))
    }

    func testLookalikesRejected() {
        XCTAssertNil(AutomergeUrlExtraction.extract(from: "automerge:hello"))
        XCTAssertNil(AutomergeUrlExtraction.extract(from: "automerge:"))
        XCTAssertNil(AutomergeUrlExtraction.extract(from: "automerge:0O0O0O0O0O0O0O0O0O0O0O0O0O0O"))
        XCTAssertNil(AutomergeUrlExtraction.extract(from: "no urls here"))
    }

    func testSkipsInvalidToFirstValid() {
        let mutated = String(doc2.dropLast()) + "t"
        let found = AutomergeUrlExtraction.extract(from: "\(mutated) then \(doc)")
        XCTAssertEqual(found?.url, doc)
    }

    func testGarbageHeadsIgnored() {
        let found = AutomergeUrlExtraction.extract(from: "\(doc)#notarealhead")
        XCTAssertEqual(found?.url, doc)
        XCTAssertEqual(found?.heads, [])
    }

    func testPercentEncodedUrl() {
        let encoded = "automerge%3A2XoPZihn6Vo2aqeVu2WN39W8cdAN"
        XCTAssertEqual(AutomergeUrlExtraction.extract(from: encoded)?.url, doc)
    }

    func testEncodedInsideQueryParam() {
        let share = "https://example.com/open?doc=automerge%3A2XoPZihn6Vo2aqeVu2WN39W8cdAN%23\(head1)%7C\(head2)&x=1"
        let found = AutomergeUrlExtraction.extract(from: share)
        XCTAssertEqual(found?.url, doc)
        XCTAssertEqual(found?.heads, [head1, head2])
    }

    func testRawMatchWinsOverDecoded() {
        let mixed = "automerge%3A4ZrZFcjeYBUkRtGVJ2HXHtxQJmBs before \(doc)"
        XCTAssertEqual(AutomergeUrlExtraction.extract(from: mixed)?.url, doc)
    }
}
