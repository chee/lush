import SwiftUI
import CoreLocation
import MapKit
import WeatherKit

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
    private static let enabledKey = "loglinePlacesEnabled"

    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }

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
        if extras != previous.extras { return true }
        return false
    }

    init(
        timestamp: Date = .distantPast,
        locationName: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        weatherDescription: String? = nil,
        extras: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.locationName = locationName
        self.latitude = latitude
        self.longitude = longitude
        self.weatherDescription = weatherDescription
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
        extras = block.attrs.reduce(into: [:]) { result, pair in
            let reserved = ["created", "ts", "location", "lat", "lon", "weather", "pending"]
            guard !reserved.contains(pair.key), let value = pair.value.stringValue else { return }
            result[pair.key] = value
        }
    }
}

extension BlockValue {
    /// A logline stamped from a snapshot that a refresh is still chasing. It
    /// draws a spinner until `resolvingContext` folds the fresher reading in.
    static let contextPendingKey = "pending"

    static func contextBlock(from snap: ContextSnapshot, pending: Bool = false) -> BlockValue {
        var attrs: [String: JSONValue] = [:]
        let fmt = ISO8601DateFormatter()
        attrs["ts"] = .string(fmt.string(from: snap.timestamp))
        if let loc = snap.locationName { attrs["location"] = .string(loc) }
        if let lat = snap.latitude { attrs["lat"] = .number(lat) }
        if let lon = snap.longitude { attrs["lon"] = .number(lon) }
        if let w = snap.weatherDescription { attrs["weather"] = .string(w) }
        for (key, value) in snap.extras { attrs[key] = .string(value) }
        if pending { attrs[contextPendingKey] = .bool(true) }
        return BlockValue(type: "context", attrs: attrs, isEmbed: true)
    }

    static func creationBlock(snap: ContextSnapshot? = nil, pending: Bool = false) -> BlockValue {
        var attrs: [String: JSONValue] = [:]
        let fmt = ISO8601DateFormatter()
        attrs["created"] = .string(fmt.string(from: Date()))
        if let snap {
            if let loc = snap.locationName { attrs["location"] = .string(loc) }
            if let lat = snap.latitude { attrs["lat"] = .number(lat) }
            if let lon = snap.longitude { attrs["lon"] = .number(lon) }
            if let w = snap.weatherDescription { attrs["weather"] = .string(w) }
                for (key, value) in snap.extras { attrs[key] = .string(value) }
            if pending { attrs[contextPendingKey] = .bool(true) }
        }
        return BlockValue(type: "context", attrs: attrs, isEmbed: true)
    }

    var isPendingContext: Bool {
        type == "context" && attrs[Self.contextPendingKey] != nil
    }

    /// When the logline was written, however long ago the doc has been sitting
    /// around with the flag still on it.
    var contextStamp: Date? {
        guard let raw = (attrs["created"] ?? attrs["ts"])?.stringValue else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }

    /// Stops the spinner, keeping whatever the refresh didn't improve on.
    func resolvingContext(with snap: ContextSnapshot?) -> BlockValue {
        var out = self
        out.attrs.removeValue(forKey: Self.contextPendingKey)
        guard let snap else { return out }
        if let loc = snap.locationName { out.attrs["location"] = .string(loc) }
        if let lat = snap.latitude { out.attrs["lat"] = .number(lat) }
        if let lon = snap.longitude { out.attrs["lon"] = .number(lon) }
        if let w = snap.weatherDescription { out.attrs["weather"] = .string(w) }
        for (key, value) in snap.extras { out.attrs[key] = .string(value) }
        return out
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
            if block.isPendingContext {
                ProgressView().controlSize(.mini)
            }
            Spacer(minLength: 0)
        }
        .labelStyle(.titleAndIcon)
        .font(.system(size: RichText.bodySize * 0.76))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .padding(.vertical, 4)
    }
}

@MainActor @Observable
final class ContextTracker {
    private static let weatherEnabledKey = "loglineWeatherEnabled"
    private(set) var snapshot = ContextSnapshot()

    static var weatherEnabled: Bool {
        UserDefaults.standard.bool(forKey: weatherEnabledKey)
    }

    /// Whether a logline has anything to go and fetch.
    static var stampsContext: Bool {
        SavedPlaces.enabled || weatherEnabled
    }

    /// A logline holds a spinner open while this runs, so it gives up fast and
    /// keeps whatever it already knew.
    static let refreshTimeout: TimeInterval = 3

    /// Extra logline sources. Each tick asks every provider for a value; the
    /// key becomes the context block's attribute name.
    var providers: [String: @MainActor () -> String?] = [:]

    private let locationDelegate = _LocationDelegate()
    private var locationManager: CLLocationManager?
    private var monitorTask: Task<Void, Never>?
    private var lastWeatherFetch: Date = .distantPast
    private var lastWeatherAttempt: Date = .distantPast
    private var lastWeatherLocation: (Double, Double)?
    private var weatherFetchInProgress = false
    private var pendingWeatherLocation: CLLocation?
    private var weatherGeneration = 0
    private var lastLocation: CLLocation?
    private var locationNameGeneration = 0
    private var locationRequestInFlight = false
    private var lastLocationFix: Date = .distantPast
    private var fixWaiters: [UUID: CheckedContinuation<CLLocation?, Never>] = [:]
    private var refreshTask: Task<Void, Never>?
    /// A note is stamped with the place it was written in, and the snapshot's
    /// own substantial-change threshold is 500m, so a fix from a few minutes
    /// ago is as good as one taken now.
    private static let locationRefresh: TimeInterval = 300

    init() {
        locationDelegate.owner = self
    }

    func start() {
        if monitorTask == nil {
            tick()
            monitorTask = Task { [weak self] in
                while !Task.isCancelled {
                    await AppActivity.waitUntilActive()
                    guard !Task.isCancelled else { break }
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled else { break }
                    self?.tick()
                }
            }
        }
        guard SavedPlaces.enabled || Self.weatherEnabled else { return }
        // one window per scene calls this; monitors must not accumulate
        guard locationManager == nil else {
            requestLocation()
            return
        }
        let mgr = CLLocationManager()
        mgr.delegate = locationDelegate
        // accuracy stays where it was: saved places are 150m wide and the POI
        // lookup gates on 150m, so a coarser fix would cost naming precision.
        // The saving comes from asking once instead of streaming, below.
        mgr.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        locationManager = mgr
        requestLocation()
    }

    func setPlacesEnabled(_ enabled: Bool) {
        SavedPlaces.setEnabled(enabled)
        locationNameGeneration &+= 1
        if enabled || Self.weatherEnabled {
            start()
        } else {
            // stopping cancels a one-shot request without any delegate call
            // back, so the in-flight flag has to be released by hand
            locationManager?.stopUpdatingLocation()
            locationManager = nil
            locationRequestInFlight = false
            lastLocation = nil
            deliverFix(nil)
        }
        if enabled {
            if let lastLocation { didUpdateLocation(lastLocation, fresh: false) }
            requestLocation(force: true)
            return
        }
        snapshot.locationName = nil
        snapshot.latitude = nil
        snapshot.longitude = nil
    }

    func setWeatherEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.weatherEnabledKey)
        weatherGeneration &+= 1
        lastWeatherFetch = .distantPast
        lastWeatherAttempt = .distantPast
        lastWeatherLocation = nil
        if enabled || SavedPlaces.enabled {
            start()
        } else {
            // stopping cancels a one-shot request without any delegate call
            // back, so the in-flight flag has to be released by hand
            locationManager?.stopUpdatingLocation()
            locationManager = nil
            locationRequestInFlight = false
            lastLocation = nil
            deliverFix(nil)
        }
        if !enabled { snapshot.weatherDescription = nil }
        if enabled, let location = lastLocation {
            Task {
                await fetchWeather(lat: location.coordinate.latitude, lon: location.coordinate.longitude)
            }
        } else if enabled {
            requestLocation(force: true)
        }
    }

    /// One fix, then the radio goes back to sleep. Streaming updates kept the
    /// location hardware warm for the whole session — every window appearing
    /// called `start()` — to serve a snapshot only read when a note is stamped.
    func requestLocation(force: Bool = false) {
        guard SavedPlaces.enabled || Self.weatherEnabled, let mgr = locationManager else { return }
        switch mgr.authorizationStatus {
        case .notDetermined:
            mgr.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            guard !locationRequestInFlight else { return }
            guard force || Date().timeIntervalSince(lastLocationFix) > Self.locationRefresh else { return }
            locationRequestInFlight = true
            mgr.requestLocation()
        default:
            break
        }
    }

    /// The freshest fix and weather that `timeout` seconds can buy. Loglines
    /// stamped in the same moment share the one refresh; what doesn't arrive in
    /// time keeps arriving in the background, it just misses this stamp.
    @discardableResult
    func refresh(timeout: TimeInterval = ContextTracker.refreshTimeout) async -> ContextSnapshot {
        if let refreshTask {
            await refreshTask.value
            return snapshot
        }
        let work: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(timeout: timeout)
        }
        refreshTask = work
        // the fix has its own deadline; this one stops a slow geocode or a
        // stalled weather host from holding the spinner past its welcome
        let deadline = Task {
            try? await Task.sleep(for: .seconds(timeout))
            work.cancel()
        }
        await work.value
        deadline.cancel()
        refreshTask = nil
        return snapshot
    }

    private func performRefresh(timeout: TimeInterval) async {
        guard Self.stampsContext else { return }
        start()
        guard let loc = await nextFix(timeout: timeout), !Task.isCancelled else { return }
        lastLocation = loc
        let lat = loc.coordinate.latitude
        let lon = loc.coordinate.longitude
        async let place = refreshedPlaceName(at: loc)
        async let sky = refreshedWeather(lat: lat, lon: lon)
        let (name, weather) = await (place, sky)
        guard !Task.isCancelled else { return }
        if SavedPlaces.enabled {
            snapshot.latitude = lat
            snapshot.longitude = lon
            if let name {
                // the fix that got us here started its own naming task; this
                // one is newer, so retire that one rather than race it
                locationNameGeneration &+= 1
                snapshot.locationName = name
            }
        }
        if Self.weatherEnabled, let weather {
            snapshot.weatherDescription = weather
            lastWeatherFetch = Date()
            lastWeatherAttempt = Date()
            lastWeatherLocation = (lat, lon)
        }
        snapshot.timestamp = Date()
    }

    private func refreshedPlaceName(at loc: CLLocation) async -> String? {
        guard SavedPlaces.enabled else { return nil }
        return await placeName(at: loc)
    }

    private func refreshedWeather(lat: Double, lon: Double) async -> String? {
        guard Self.weatherEnabled else { return nil }
        return await weatherText(lat: lat, lon: lon)
    }

    /// The fix the radio is about to hand over, or the last one when there is
    /// nothing in flight to wait for. The deadline is what guarantees the wait
    /// ends — a one-shot request that never answers has no delegate call back.
    private func nextFix(timeout: TimeInterval) async -> CLLocation? {
        requestLocation(force: true)
        guard locationRequestInFlight else { return lastLocation }
        let id = UUID()
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            self?.stopWaitingForFix(id)
        }
        let fix = await withCheckedContinuation { (continuation: CheckedContinuation<CLLocation?, Never>) in
            fixWaiters[id] = continuation
        }
        deadline.cancel()
        return fix
    }

    private func stopWaitingForFix(_ id: UUID) {
        fixWaiters.removeValue(forKey: id)?.resume(returning: lastLocation)
    }

    private func deliverFix(_ loc: CLLocation?) {
        guard !fixWaiters.isEmpty else { return }
        let waiters = fixWaiters
        fixWaiters.removeAll()
        for continuation in waiters.values {
            continuation.resume(returning: loc ?? lastLocation)
        }
    }

    private func tick() {
        var extras: [String: String] = [:]
        for (key, provide) in providers {
            if let value = provide() { extras[key] = value }
        }
        snapshot.extras = extras
        snapshot.timestamp = Date()
        requestLocation()
    }

    /// `fresh` marks a fix the radio just produced; replaying a cached one must
    /// not push the throttle forward or the snapshot could go stale unnoticed.
    func didUpdateLocation(_ loc: CLLocation, fresh: Bool = true) {
        if fresh {
            locationRequestInFlight = false
            lastLocationFix = Date()
            deliverFix(loc)
        }
        guard SavedPlaces.enabled || Self.weatherEnabled else { return }
        lastLocation = loc
        snapshot.timestamp = Date()
        if SavedPlaces.enabled {
            locationNameGeneration &+= 1
            let generation = locationNameGeneration
            snapshot.latitude = loc.coordinate.latitude
            snapshot.longitude = loc.coordinate.longitude
            snapshot.locationName = nil
            Task {
                let name = await placeName(at: loc)
                guard SavedPlaces.enabled, locationNameGeneration == generation else { return }
                snapshot.locationName = name
            }
        }
        if Self.weatherEnabled {
            Task {
                await fetchWeather(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
            }
        }
    }

    func refreshPlaceName() {
        guard SavedPlaces.enabled, let loc = lastLocation else { return }
        locationNameGeneration &+= 1
        let generation = locationNameGeneration
        snapshot.locationName = nil
        Task {
            let name = await placeName(at: loc)
            guard SavedPlaces.enabled, locationNameGeneration == generation else { return }
            snapshot.locationName = name
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

    /// A one-shot request reports its failure and nothing else, so the in-flight
    /// flag has to clear here or no fix would ever be asked for again.
    func didFailToLocate() {
        locationRequestInFlight = false
        deliverFix(nil)
    }

    func didChangeAuthorization() {
        requestLocation(force: true)
    }

    private func fetchWeather(lat: Double, lon: Double, retrying: Bool = false) async {
        guard Self.weatherEnabled else { return }
        let generation = weatherGeneration
        let now = Date()
        guard !weatherFetchInProgress else {
            pendingWeatherLocation = CLLocation(latitude: lat, longitude: lon)
            return
        }
        if !retrying, let last = lastWeatherLocation {
            let moved = sqrt(pow(lat - last.0, 2) + pow(lon - last.1, 2)) > 0.01
            let stale = now.timeIntervalSince(lastWeatherFetch) > 1800
            guard moved || stale else { return }
        }
        guard retrying || now.timeIntervalSince(lastWeatherAttempt) > 60 else { return }
        lastWeatherAttempt = now
        weatherFetchInProgress = true
        defer {
            weatherFetchInProgress = false
            let pending = pendingWeatherLocation
            pendingWeatherLocation = nil
            if Self.weatherEnabled,
               let location = pending ?? (weatherGeneration != generation ? lastLocation : nil) {
                Task {
                    await fetchWeather(
                        lat: location.coordinate.latitude,
                        lon: location.coordinate.longitude,
                        retrying: true
                    )
                }
            }
        }
        guard let text = await weatherText(lat: lat, lon: lon) else { return }
        guard Self.weatherEnabled, weatherGeneration == generation else { return }
        snapshot.weatherDescription = text
        lastWeatherFetch = now
        lastWeatherLocation = (lat, lon)
    }

    /// WeatherKit when it answers, open-meteo when it doesn't. No throttling and
    /// no snapshot writes — the caller owns both.
    private func weatherText(lat: Double, lon: Double) async -> String? {
        let location = CLLocation(latitude: lat, longitude: lon)
        if let current = try? await WeatherService.shared.weather(for: location, including: .current) {
            let formatter = MeasurementFormatter()
            formatter.unitOptions = [.naturalScale, .temperatureWithoutUnit]
            formatter.numberFormatter.maximumFractionDigits = 0
            let temp = formatter.string(from: current.temperature)
            return "\(temp) \(current.condition.description)"
        }
        guard !Task.isCancelled, let url = URL(
            string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current_weather=true"
        ) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current_weather"] as? [String: Any],
              let temperature = current["temperature"] as? Double
        else { return nil }
        let condition = weatherLabel(current["weathercode"] as? Int ?? 0)
        let temp = "\(Int(temperature.rounded()))°C"
        return condition.isEmpty ? temp : "\(temp) \(condition)"
    }

    private func weatherLabel(_ code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1, 2: "Partly Cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51, 53, 55, 61, 63, 65: "Rain"
        case 66, 67: "Freezing Rain"
        case 71, 73, 75, 77: "Snow"
        case 80, 81, 82: "Showers"
        case 85, 86: "Snow Showers"
        case 95: "Thunderstorm"
        default: ""
        }
    }
}

private final class _LocationDelegate: NSObject, CLLocationManagerDelegate {
    weak var owner: ContextTracker?

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor [weak owner] in owner?.didUpdateLocation(loc) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak owner] in owner?.didFailToLocate() }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak owner] in owner?.didChangeAuthorization() }
    }
}
