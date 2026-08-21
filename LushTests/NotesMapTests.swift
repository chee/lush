import Foundation
import MapKit
import XCTest
@testable import Lush

final class NotesMapTests: XCTestCase {
    func testTheIndexRecordBecomesALocation() {
        let found = NoteLocation.from([
            NotePlace(
                url: "automerge:note",
                ordinal: 0,
                latitude: 55.8642,
                longitude: -4.2518,
                name: "Glasgow",
                weather: "Rain",
                stamped: "2026-03-04T09:00:00Z"
            ),
            NotePlace(
                url: "automerge:note",
                ordinal: 1,
                latitude: 51.5072,
                longitude: -0.1276,
                name: "",
                weather: "",
                stamped: ""
            ),
        ])

        XCTAssertEqual(found.map(\.id), ["automerge:note#0", "automerge:note#1"])
        XCTAssertEqual(found.first?.name, "Glasgow")
        XCTAssertEqual(found.first?.weather, "Rain")
        XCTAssertNotNil(found.first?.stamped)
        XCTAssertEqual(found.first?.latitude ?? 0, 55.8642, accuracy: 0.0001)
        XCTAssertNil(found.last?.name)
        XCTAssertNil(found.last?.weather)
        XCTAssertNil(found.last?.stamped)
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
