import Foundation
import MapKit
import XCTest
@testable import Lush

final class NotesMapTests: XCTestCase {
    private func logline(
        lat: Double? = nil,
        lon: Double? = nil,
        name: String? = nil,
        weather: String? = nil,
        stamped: String? = nil
    ) -> SpanNode {
        var attrs: [String: JSONValue] = [:]
        if let lat { attrs["lat"] = .number(lat) }
        if let lon { attrs["lon"] = .number(lon) }
        if let name { attrs["location"] = .string(name) }
        if let weather { attrs["weather"] = .string(weather) }
        if let stamped { attrs["created"] = .string(stamped) }
        return .block(BlockValue(type: "context", attrs: attrs, isEmbed: true))
    }

    func testEveryLoglineWithAFixIsFound() {
        let json = SpanNode.encodeList([
            logline(lat: 55.8642, lon: -4.2518, name: "Glasgow", weather: "Rain", stamped: "2026-03-04T09:00:00Z"),
            .text("some words", [:]),
            logline(lat: 51.5072, lon: -0.1276, name: "London", stamped: "2026-03-05T09:00:00Z"),
        ])

        let found = NoteLocation.loglines(inSpansJson: json, of: "automerge:note")

        XCTAssertEqual(found.map(\.name), ["Glasgow", "London"])
        XCTAssertEqual(found.map(\.ordinal), [0, 1])
        XCTAssertEqual(found.map(\.id), ["automerge:note#0", "automerge:note#1"])
        XCTAssertEqual(found.first?.weather, "Rain")
        XCTAssertEqual(found.first?.latitude ?? 0, 55.8642, accuracy: 0.0001)
    }

    func testLoglinesWithoutAFixAreLeftOffTheMap() {
        let json = SpanNode.encodeList([
            logline(name: "Somewhere", stamped: "2026-03-04T09:00:00Z"),
            logline(lat: 55.8642, stamped: "2026-03-04T10:00:00Z"),
            .block(BlockValue(type: "paragraph")),
        ])

        XCTAssertTrue(NoteLocation.loglines(inSpansJson: json, of: "automerge:note").isEmpty)
    }

    func testALoglineWithNoStampStillCounts() {
        let json = SpanNode.encodeList([logline(lat: 55.8642, lon: -4.2518)])

        let found = NoteLocation.loglines(inSpansJson: json, of: "automerge:note")

        XCTAssertEqual(found.count, 1)
        XCTAssertNil(found.first?.stamped)
        XCTAssertNil(found.first?.name)
    }

    func testTheSameDeskDoesNotScatterIntoSeveralPins() {
        let places = MapPlace.cluster([
            NoteLocation(noteUrl: "a", ordinal: 0, name: "Home", latitude: 55.8642, longitude: -4.2518, weather: nil, stamped: Date(timeIntervalSince1970: 1)),
            NoteLocation(noteUrl: "b", ordinal: 0, name: "Home", latitude: 55.8647, longitude: -4.2518, weather: nil, stamped: Date(timeIntervalSince1970: 2)),
            NoteLocation(noteUrl: "c", ordinal: 0, name: "London", latitude: 51.5072, longitude: -0.1276, weather: nil, stamped: Date(timeIntervalSince1970: 3)),
        ])

        XCTAssertEqual(places.count, 2)
        XCTAssertEqual(places.first?.title, "Home")
        XCTAssertEqual(places.first?.noteUrls, ["a", "b"])
        XCTAssertEqual(places.last?.visits.count, 1)
    }

    func testOneNoteStampedTwiceAtAPlaceCountsOnce() {
        let places = MapPlace.cluster([
            NoteLocation(noteUrl: "a", ordinal: 0, name: "Home", latitude: 55.8642, longitude: -4.2518, weather: nil, stamped: Date(timeIntervalSince1970: 1)),
            NoteLocation(noteUrl: "a", ordinal: 1, name: "Home", latitude: 55.8643, longitude: -4.2518, weather: nil, stamped: Date(timeIntervalSince1970: 2)),
        ])

        XCTAssertEqual(places.count, 1)
        XCTAssertEqual(places.first?.visits.count, 2)
        XCTAssertEqual(places.first?.noteUrls, ["a"])
    }

    func testAPinTakesTheNameMostOfItsLoglinesAgreedOn() {
        let places = MapPlace.cluster([
            NoteLocation(noteUrl: "a", ordinal: 0, name: "Cafe Gandolfi", latitude: 55.8580, longitude: -4.2450, weather: nil, stamped: Date(timeIntervalSince1970: 1)),
            NoteLocation(noteUrl: "b", ordinal: 0, name: "Albion Street", latitude: 55.8581, longitude: -4.2450, weather: nil, stamped: Date(timeIntervalSince1970: 2)),
            NoteLocation(noteUrl: "c", ordinal: 0, name: "Cafe Gandolfi", latitude: 55.8580, longitude: -4.2451, weather: nil, stamped: Date(timeIntervalSince1970: 3)),
        ])

        XCTAssertEqual(places.count, 1)
        XCTAssertEqual(places.first?.name, "Cafe Gandolfi")
    }

    func testAPinWithNoNameFallsBackToItsCoordinates() {
        let places = MapPlace.cluster([
            NoteLocation(noteUrl: "a", ordinal: 0, name: nil, latitude: 55.8642, longitude: -4.2518, weather: nil, stamped: nil),
        ])

        XCTAssertEqual(places.first?.title, "55.8642, -4.2518")
    }

    func testTheRegionCoversEveryPlace() {
        let places = MapPlace.cluster([
            NoteLocation(noteUrl: "a", ordinal: 0, name: nil, latitude: 55.0, longitude: -4.0, weather: nil, stamped: Date(timeIntervalSince1970: 1)),
            NoteLocation(noteUrl: "b", ordinal: 0, name: nil, latitude: 51.0, longitude: 0.0, weather: nil, stamped: Date(timeIntervalSince1970: 2)),
        ])

        let region = MapPlace.region(covering: places)

        XCTAssertEqual(region?.center.latitude ?? 0, 53.0, accuracy: 0.0001)
        XCTAssertEqual(region?.center.longitude ?? 0, -2.0, accuracy: 0.0001)
        XCTAssertGreaterThan(region?.span.latitudeDelta ?? 0, 4.0)
        XCTAssertNil(MapPlace.region(covering: []))
    }
}
