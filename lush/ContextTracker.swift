import SwiftUI
import CoreLocation
import MapKit
import MediaPlayer

struct SavedPlace: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var radius: Double = 150
}

enum SavedPlaces {
    static let changed = Notification.Name("io.lush.savedPlacesChanged")
    private static let key = "loglinePlaces"

    static var all: [SavedPlace] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedPlace].self, from: data)) ?? []
    }

    static func save(_ places: [SavedPlace]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(places), forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func name(near loc: CLLocation) -> String? {
        all.compactMap { place -> (name: String, distance: Double)? in
            let center = CLLocation(latitude: place.latitude, longitude: place.longitude)
            let distance = loc.distance(from: center)
            return distance <= place.radius ? (place.name, distance) : nil
        }
        .min { $0.distance < $1.distance }?.name
    }
}

struct ContextSnapshot: Equatable {
    var timestamp: Date = .distantPast
    var locationName: String?
    var latitude: Double?
    var longitude: Double?
    var weatherDescription: String?
    var nowPlaying: String?
    /// Values from registered providers, keyed by attribute name.
    var extras: [String: String] = [:]

    func hasSubstantialChange(from previous: Self) -> Bool {
        if let lat = latitude, let lon = longitude,
           let prevLat = previous.latitude, let prevLon = previous.longitude {
            let d = sqrt(pow(lat - prevLat, 2) + pow(lon - prevLon, 2))
            if d > 500.0 / 111_000.0 { return true }
        } else if latitude != nil && previous.latitude == nil {
            return true
        }
        if locationName != previous.locationName { return true }
        if weatherDescription != previous.weatherDescription { return true }
        if nowPlaying != previous.nowPlaying { return true }
        if extras != previous.extras { return true }
        return false
    }

    init(
        timestamp: Date = .distantPast,
        locationName: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        weatherDescription: String? = nil,
        nowPlaying: String? = nil,
        extras: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.locationName = locationName
        self.latitude = latitude
        self.longitude = longitude
        self.weatherDescription = weatherDescription
        self.nowPlaying = nowPlaying
        self.extras = extras
    }

    init?(block: BlockValue) {
        guard block.type == "context" else { return nil }
        let fmt = ISO8601DateFormatter()
        if let raw = (block.attrs["created"] ?? block.attrs["ts"])?.stringValue,
           let date = fmt.date(from: raw) {
            timestamp = date
        }
        locationName = block.attrs["location"]?.stringValue
        latitude = block.attrs["lat"]?.doubleValue
        longitude = block.attrs["lon"]?.doubleValue
        weatherDescription = block.attrs["weather"]?.stringValue
        nowPlaying = block.attrs["now_playing"]?.stringValue
        extras = block.attrs.reduce(into: [:]) { result, pair in
            let reserved = ["created", "ts", "location", "lat", "lon", "weather", "now_playing"]
            guard !reserved.contains(pair.key), let value = pair.value.stringValue else { return }
            result[pair.key] = value
        }
    }
}

extension BlockValue {
    static func contextBlock(from snap: ContextSnapshot) -> BlockValue {
        var attrs: [String: JSONValue] = [:]
        let fmt = ISO8601DateFormatter()
        attrs["ts"] = .string(fmt.string(from: snap.timestamp))
        if let loc = snap.locationName { attrs["location"] = .string(loc) }
        if let lat = snap.latitude { attrs["lat"] = .number(lat) }
        if let lon = snap.longitude { attrs["lon"] = .number(lon) }
        if let w = snap.weatherDescription { attrs["weather"] = .string(w) }
        if let s = snap.nowPlaying { attrs["now_playing"] = .string(s) }
        for (key, value) in snap.extras { attrs[key] = .string(value) }
        return BlockValue(type: "context", attrs: attrs, isEmbed: true)
    }

    static func creationBlock(snap: ContextSnapshot? = nil) -> BlockValue {
        var attrs: [String: JSONValue] = [:]
        let fmt = ISO8601DateFormatter()
        attrs["created"] = .string(fmt.string(from: Date()))
        if let snap {
            if let loc = snap.locationName { attrs["location"] = .string(loc) }
            if let lat = snap.latitude { attrs["lat"] = .number(lat) }
            if let lon = snap.longitude { attrs["lon"] = .number(lon) }
            if let w = snap.weatherDescription { attrs["weather"] = .string(w) }
            if let s = snap.nowPlaying { attrs["now_playing"] = .string(s) }
            for (key, value) in snap.extras { attrs[key] = .string(value) }
        }
        return BlockValue(type: "context", attrs: attrs, isEmbed: true)
    }
}

struct ContextInlineView: View {
    let block: BlockValue

    private var isCreation: Bool { block.attrs["created"] != nil }

    private var dateText: String? {
        let fmt = ISO8601DateFormatter()
        let raw = block.attrs["created"] ?? block.attrs["ts"]
        guard let s = raw?.stringValue, let d = fmt.date(from: s) else { return nil }
        if isCreation {
            return d.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
        }
        return d.formatted(.dateTime.hour().minute())
    }

    var body: some View {
        HStack(spacing: 8) {
            if let date = dateText {
                Label(date, systemImage: isCreation ? "doc.badge.clock" : "clock")
            }
            if let weather = block.attrs["weather"]?.stringValue {
                Label(weather, systemImage: "cloud.sun")
            }
            if let loc = block.attrs["location"]?.stringValue {
                let lat = block.attrs["lat"]?.doubleValue
                let lon = block.attrs["lon"]?.doubleValue
                if let lat, let lon,
                   let url = URL(string: "https://maps.apple.com/?q=\(loc.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? loc)&ll=\(lat),\(lon)") {
                    Button {
                        #if os(macOS)
                        NSWorkspace.shared.open(url)
                        #else
                        UIApplication.shared.open(url)
                        #endif
                    } label: {
                        Label(loc, systemImage: "location")
                    }
                    .buttonStyle(.plain)
                } else {
                    Label(loc, systemImage: "location")
                }
            }
            if let song = block.attrs["now_playing"]?.stringValue {
                Label(song, systemImage: "music.note")
            }
            Spacer(minLength: 0)
        }
        .labelStyle(.titleAndIcon)
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }
}

@MainActor @Observable
final class ContextTracker {
    private(set) var snapshot = ContextSnapshot()

    /// Extra logline sources. Each tick asks every provider for a value; the
    /// key becomes the context block's attribute name.
    var providers: [String: @MainActor () -> String?] = [:]

    private let locationDelegate = _LocationDelegate()
    private var locationManager: CLLocationManager?
    private var monitorTask: Task<Void, Never>?
    private var lastWeatherFetch: Date = .distantPast
    private var lastWeatherLocation: (Double, Double)?
    private var lastLocation: CLLocation?

    init() {
        locationDelegate.owner = self
    }

    func start() {
        let mgr = CLLocationManager()
        mgr.delegate = locationDelegate
        mgr.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        mgr.distanceFilter = 100
        locationManager = mgr
        requestLocation()

        tick()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                self?.tick()
            }
        }
    }

    func requestLocation() {
        guard let mgr = locationManager else { return }
        switch mgr.authorizationStatus {
        case .notDetermined:
            mgr.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            mgr.startUpdatingLocation()
        default:
            break
        }
    }

    private func tick() {
        updateNowPlaying()
        var extras: [String: String] = [:]
        for (key, provide) in providers {
            if let value = provide() { extras[key] = value }
        }
        snapshot.extras = extras
        snapshot.timestamp = Date()
    }

    #if os(macOS)
    /// MPNowPlayingInfoCenter only reports this app's own playback, so ask
    /// the players themselves. `is running` doesn't launch them.
    private static let nowPlayingScript = NSAppleScript(source: """
        tell application "System Events"
            set musicRunning to (name of processes) contains "Music"
            set spotifyRunning to (name of processes) contains "Spotify"
        end tell
        if musicRunning then
            tell application "Music"
                if player state is playing then
                    return (get name of current track) & " – " & (get artist of current track)
                end if
            end tell
        end if
        if spotifyRunning then
            tell application "Spotify"
                if player state is playing then
                    return (get name of current track) & " – " & (get artist of current track)
                end if
            end tell
        end if
        return ""
        """)

    private func updateNowPlaying() {
        var error: NSDictionary?
        let result = Self.nowPlayingScript?.executeAndReturnError(&error)
        let playing = result?.stringValue ?? ""
        snapshot.nowPlaying = playing.isEmpty ? nil : playing
    }
    #else
    private func updateNowPlaying() {
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        if let title = info?[MPMediaItemPropertyTitle] as? String, !title.isEmpty {
            let artist = info?[MPMediaItemPropertyArtist] as? String
            snapshot.nowPlaying = artist.map { "\(title) – \($0)" } ?? title
        } else {
            snapshot.nowPlaying = nil
        }
    }
    #endif

    func didUpdateLocation(_ loc: CLLocation) {
        lastLocation = loc
        snapshot.latitude = loc.coordinate.latitude
        snapshot.longitude = loc.coordinate.longitude
        snapshot.timestamp = Date()
        Task {
            if let name = await placeName(at: loc) { snapshot.locationName = name }
            await fetchWeather(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
        }
    }

    func refreshPlaceName() {
        guard let loc = lastLocation else { return }
        Task {
            if let name = await placeName(at: loc) { snapshot.locationName = name }
        }
    }

    /// The most specific name for the spot — a saved place, a nearby business
    /// or park, else the street — followed by the city and its region.
    private func placeName(at loc: CLLocation) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: loc),
              let mapItem = try? await request.mapItems.first
        else { return nil }
        let addr = mapItem.addressRepresentations
        let city = addr?.cityWithContext ?? addr?.cityName
        let street = addr?.fullAddress(includingRegion: false, singleLine: false)?
            .split(separator: "\n").first.map(String.init)
        let poi = mapItem.pointOfInterestCategory != nil ? mapItem.name : nil
        var specific = SavedPlaces.name(near: loc) ?? poi
        if specific == nil { specific = await nearbyPointOfInterest(at: loc) ?? street }
        if let found = specific, let city, city.hasPrefix(found) { specific = nil }
        let parts = [specific, city].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func nearbyPointOfInterest(at loc: CLLocation) async -> String? {
        guard loc.horizontalAccuracy <= 150 else { return nil }
        let radius: CLLocationDistance = 60
        let poi = MKLocalPointsOfInterestRequest(center: loc.coordinate, radius: radius)
        let search = MKLocalSearch(request: poi)
        guard let response = try? await search.start() else { return nil }
        var nearest: (name: String, distance: CLLocationDistance)?
        for item in response.mapItems {
            guard let name = item.name else { continue }
            let distance = item.location.distance(from: loc)
            guard distance <= radius else { continue }
            if nearest == nil || distance < nearest!.distance { nearest = (name, distance) }
        }
        return nearest?.name
    }

    func didChangeAuthorization() {
        requestLocation()
    }

    private func fetchWeather(lat: Double, lon: Double) async {
        let now = Date()
        if let last = lastWeatherLocation {
            let moved = sqrt(pow(lat - last.0, 2) + pow(lon - last.1, 2)) > 0.01
            let stale = now.timeIntervalSince(lastWeatherFetch) > 1800
            guard moved || stale else { return }
        }
        lastWeatherFetch = now
        lastWeatherLocation = (lat, lon)
        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current_weather=true") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cw = json["current_weather"] as? [String: Any],
              let temp = cw["temperature"] as? Double
        else { return }
        let code = cw["weathercode"] as? Int ?? 0
        let label = weatherLabel(code)
        snapshot.weatherDescription = label.isEmpty ? "\(Int(temp))°C" : "\(Int(temp))°C \(label)"
    }

    private func weatherLabel(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1, 2: return "Partly Cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55, 61, 63, 65: return "Rain"
        case 66, 67: return "Freezing Rain"
        case 71, 73, 75, 77: return "Snow"
        case 80, 81, 82: return "Showers"
        case 85, 86: return "Snow Showers"
        case 95: return "Thunderstorm"
        default: return ""
        }
    }
}

private final class _LocationDelegate: NSObject, CLLocationManagerDelegate {
    weak var owner: ContextTracker?

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor [weak owner] in owner?.didUpdateLocation(loc) }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak owner] in owner?.didChangeAuthorization() }
    }
}
