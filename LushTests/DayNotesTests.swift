import Foundation
import XCTest
@testable import Lush

final class DayNotesTests: XCTestCase {
    private func day(_ text: String) -> Date {
        Agenda.stampDay(text)!
    }

    /// Built from a wall clock rather than a fixed epoch, so the day it lands
    /// on is the same day wherever the test is run.
    private func made(_ clock: String) -> Date {
        Agenda.stampClock.date(from: clock)!
    }

    func testALoglineFromADayPutsTheNoteOnIt() {
        let byDay = DayNote.from([
            NoteDay(
                url: "automerge:trip",
                title: "A day out",
                created: 0,
                stamps: [
                    "2026-03-04T09:00:00+01:00",
                    "2026-03-04T18:30:00+01:00",
                    "2026-03-06T22:10:00Z",
                ]
            )
        ])

        XCTAssertEqual(byDay.keys.sorted(), [day("2026-03-04"), day("2026-03-06")])
        XCTAssertEqual(byDay[day("2026-03-04")]?.count, 1)
        XCTAssertEqual(byDay[day("2026-03-04")]?.first?.displayTitle, "A day out")
        XCTAssertEqual(byDay[day("2026-03-04")]?.first?.isOrigin, false)
        XCTAssertEqual(byDay[day("2026-03-06")]?.first?.id, "automerge:trip|2026-03-06")
    }

    func testTheDayANoteWasMadeIsItsOwnRow() {
        let start = made("2026-03-04T09:00:00")
        let byDay = DayNote.from([
            NoteDay(
                url: "a",
                title: "kept up",
                created: Int64(start.timeIntervalSince1970),
                stamps: ["2026-03-04T09:00:02Z", "2026-03-09T11:00:00Z"]
            )
        ])

        XCTAssertEqual(byDay.keys.sorted(), [day("2026-03-04"), day("2026-03-09")])
        let origin = byDay[day("2026-03-04")]?.first
        XCTAssertEqual(origin?.isOrigin, true)
        XCTAssertEqual(origin?.at, start)
        XCTAssertEqual(origin?.detailText.hasPrefix("written "), true)
        XCTAssertEqual(byDay[day("2026-03-09")]?.first?.isOrigin, false)
    }

    /// The stamp carries the offset it was written at, so the hour it reads as
    /// is the hour the clock said there — wherever the note is read back.
    func testALoglineKeepsTheHourItWasStampedAt() {
        let byDay = DayNote.from([
            NoteDay(url: "a", title: "abroad", created: 0, stamps: ["2026-03-04T09:15:00+09:00"])
        ])
        let at = byDay[day("2026-03-04")]?.first?.at

        XCTAssertNotNil(at)
        XCTAssertEqual(Calendar.current.component(.hour, from: at ?? Date()), 9)
        XCTAssertEqual(Calendar.current.component(.minute, from: at ?? Date()), 15)
    }

    func testTwoLoglinesOnOneDayAreOneRow() {
        let byDay = DayNote.from([
            NoteDay(
                url: "a",
                title: "long day",
                created: 0,
                stamps: ["2026-03-04T09:00:00Z", "2026-03-04T11:00:00Z"]
            )
        ])

        XCTAssertEqual(byDay[day("2026-03-04")]?.count, 1)
        XCTAssertEqual(
            Calendar.current.component(.hour, from: byDay[day("2026-03-04")]?.first?.at ?? Date()),
            9
        )
    }

    func testANoteWithNoLoglineStillLandsOnTheDayItWasMade() {
        let start = made("2026-03-04T16:20:00")
        let byDay = DayNote.from([
            NoteDay(url: "a", title: "", created: Int64(start.timeIntervalSince1970), stamps: [])
        ])
        let entry = byDay[day("2026-03-04")]?.first

        XCTAssertEqual(byDay.count, 1)
        XCTAssertEqual(entry?.at, start)
        XCTAssertEqual(entry?.isOrigin, true)
        XCTAssertEqual(entry?.displayTitle, "Untitled Note")
    }

    func testANoteWithNothingToDateItIsOnNoDay() {
        XCTAssertTrue(DayNote.from([NoteDay(url: "a", title: "nowhen", created: 0, stamps: [])]).isEmpty)
        XCTAssertTrue(
            DayNote.from([NoteDay(url: "a", title: "nowhen", created: 0, stamps: ["not a stamp"])]).isEmpty
        )
    }

    func testADayReadsInTheOrderItHappened() {
        let byDay = DayNote.from([
            NoteDay(url: "late", title: "evening", created: 0, stamps: ["2026-03-04T21:00:00Z"]),
            NoteDay(url: "dateless", title: "sometime", created: 0, stamps: ["2026-03-04"]),
            NoteDay(url: "early", title: "morning", created: 0, stamps: ["2026-03-04T07:00:00Z"]),
        ])

        XCTAssertEqual(
            byDay[day("2026-03-04")]?.map(\.noteUrl),
            ["dateless", "early", "late"]
        )
    }

    func testTheRowSaysWhyTheNoteIsOnTheDay() {
        let byDay = DayNote.from([
            NoteDay(
                url: "a",
                title: "trip",
                created: 0,
                stamps: ["2026-03-04", "2026-03-05T14:02:00Z"]
            )
        ])

        XCTAssertEqual(byDay[day("2026-03-04")]?.first?.detailText, "logline")
        XCTAssertEqual(byDay[day("2026-03-05")]?.first?.detailText.hasPrefix("logline "), true)
    }
}
