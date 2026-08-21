import Foundation
import XCTest
@testable import Lush

final class NoteFinderTests: XCTestCase {
    private func hit(_ url: String, _ name: String) -> SearchHit {
        SearchHit(url: url, name: name, snippet: "")
    }

    func testAnAnswerNamingNotesShowsOnlyThose() {
        let found = [hit("automerge:aaa", "Pasta"), hit("automerge:bbb", "Bikes")]
        XCTAssertEqual(
            NoteFinder.hits(citedIn: "It is in automerge:bbb.", from: found).map(\.url),
            ["automerge:bbb"]
        )
    }

    func testAnAnswerNamingNothingFallsBackToEverythingFound() {
        let found = [hit("automerge:aaa", "Pasta"), hit("automerge:bbb", "Bikes")]
        XCTAssertEqual(
            NoteFinder.hits(citedIn: "Nothing here is about that.", from: found).map(\.url),
            found.map(\.url)
        )
    }

    /// Citing the longer of two overlapping urls must not select the shorter.
    func testAUrlThatStartsAnotherIsNotCountedAsCited() {
        let found = [hit("automerge:aaa", "Pasta"), hit("automerge:aaa2", "Bikes")]
        XCTAssertEqual(
            NoteFinder.hits(citedIn: "It is automerge:aaa2.", from: found).map(\.url),
            ["automerge:aaa2"]
        )
    }

    /// One url being the start of another must not leave half of it behind.
    func testUrlsAreReadBackAsNames() {
        let found = [hit("automerge:aaa", "Pasta"), hit("automerge:aaa2", "")]
        XCTAssertEqual(
            NoteFinder.naming("automerge:aaa2 and automerge:aaa", from: found),
            "\u{201C}Untitled\u{201D} and \u{201C}Pasta\u{201D}"
        )
    }
}
