import Foundation
import MapKit
import XCTest
@testable import Lush

/// One placed logline. The fields a clustering test doesn't look at default
/// away, so each case says only what it is about.
private func logline(
    _ noteUrl: String,
    ordinal: Int = 0,
    name: String? = nil,
    lat: Double,
    lon: Double,
    at seconds: TimeInterval? = nil,
    excerpt: String? = nil,
    image: String? = nil
) -> NoteLocation {
    NoteLocation(
        noteUrl: noteUrl,
        ordinal: ordinal,
        name: name,
        latitude: lat,
        longitude: lon,
        weather: nil,
        stamped: seconds.map { Date(timeIntervalSince1970: $0) },
        excerpt: excerpt,
        imageUrl: image
    )
}

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
                stamped: "2026-03-04T09:00:00Z",
                excerpt: "rained the whole way",
                image: "automerge:photo"
            ),
            NotePlace(
                url: "automerge:note",
                ordinal: 1,
                latitude: 51.5072,
                longitude: -0.1276,
                name: "",
                weather: "",
                stamped: "",
                excerpt: "",
                image: ""
            ),
        ])

        XCTAssertEqual(found.map(\.id), ["automerge:note#0", "automerge:note#1"])
        XCTAssertEqual(found.first?.name, "Glasgow")
        XCTAssertEqual(found.first?.weather, "Rain")
        XCTAssertNotNil(found.first?.stamped)
        XCTAssertEqual(found.first?.latitude ?? 0, 55.8642, accuracy: 0.0001)
        XCTAssertEqual(found.first?.excerpt, "rained the whole way")
        XCTAssertEqual(found.first?.imageUrl, "automerge:photo")
        XCTAssertNil(found.last?.name)
        XCTAssertNil(found.last?.weather)
        XCTAssertNil(found.last?.stamped)
        XCTAssertNil(found.last?.excerpt)
        XCTAssertNil(found.last?.imageUrl)
    }

    func testAFixOffTheGlobeNeverBecomesALocation() {
        let found = NoteLocation.from([
            NotePlace(url: "a", ordinal: 0, latitude: 100, longitude: -4.2518, name: "", weather: "", stamped: "", excerpt: "", image: ""),
            NotePlace(url: "a", ordinal: 1, latitude: 55.8642, longitude: 181.5, name: "", weather: "", stamped: "", excerpt: "", image: ""),
            NotePlace(url: "a", ordinal: 2, latitude: 55.8642, longitude: -4.2518, name: "", weather: "", stamped: "", excerpt: "", image: ""),
        ])

        XCTAssertEqual(found.map(\.id), ["a#2"])
    }

    func testAPlaceOnTheAntimeridianKeepsItsPinThere() {
        let places = MapPlace.cluster([
            logline("a", name: "Taveuni", lat: -16.8, lon: 179.9995, at: 1),
            logline("b", name: "Taveuni", lat: -16.8, lon: -179.9995, at: 2),
        ])

        XCTAssertEqual(places.count, 1)
        XCTAssertEqual(abs(places[0].longitude), 180, accuracy: 0.001)

        let region = MapPlace.region(covering: places)
        XCTAssertEqual(abs(region?.center.longitude ?? 0), 180, accuracy: 0.001)
        XCTAssertLessThan(region?.span.longitudeDelta ?? 360, 1)
    }

    func testTheSameDeskDoesNotScatterIntoSeveralPins() {
        let places = MapPlace.cluster([
            logline("a", name: "Home", lat: 55.8642, lon: -4.2518, at: 1),
            logline("b", name: "Home", lat: 55.8647, lon: -4.2518, at: 2),
            logline("c", name: "London", lat: 51.5072, lon: -0.1276, at: 3),
        ])

        XCTAssertEqual(places.count, 2)
        XCTAssertEqual(places.first?.title, "Home")
        XCTAssertEqual(places.first?.noteUrls, ["a", "b"])
        XCTAssertEqual(places.last?.visits.count, 1)
    }

    /// The distinction the pin badge turns on: two entries, one note.
    func testANoteStampedTwiceAtAPlaceIsTwoLoglinesAndOneNote() {
        let places = MapPlace.cluster([
            logline("a", name: "Home", lat: 55.8642, lon: -4.2518, at: 1),
            logline("a", ordinal: 1, name: "Home", lat: 55.8643, lon: -4.2518, at: 2),
        ])

        XCTAssertEqual(places.count, 1)
        XCTAssertEqual(places.first?.visits.count, 2)
        XCTAssertEqual(places.first?.noteUrls, ["a"])
    }

    /// The arithmetic the summary line got wrong. Badges deduped notes within
    /// a pin and the summary deduped them across every pin, so one note
    /// written in two places drew two badges reading 1 over a summary reading
    /// 1 note — neither number the sum of the other. In loglines they agree by
    /// construction.
    func testTheBadgesSumToTheSummary() {
        let places = MapPlace.cluster([
            logline("a", name: "Home", lat: 55.8642, lon: -4.2518, at: 1),
            logline("a", ordinal: 1, name: "Home", lat: 55.8643, lon: -4.2518, at: 2),
            logline("a", ordinal: 2, name: "London", lat: 51.5072, lon: -0.1276, at: 3),
        ])

        XCTAssertEqual(places.count, 2)
        XCTAssertEqual(places.reduce(0) { $0 + $1.visits.count }, 3)
        // what the two of them used to say
        XCTAssertEqual(places.map(\.noteUrls.count), [1, 1])
        XCTAssertEqual(Set(places.flatMap(\.noteUrls)).count, 1)
    }

    func testAPinTakesTheNameMostOfItsLoglinesAgreedOn() {
        let places = MapPlace.cluster([
            logline("a", name: "Cafe Gandolfi", lat: 55.8580, lon: -4.2450, at: 1),
            logline("b", name: "Albion Street", lat: 55.8581, lon: -4.2450, at: 2),
            logline("c", name: "Cafe Gandolfi", lat: 55.8580, lon: -4.2451, at: 3),
        ])

        XCTAssertEqual(places.count, 1)
        XCTAssertEqual(places.first?.name, "Cafe Gandolfi")
    }

    func testAPinWithNoNameFallsBackToItsCoordinates() {
        let places = MapPlace.cluster([
            logline("a", lat: 55.8642, lon: -4.2518),
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
            logline("a", name: "Vancouver BC", lat: 49.2827, lon: -123.1207, at: 1),
            logline("b", name: "Richmond BC", lat: 49.1666, lon: -123.1336, at: 2),
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
            logline("a", name: "A", lat: 55.0, lon: -4.0, at: 1),
            logline("b", name: "B", lat: 55.071865, lon: -4.0, at: 2),
            logline("c", name: "C", lat: 55.041322, lon: -4.0, at: 3),
        ], within: 5_000)

        XCTAssertEqual(places.count, 2)
        XCTAssertEqual(places.first?.noteUrls, ["a"])
        XCTAssertEqual(places.last?.noteUrls, ["b", "c"])
    }

    func testTheRegionCoversEveryPlace() {
        let places = MapPlace.cluster([
            logline("a", lat: 55.0, lon: -4.0, at: 1),
            logline("b", lat: 51.0, lon: 0.0, at: 2),
        ])

        let region = MapPlace.region(covering: places)

        XCTAssertEqual(region?.center.latitude ?? 0, 53.0, accuracy: 0.0001)
        XCTAssertEqual(region?.center.longitude ?? 0, -2.0, accuracy: 0.0001)
        XCTAssertGreaterThan(region?.span.latitudeDelta ?? 0, 4.0)
        XCTAssertNil(MapPlace.region(covering: []))
    }
}
