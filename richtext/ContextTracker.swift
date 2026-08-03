import SwiftUI
import CoreLocation
import MapKit
import MediaPlayer

struct ContextSnapshot: Equatable {
    var timestamp: Date = .distantPast
    var locationName: String?
    var latitude: Double?
    var longitude: Double?
    var weatherDescription: String?
    var nowPlaying: String?

    func hasSubstantialChange(from previous: Self) -> Bool {
        if timestamp.timeIntervalSince(previous.timestamp) > 600 { return true }
        if let lat = latitude, let lon = longitude,
           let prevLat = previous.latitude, let prevLon = previous.longitude {
            let d = sqrt(pow(lat - prevLat, 2) + pow(lon - prevLon, 2))
            if d > 500.0 / 111_000.0 { return true }
        } else if latitude != nil && previous.latitude == nil {
            return true
        }
        if weatherDescription != previous.weatherDescription { return true }
        if nowPlaying != previous.nowPlaying { return true }
        return false
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

    private let locationDelegate = _LocationDelegate()
    private var locationManager: CLLocationManager?
    private var monitorTask: Task<Void, Never>?
    private var lastWeatherFetch: Date = .distantPast
    private var lastWeatherLocation: (Double, Double)?

    init() {
        locationDelegate.owner = self
    }

    func start() {
        let mgr = CLLocationManager()
        mgr.delegate = locationDelegate
        mgr.desiredAccuracy = kCLLocationAccuracyHundredMeters
        mgr.distanceFilter = 300
        locationManager = mgr
        requestLocation()

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
        snapshot.timestamp = Date()
    }

    private func updateNowPlaying() {
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        if let title = info?[MPMediaItemPropertyTitle] as? String, !title.isEmpty {
            let artist = info?[MPMediaItemPropertyArtist] as? String
            snapshot.nowPlaying = artist.map { "\(title) – \($0)" } ?? title
        } else {
            snapshot.nowPlaying = nil
        }
    }

    func didUpdateLocation(_ loc: CLLocation) {
        snapshot.latitude = loc.coordinate.latitude
        snapshot.longitude = loc.coordinate.longitude
        snapshot.timestamp = Date()
        Task {
            if let request = MKReverseGeocodingRequest(location: loc),
               let mapItem = try? await request.mapItems.first,
               let addr = mapItem.addressRepresentations {
                snapshot.locationName = addr.cityWithContext ?? addr.cityName
            }
            await fetchWeather(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
        }
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
