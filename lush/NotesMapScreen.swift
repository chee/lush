import SwiftUI
import CoreLocation
import ImageIO
import MapKit

enum NotesMap {
    static let sidebarTag = "notes:map"
}

/// One logline that carried a fix. A note stamped in several places has one of
/// these per stamp, so it shows up at each of them.
struct NoteLocation: Identifiable, Hashable, Sendable {
    let noteUrl: String
    let ordinal: Int
    let name: String?
    let latitude: Double
    let longitude: Double
    let weather: String?
    let stamped: Date?
    /// The opening of what was written under this logline. Two visits to the
    /// same place on the same day are otherwise the same row twice.
    let excerpt: String?
    /// The first image written under it.
    let imageUrl: String?

    var id: String { "\(noteUrl)#\(ordinal)" }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// The whole batch at once: one date formatter does for all of them, and
    /// the index hands them over in one go anyway. A logline can come from an
    /// imported doc, so two numbers are not yet a place — anything off the
    /// globe is dropped rather than handed to MapKit.
    static func from(_ places: [NotePlace]) -> [NoteLocation] {
        let fmt = ISO8601DateFormatter()
        return places.compactMap { place in
            let coordinate = CLLocationCoordinate2D(
                latitude: place.latitude,
                longitude: place.longitude
            )
            guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            return NoteLocation(
                noteUrl: place.url,
                ordinal: Int(place.ordinal),
                name: place.name.isEmpty ? nil : place.name,
                latitude: place.latitude,
                longitude: place.longitude,
                weather: place.weather.isEmpty ? nil : place.weather,
                stamped: place.stamped.isEmpty ? nil : fmt.date(from: place.stamped),
                excerpt: place.excerpt.isEmpty ? nil : place.excerpt,
                imageUrl: place.image.isEmpty ? nil : place.image
            )
        }
    }
}

/// Loglines close enough together to be the same place, drawn as one pin. A fix
/// wanders by a few dozen metres between sittings, so the same desk would
/// otherwise scatter into a cloud of pins.
struct MapPlace: Identifiable, Sendable {
    let id: String
    let name: String?
    let latitude: Double
    let longitude: Double
    let visits: [NoteLocation]

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var noteUrls: [String] {
        var seen = Set<String>()
        return visits.compactMap { seen.insert($0.noteUrl).inserted ? $0.noteUrl : nil }
    }

    var title: String {
        name ?? String(format: "%.4f, %.4f", latitude, longitude)
    }

    var lastStamped: Date? {
        visits.compactMap(\.stamped).max()
    }

    /// How far apart two loglines can be and still share a pin, when nothing
    /// says how far the map is zoomed in. Only the first draw uses it — the
    /// camera has the answer from then on.
    static let defaultClusterRadius: CLLocationDistance = 200

    /// The closest two pins are ever allowed to be. A fix wanders by a few
    /// dozen metres between sittings, so without a floor the same desk
    /// scatters into a cloud of pins once the map is zoomed far enough in.
    static let minimumClusterRadius: CLLocationDistance = 25

    /// Metres to a degree of latitude. Longitude narrows towards the poles but
    /// latitude does not, so this is the one direction a span converts to the
    /// ground without knowing where on the globe it is.
    static let metresPerDegreeLatitude: Double = 111_320

    /// The grouping distance for a map showing `span` in `height` points: the
    /// distance on the ground that `spacing` points of screen covers. Pins
    /// merge exactly when they would have overlapped, so a continent shows one
    /// pin a city and a street shows one pin a doorway — rather than the fixed
    /// 200m that piles a whole province into one illegible stack.
    ///
    /// MapKit's projection is conformal, so the scale it works out down the
    /// screen is the scale across it too.
    static func clusterRadius(
        forSpan span: MKCoordinateSpan,
        height: CGFloat,
        spacing: CGFloat = 60
    ) -> CLLocationDistance {
        guard height > 0, span.latitudeDelta > 0, span.latitudeDelta.isFinite else {
            return defaultClusterRadius
        }
        let metresPerPoint = span.latitudeDelta * metresPerDegreeLatitude / Double(height)
        return max(metresPerPoint * Double(spacing), minimumClusterRadius)
    }

    static func cluster(
        _ locations: [NoteLocation],
        within metres: CLLocationDistance = defaultClusterRadius
    ) -> [MapPlace] {
        var groups: [(centre: CLLocation, members: [NoteLocation])] = []
        for location in locations.sorted(by: { ($0.stamped ?? .distantPast) < ($1.stamped ?? .distantPast) }) {
            let point = CLLocation(latitude: location.latitude, longitude: location.longitude)
            // the nearest group in range, not the first one found: zoomed out
            // the range is wide enough that first-match would chain one pin
            // across everything that happens to touch it
            var nearest: Int?
            var nearestDistance = metres
            for index in groups.indices {
                let distance = groups[index].centre.distance(from: point)
                guard distance <= nearestDistance else { continue }
                nearestDistance = distance
                nearest = index
            }
            if let index = nearest {
                groups[index].members.append(location)
                let count = Double(groups[index].members.count)
                let centre = groups[index].centre.coordinate
                let latitude = centre.latitude + (location.latitude - centre.latitude) / count
                let longitude = wrappedLongitude(
                    centre.longitude + wrappedLongitude(location.longitude - centre.longitude) / count
                )
                groups[index].centre = CLLocation(latitude: latitude, longitude: longitude)
            } else {
                groups.append((centre: point, members: [location]))
            }
        }
        return groups.map { group in
            MapPlace(
                id: group.members.first?.id ?? UUID().uuidString,
                name: commonName(of: group.members),
                latitude: group.centre.coordinate.latitude,
                longitude: group.centre.coordinate.longitude,
                visits: group.members
            )
        }
    }

    /// The name most of the loglines here agreed on. Reverse geocoding names the
    /// nearest thing it can see, which is not always the same thing twice.
    private static func commonName(of members: [NoteLocation]) -> String? {
        var counts: [String: Int] = [:]
        for name in members.compactMap(\.name) where !name.isEmpty {
            counts[name, default: 0] += 1
        }
        return counts.max { left, right in
            left.value == right.value ? left.key > right.key : left.value < right.value
        }?.key
    }

    /// A longitude, or a difference between two, taken the short way round the
    /// globe. Two fixes either side of the antimeridian are a few metres apart,
    /// and averaging them arithmetically would put their pin in the Gulf of
    /// Guinea instead.
    static func wrappedLongitude(_ degrees: Double) -> Double {
        let turned = (degrees + 180).truncatingRemainder(dividingBy: 360)
        return turned < 0 ? turned + 180 : turned - 180
    }

    static func region(covering places: [MapPlace]) -> MKCoordinateRegion? {
        guard let first = places.first else { return nil }
        let latitudes = places.map(\.latitude)
        // measured from the first place rather than from zero, so a set lying
        // either side of the antimeridian frames across the line
        let longitudes = places.map {
            first.longitude + wrappedLongitude($0.longitude - first.longitude)
        }
        guard let minLatitude = latitudes.min(), let maxLatitude = latitudes.max(),
              let minLongitude = longitudes.min(), let maxLongitude = longitudes.max()
        else { return nil }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: wrappedLongitude((minLongitude + maxLongitude) / 2)
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLatitude - minLatitude) * 1.4, 0.01),
                longitudeDelta: max((maxLongitude - minLongitude) * 1.4, 0.01)
            )
        )
    }
}

/// A note's own menu, when the note is still there. A logline can outlive the
/// note it was written in — the index row survives until the next crawl — and
/// a row with no note behind it should still open nothing rather than crash.
private struct OptionalNoteMenu: ViewModifier {
    let node: FolderNode?

    func body(content: Content) -> some View {
        if let node {
            content.contextMenu { NoteContextMenu(node: node) }
        } else {
            content
        }
    }
}

/// The side a card thumbnail draws at, and the pixels to decode for it —
/// three times over, for the densest screen either platform ships.
private let visitThumbnailSide: CGFloat = 46
private let visitThumbnailPixels = Int(visitThumbnailSide * 3)

/// A decoded picture on its way back from the thread that decoded it. Neither
/// platform's image type is Sendable; this one is made there, touched by
/// nobody on the way, and read only by the main actor once it lands.
private struct DecodedImage: @unchecked Sendable {
    let image: PImage
}

/// Decoded straight to the size it will be drawn at rather than decoded and
/// then shrunk, so a photograph never exists at full size in the first place.
private func decodeVisitThumbnail(_ data: Data) -> DecodedImage? {
    let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
    guard let source = CGImageSourceCreateWithData(
        data as CFData,
        sourceOptions as CFDictionary
    ) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: visitThumbnailPixels,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
        source,
        0,
        options as CFDictionary
    ) else { return nil }
    #if os(macOS)
    return DecodedImage(image: NSImage(cgImage: cgImage, size: .zero))
    #else
    return DecodedImage(image: UIImage(cgImage: cgImage, scale: 3, orientation: .up))
    #endif
}

/// A logline's picture at the size the card draws it. A place can hold a dozen
/// entries, and a dozen full-resolution photographs is a card that costs more
/// to open than the notes it points at.
private struct VisitThumbnail: View {
    let assetUrl: String

    @Environment(NotesModel.self) private var model
    @State private var image: PImage?

    var body: some View {
        Group {
            if let image {
                Image(pImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
            }
        }
        .frame(width: visitThumbnailSide, height: visitThumbnailSide)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: assetUrl) {
            guard let data = await model.assetBytes(assetUrl) else { return }
            let decoded = await Task.detached(priority: .utility) {
                decodeVisitThumbnail(data)
            }.value
            guard !Task.isCancelled else { return }
            image = decoded?.image
        }
    }
}

struct NotesMapScreen: View {
    let open: (String) -> Void

    @Environment(NotesModel.self) private var model
    /// Every logline that carried a fix, kept whole: the pins are a view of
    /// this at the zoom the map happens to be at, and re-grouping has to start
    /// from the loglines rather than from the last set of pins.
    @State private var locations: [NoteLocation] = []
    @State private var places: [MapPlace] = []
    @State private var selected: String?
    @State private var camera: MapCameraPosition = .automatic
    @State private var loading = true
    @State private var radius = MapPlace.defaultClusterRadius
    @State private var span: MKCoordinateSpan?
    @State private var mapHeight: CGFloat = 0

    private var selectedPlace: MapPlace? {
        places.first { $0.id == selected }
    }

    var body: some View {
        Group {
            if places.isEmpty {
                if loading {
                    ProgressView("Reading loglines…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("Nowhere Yet", systemImage: "map")
                    } description: {
                        Text("Notes land here once their loglines carry a location. Let Lush see where you are in Permissions, and keep loglines on in Settings.")
                    }
                }
            } else {
                map
            }
        }
        .navigationTitle("Map")
        .task { await reload() }
        // the grouping distance is the trigger: a zoom works out a new one and
        // this re-groups against it, cancelling a regroup still in flight
        .task(id: radius) { await regroup() }
    }

    private var map: some View {
        Map(position: $camera, selection: $selected) {
            ForEach(places) { place in
                Annotation(place.title, coordinate: place.coordinate) {
                    pin(place)
                }
                .tag(place.id)
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
            mapHeight = height
            rescale()
        }
        // .onEnd, not .continuous: pins that re-group mid-pinch jump about
        // under the fingers doing the pinching
        .onMapCameraChange(frequency: .onEnd) { context in
            span = context.region.span
            rescale()
        }
        .overlay(alignment: .topLeading) { summary }
        .overlay(alignment: .bottomLeading) {
            if let place = selectedPlace {
                card(place)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: selected)
    }

    private func pin(_ place: MapPlace) -> some View {
        let isSelected = place.id == selected
        // Loglines, not notes. The map is a record of times you were
        // somewhere, and a note written here over three visits is three of
        // them — counting notes made a pin that said 1 stand for an
        // afternoon and a pin that said 1 stand for a year.
        return VStack(spacing: 2) {
            Text("\(place.visits.count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 26, minHeight: 26)
                .padding(.horizontal, 4)
                .background(isSelected ? Color.accentColor : .lushPink, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.9), lineWidth: 1.5))
                .shadow(radius: 2, y: 1)
            if let name = place.name {
                Text(name)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .contentShape(Rectangle())
    }

    private var summary: some View {
        HStack(spacing: 10) {
            Text(countLine)
                .uiFont(.caption)
                .foregroundStyle(.secondary)
            Button {
                if let region = MapPlace.region(covering: places) {
                    withAnimation { camera = .region(region) }
                }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .help("Fit every place")
            Button {
                Task { await reload() }
            } label: {
                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .disabled(loading)
            .help("Read the loglines again")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(16)
    }

    /// Counted the way the badges count, so the badges add up to it. Notes
    /// were the wrong unit twice over: the badges deduped them within a pin
    /// and this deduped them across every pin, so a note written in five
    /// places counted five times on the map and once in the summary, and
    /// neither number was the sum of the other.
    private var countLine: String {
        let loglines = places.reduce(0) { $0 + $1.visits.count }
        let logWord = loglines == 1 ? "logline" : "loglines"
        let placeWord = places.count == 1 ? "place" : "places"
        return "\(loglines) \(logWord) · \(places.count) \(placeWord)"
    }

    private func card(_ place: MapPlace) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.title)
                        .uiFont(.headline)
                        .lineLimit(1)
                    Text(subtitle(place))
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    selected = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visits(at: place).enumerated()), id: \.element.id) { index, visit in
                        if index > 0 { Divider() }
                        visitRow(visit)
                    }
                }
            }
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(16)
    }

    /// The place in summary. Weather belongs to a moment rather than to a
    /// place, so it sits on the entries below instead of up here where the
    /// last one to arrive would speak for all of them.
    private func subtitle(_ place: MapPlace) -> String {
        var parts: [String] = []
        let count = place.visits.count
        parts.append("\(count) \(count == 1 ? "logline" : "loglines")")
        let notes = place.noteUrls.count
        if notes != count {
            parts.append("\(notes) \(notes == 1 ? "note" : "notes")")
        }
        if let last = place.lastStamped {
            parts.append("last \(last.formatted(.dateTime.month(.abbreviated).day().year()))")
        }
        return parts.joined(separator: "  ·  ")
    }

    /// One row per logline rather than per note. A note written here over
    /// three visits is three entries, and collapsing them threw away the only
    /// thing that told them apart — when each was written, and what was
    /// written under it.
    ///
    /// Newest first: the entry she was just here for is the one she is most
    /// likely reaching for.
    private func visits(at place: MapPlace) -> [NoteLocation] {
        place.visits.sorted { ($0.stamped ?? .distantPast) > ($1.stamped ?? .distantPast) }
    }

    @ViewBuilder
    private func visitRow(_ visit: NoteLocation) -> some View {
        let node = model.node(for: visit.noteUrl)
        HStack(alignment: .top, spacing: 8) {
            if let imageUrl = visit.imageUrl {
                VisitThumbnail(assetUrl: imageUrl)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(node?.displayName ?? "Untitled")
                        .uiFont(.subheadline, weight: .medium)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let stamped = visit.stamped {
                        Text(stamped.formatted(
                            .dateTime.month(.abbreviated).day().hour().minute()
                        ))
                        .uiFont(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                }
                if let line = entryLine(visit) {
                    Text(line)
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { open(visit.noteUrl) }
        .modifier(OptionalNoteMenu(node: node))
        #if os(macOS)
        .pointerStyle(.link)
        #endif
    }

    private func entryLine(_ visit: NoteLocation) -> String? {
        let parts = [visit.weather, visit.excerpt].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private func reload() async {
        loading = true
        let found = await model.noteLocations()
        guard !Task.isCancelled else { return }
        let grouping = radius
        let clustered = await Task.detached { MapPlace.cluster(found, within: grouping) }.value
        guard !Task.isCancelled else { return }
        let isFirstLoad = places.isEmpty
        locations = found
        apply(clustered)
        loading = false
        if isFirstLoad, let region = MapPlace.region(covering: clustered) {
            camera = .region(region)
        }
        // the map was not on screen while this loaded, so nothing has reported
        // a camera yet — group for the region it is about to frame
        rescale()
    }

    /// The grouping distance for the map as it stands. Called on every camera
    /// settle, and only stirs when the scale really moved: a pan across a city
    /// leaves the pins where they are, a zoom re-groups them.
    private func rescale() {
        let grouping = MapPlace.clusterRadius(forSpan: span ?? fallbackSpan, height: mapHeight)
        guard grouping > radius * 1.1 || grouping < radius / 1.1 else { return }
        radius = grouping
    }

    private func regroup() async {
        guard !locations.isEmpty else { return }
        let found = locations
        let grouping = radius
        let clustered = await Task.detached { MapPlace.cluster(found, within: grouping) }.value
        guard !Task.isCancelled else { return }
        apply(clustered)
    }

    /// The span to group by before the map has reported a camera: whatever the
    /// places themselves cover, which is what `.automatic` is about to frame.
    private var fallbackSpan: MKCoordinateSpan {
        MapPlace.region(covering: places)?.span
            ?? MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    }

    /// Swap in a new set of pins, keeping the open card on the place it was
    /// opened for. A pin's id is its earliest logline, so the one the reader
    /// picked is still in whichever pin swallowed it.
    private func apply(_ clustered: [MapPlace]) {
        let anchor = selected
        places = clustered
        guard let anchor else { return }
        selected = clustered
            .first { place in place.visits.contains { $0.id == anchor } }?
            .id
    }
}
