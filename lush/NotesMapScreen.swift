import SwiftUI
import CoreLocation
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
                stamped: place.stamped.isEmpty ? nil : fmt.date(from: place.stamped)
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

    static func cluster(_ locations: [NoteLocation], within metres: CLLocationDistance = 200) -> [MapPlace] {
        var groups: [(centre: CLLocation, members: [NoteLocation])] = []
        for location in locations.sorted(by: { ($0.stamped ?? .distantPast) < ($1.stamped ?? .distantPast) }) {
            let point = CLLocation(latitude: location.latitude, longitude: location.longitude)
            if let index = groups.firstIndex(where: { $0.centre.distance(from: point) <= metres }) {
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

struct NotesMapScreen: View {
    let open: (String) -> Void

    @Environment(NotesModel.self) private var model
    @State private var places: [MapPlace] = []
    @State private var selected: String?
    @State private var camera: MapCameraPosition = .automatic
    @State private var loading = true

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
        return VStack(spacing: 2) {
            Text("\(place.noteUrls.count)")
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

    private var countLine: String {
        let notes = Set(places.flatMap(\.noteUrls)).count
        let noteWord = notes == 1 ? "note" : "notes"
        let placeWord = places.count == 1 ? "place" : "places"
        return "\(notes) \(noteWord) · \(places.count) \(placeWord)"
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
                    ForEach(nodes(at: place), id: \.url) { node in
                        NoteRowView(node: node, showFolder: true)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                            .onTapGesture { open(node.url) }
                            .contextMenu { NoteContextMenu(node: node) }
                            #if os(macOS)
                            .pointerStyle(.link)
                            #endif
                    }
                }
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(16)
    }

    private func subtitle(_ place: MapPlace) -> String {
        var parts: [String] = []
        let visits = place.visits.count
        parts.append("\(visits) \(visits == 1 ? "logline" : "loglines")")
        if let last = place.lastStamped {
            parts.append("last \(last.formatted(.dateTime.month(.abbreviated).day().year()))")
        }
        if let weather = place.visits.compactMap(\.weather).last {
            parts.append(weather)
        }
        return parts.joined(separator: "  ·  ")
    }

    /// Newest stamp first: the note she was just at this place for is the one
    /// she is most likely reaching for.
    private func nodes(at place: MapPlace) -> [FolderNode] {
        var newest: [String: Date] = [:]
        for visit in place.visits {
            let when = visit.stamped ?? .distantPast
            if let existing = newest[visit.noteUrl], existing >= when { continue }
            newest[visit.noteUrl] = when
        }
        return newest
            .sorted { $0.value > $1.value }
            .compactMap { model.node(for: $0.key) }
    }

    /// The startup crawl is what fills the index, so a map opened while Lush is
    /// still coming up is only as complete as what has been read so far. Draw
    /// that, then draw again when the rest lands — the spinner is only held
    /// while there is nothing to show, so it never claims there is nowhere.
    private func reload() async {
        loading = true
        await draw()
        if !model.startupSettled {
            loading = places.isEmpty
            await model.awaitStartup()
            guard !Task.isCancelled else { return }
            await draw()
        }
        loading = false
    }

    private func draw() async {
        let locations = await model.noteLocations()
        let clustered = await Task.detached { MapPlace.cluster(locations) }.value
        guard !Task.isCancelled else { return }
        let isFirstLoad = places.isEmpty
        places = clustered
        if selected != nil, !clustered.contains(where: { $0.id == selected }) { selected = nil }
        if isFirstLoad, let region = MapPlace.region(covering: clustered) {
            camera = .region(region)
        }
    }
}
