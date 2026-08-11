import Foundation
import XCTest
@testable import Lush

final class CoreSpliceTests: XCTestCase {
    func testStaleHeadSplicesAtDifferentPositionsMergeWithoutLosingText() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lush-splice-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        let core = try Core(dataDir: directory.path, serverUrl: "http://[")
        let note = try core.createNoteDoc(title: "seed")
        let emptyHeads = await core.docHeads(url: note)
        _ = try core.spliceNoteText(
            url: note,
            index: 1,
            deleteCount: 0,
            insert: "middle",
            title: "seed",
            heads: emptyHeads
        )
        let sharedHeads = await core.docHeads(url: note)
        let changesBeforeConcurrentEdits = core.docChangeCount(url: note)

        _ = try core.spliceNoteText(
            url: note,
            index: 1,
            deleteCount: 0,
            insert: "left-",
            title: "seed",
            heads: sharedHeads
        )
        _ = try core.spliceNoteText(
            url: note,
            index: 7,
            deleteCount: 0,
            insert: "-right",
            title: "seed",
            heads: sharedHeads
        )

        let snapshot = try await core.noteSpansSnapshot(url: note)
        let text = RichText.plainText(of: SpanNode.decodeList(snapshot.spansJson))
        XCTAssertEqual(text, "left-middle-right")
        XCTAssertEqual(core.docChangeCount(url: note), changesBeforeConcurrentEdits + 2)
        XCTAssertEqual(Set(snapshot.heads).count, 2)
    }
}
