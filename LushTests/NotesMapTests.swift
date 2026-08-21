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

    func testAFixOffTheGlobeNeverBecomesALocation() {
        let found = NoteLocation.from([
            NotePlace(url: "a", ordinal: 0, latitude: 100, longitude: -4.2518, name: "", weather: "", stamped: ""),
            NotePlace(url: "a", ordinal: 1, latitude: 55.8642, longitude: 181.5, name: "", weather: "", stamped: ""),
            NotePlace(url: "a", ordinal: 2, latitude: 55.8642, longitude: -4.2518, name: "", weather: "", stamped: ""),
        ])

        XCTAssertEqual(found.map(\.id), ["a#2"])
    }

    func testAPlaceOnTheAntimeridianKeepsItsPinThere() {
        let places = MapPlace.cluster([
            NoteLocation(noteUrl: "a", ordinal: 0, name: "Taveuni", latitude: -16.8, longitude: 179.9995, weather: nil, stamped: Date(timeIntervalSince1970: 1)),
            NoteLocation(noteUrl: "b", ordinal: 0, name: "Taveuni", latitude: -16.8, longitude: -179.9995, weather: nil, stamped: Date(timeIntervalSince1970: 2)),
        ])

        XCTAssertEqual(places.count, 1)
        XCTAssertEqual(abs(places[0].longitude), 180, accuracy: 0.001)

        let region = MapPlace.region(covering: places)
        XCTAssertEqual(abs(region?.center.longitude ?? 0), 180, accuracy: 0.001)
        XCTAssertLessThan(region?.span.longitudeDelta ?? 360, 1)
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

    func testTheGroupingWidensAsTheMapZoomsOut() {
        let street = MapPlace.clusterRadius(
            forSpan: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004),
            height: 800
        )
        let province = MapPlace.clusterRadius(
            forSpan: MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 10),
            height: 800
        )

        XCTAssertLessThan(street, province)
        // 60 points of an 800-point map showing ten degrees of latitude
        XCTAssertEqual(province, 10 * 111_320 / 800 * 60, accuracy: 1)
    }

    func testTheGroupingNeverGetsTighterThanAFixWanders() {
        let doorway = MapPlace.clusterRadius(
            forSpan: MKCoordinateSpan(latitudeDelta: 0.00001, longitudeDelta: 0.00001),
            height: 800
        )

        XCTAssertEqual(doorway, MapPlace.minimumClusterRadius)
    }

    func testAMapWithNoSizeYetGroupsByTheOldFixedDistance() {
        let span = MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 10)

        XCTAssertEqual(MapPlace.clusterRadius(forSpan: span, height: 0), MapPlace.defaultClusterRadius)
        XCTAssertEqual(
            MapPlace.clusterRadius(
                forSpan: MKCoordinateSpan(latitudeDelta: 0, longitudeDelta: 0),
                height: 800
            ),
            MapPlace.defaultClusterRadius
        )
    }

    /// The bug this fixes: at province zoom every fix around Vancouver drew its
    /// own pin, and they landed on top of each other in an unreadable stack.
    func testTwoCitiesShareAPinZoomedOutAndSplitZoomedIn() {
        let loglines = [
            NoteLocation(noteUrl: "a", ordinal: 0, name: "Vancouver BC", latitude: 49.2827, longitude: -123.1207, weather: nil, stamped: Date(timeIntervalSince1970: 1)),
            NoteLocation(noteUrl: "b", ordinal: 0, name: "Richmond BC", latitude: 49.1666, longitude: -123.1336, weather: nil, stamped: Date(timeIntervalSince1970: 2)),
        ]
        let province = MapPlace.clusterRadius(
            forSpan: MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 10),
            height: 900
        )
        let city = MapPlace.clusterRadius(
            forSpan: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05),
            height: 900
        )

        XCTAssertEqual(MapPlace.cluster(loglines, within: province).count, 1)
        XCTAssertEqual(MapPlace.cluster(loglines, within: city).count, 2)
    }

    /// C is in range of both pins — 4.6km from A, 3.4km from B — so taking the
    /// first pin in range would hang it off A. The wider the grouping gets, the
    /// more often two pins are both in range, so zoomed out it matters which.
    func testALoglineJoinsItsNearestPinNotTheFirstOneInRange() {
        let places = MapPlace.cluster([
            NoteLocation(noteUrl: "a", ordinal: 0, name: "A", latitude: 55.0, longitude: -4.0, weather: nil, stamped: Date(timeIntervalSince1970: 1)),
            NoteLocation(noteUrl: "b", ordinal: 0, name: "B", latitude: 55.071865, longitude: -4.0, weather: nil, stamped: Date(timeIntervalSince1970: 2)),
            NoteLocation(noteUrl: "c", ordinal: 0, name: "C", latitude: 55.041322, longitude: -4.0, weather: nil, stamped: Date(timeIntervalSince1970: 3)),
        ], within: 5_000)

        XCTAssertEqual(places.count, 2)
        XCTAssertEqual(places.first?.noteUrls, ["a"])
        XCTAssertEqual(places.last?.noteUrls, ["b", "c"])
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
