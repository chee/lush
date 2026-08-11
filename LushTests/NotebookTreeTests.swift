import XCTest
@testable import Lush

final class NotebookTreeTests: XCTestCase {
    func testContainsStopsAtSelfCycle() {
        let tree = NotebookTree(
            kinds: ["note": "lush", "folder": "folder"],
            parents: ["note": "folder", "folder": "folder"]
        )
        XCTAssertTrue(tree.contains("note", under: "folder"))
        XCTAssertFalse(tree.contains("note", under: "elsewhere"))
    }

    func testContainsStopsAtMultiNodeCycle() {
        let tree = NotebookTree(
            parents: [
                "note": "a",
                "a": "b",
                "b": "c",
                "c": "a",
            ]
        )
        XCTAssertTrue(tree.contains("note", under: "b"))
        XCTAssertFalse(tree.contains("note", under: "outside"))
    }

    func testContainsWalksLongChainsWithoutRecursion() {
        var parents = ["note": "folder-0"]
        for index in 0..<20_000 {
            parents["folder-\(index)"] = "folder-\(index + 1)"
        }
        let tree = NotebookTree(parents: parents)
        XCTAssertTrue(tree.contains("note", under: "folder-20000"))
        XCTAssertFalse(tree.contains("note", under: "missing"))
    }

    func testContainsDoesNotTreatUnparentedNodeAsDescendant() {
        let tree = NotebookTree(kinds: ["root": "folder", "note": "lush"])
        XCTAssertFalse(tree.contains("root", under: "root"))
        XCTAssertFalse(tree.contains("note", under: "root"))
    }
}
