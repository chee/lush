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
            guard !LoglineDraft.reservedKeys.contains(pair.key),
                  let value = pair.value.stringValue
            else { return }
            result[pair.key] = value
        }
    }
}

/// Everything a logline records, as an editable form. A logline filled in by
/// hand is the same block the tracker stamps — this is only a way to write the
/// attrs yourself, for a moment you weren't at a keyboard for.
struct LoglineDraft {
    /// The attrs the form has fields of its own for. Everything else is an
    /// extra, editable as plain text — `ContextSnapshot` draws the same line.
    static let reservedKeys: Set<String> = [
        "created", "ts", "tz", "location", "lat", "lon", "weather", "pending",
    ]

    /// One of the attrs the form has no dedicated field for — `nowPlaying`
    /// and whatever else a tracker or a future version stamps. Identity is the
    /// row's own, not the key's, so renaming a key doesn't lose the field
    /// under the cursor.
    struct Extra: Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }

    var date: Date
    var zone: TimeZone
    var location: String
    var latitude: String
    var longitude: String
    var weather: String
    var extras: [Extra]
    /// Which stamp key the block carries. A note's opening logline is its
    /// `created` one and there should only ever be the one, so editing never
    /// changes this — it is carried so saving doesn't turn one into the other.
    var isCreation: Bool

    init(block: BlockValue? = nil, now: Date = Date()) {
        isCreation = block?.attrs["created"] != nil
        date = block?.contextStamp ?? now
        zone = block?.contextZone ?? .current
        location = block?.attrs["location"]?.stringValue ?? ""
        weather = block?.attrs["weather"]?.stringValue ?? ""
        latitude = Self.text(block?.attrs["lat"]?.doubleValue)
        longitude = Self.text(block?.attrs["lon"]?.doubleValue)
        // Only the ones that are already text. A number or a flag under an
        // unexpected key is left alone rather than retyped as a string by
        // being shown in a text field.
        extras = (block?.attrs ?? [:])
            .filter { !Self.reservedKeys.contains($0.key) && $0.value.stringValue != nil }
            .map { Extra(key: $0.key, value: $0.value.stringValue ?? "") }
            .sorted { $0.key < $1.key }
    }

    /// Latitude and longitude, only when both parse and both are in range. A
    /// lone or impossible coordinate is worse than none: `mapsURL` would hand
    /// Maps a pin in the wrong place rather than searching for the name.
    var coordinate: (lat: Double, lon: Double)? {
        guard let lat = Double(latitude.trimmingCharacters(in: .whitespaces)),
              let lon = Double(longitude.trimmingCharacters(in: .whitespaces)),
              (-90...90).contains(lat), (-180...180).contains(lon)
        else { return nil }
        return (lat, lon)
    }

    /// True when the coordinate fields hold something that isn't a usable
    /// pair, so the form can say so rather than dropping it silently.
    var coordinateIsBroken: Bool {
        let entered = !latitude.trimmingCharacters(in: .whitespaces).isEmpty
            || !longitude.trimmingCharacters(in: .whitespaces).isEmpty
        return entered && coordinate == nil
    }

    /// The draft as a block, keeping whatever the form doesn't cover — the
    /// `nowPlaying` and other extras the tracker stamps stay put.
    func applied(to existing: BlockValue?) -> BlockValue {
        var out = existing ?? BlockValue(type: "context", isEmbed: true)
        out.type = "context"
        out.isEmbed = true
        // Filled in by hand, so there is nothing for a refresh to chase.
        out.attrs.removeValue(forKey: BlockValue.contextPendingKey)
        let stamp = BlockValue.isoStamp(date, in: zone)
        out.attrs[isCreation ? "created" : "ts"] = .string(stamp)
        out.attrs.removeValue(forKey: isCreation ? "ts" : "created")
        out.attrs["tz"] = .string(zone.identifier)
        Self.put(&out.attrs, "location", location)
        Self.put(&out.attrs, "weather", weather)
        // Drop the text extras and write the rows back, so a removed row is
        // actually removed. Anything that wasn't text was never shown and
        // stays where it is.
        for key in out.attrs.keys
        where !Self.reservedKeys.contains(key) && out.attrs[key]?.stringValue != nil {
            out.attrs.removeValue(forKey: key)
        }
        for extra in extras {
            let key = extra.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !Self.reservedKeys.contains(key) else { continue }
            out.attrs[key] = .string(extra.value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let coordinate {
            out.attrs["lat"] = .number(coordinate.lat)
            out.attrs["lon"] = .number(coordinate.lon)
        } else {
            out.attrs.removeValue(forKey: "lat")
            out.attrs.removeValue(forKey: "lon")
        }
        return out
    }

    private static func text(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(value)
    }

    private static func put(_ attrs: inout [String: JSONValue], _ key: String, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            attrs.removeValue(forKey: key)
        } else {
            attrs[key] = .string(trimmed)
        }
    }
}

/// Renders a logline's stamp from the template in settings, in the zone the
/// logline was written in.
///
/// `DateFormatter` is expensive to build and this runs once per logline per
/// layout pass, so the built ones are kept. The key carries the template and
/// the zone because both change what comes out. Touched only while drawing,
/// which is the main thread, so the cache needs no lock of its own.
enum LoglineStampFormat {
    private static var cache: [String: DateFormatter] = [:]

    static func string(for date: Date, zone: TimeZone) -> String {
        let template = EditorSettings.loglineDateFormat
        let key = "\(template)|\(zone.identifier)"
        if let cached = cache[key] { return cached.string(from: date) }
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate(template)
        // A template with nothing usable in it leaves an empty format, which
        // would render every logline blank. Fall back rather than do that.
        if formatter.dateFormat?.isEmpty != false {
            formatter.setLocalizedDateFormatFromTemplate(EditorSettings.defaultLoglineDateFormat)
        }
        cache[key] = formatter
        return formatter.string(from: date)
    }

    static func forget() { cache.removeAll() }
}

extension BlockValue {
    /// A logline stamped from a snapshot that a refresh is still chasing. It
    /// draws a spinner until `resolvingContext` folds the fresher reading in.
    static let contextPendingKey = "pending"

    /// Stamps carry the writer's wall-clock offset, so a reader — the core's
    /// logline enrichment included — knows what "morning" meant without a
    /// timezone database.
    static func isoStamp(_ date: Date, in zone: TimeZone = .autoupdatingCurrent) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.timeZone = zone
        return fmt.string(from: date)
    }

    static func contextBlock(from snap: ContextSnapshot, pending: Bool = false) -> BlockValue {
        var attrs: [String: JSONValue] = [:]
        // when the logline was stamped, which is now — the snapshot's own
        // timestamp says how fresh its readings are, a different question
        attrs["ts"] = .string(isoStamp(Date()))
        attrs["tz"] = .string(TimeZone.current.identifier)
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
        attrs["created"] = .string(isoStamp(Date()))
        attrs["tz"] = .string(TimeZone.current.identifier)
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
        guard let raw = contextStampText else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }

    /// The stamp as written, which is what tells one logline in a note from
    /// another once the pending flag is off and there's nothing else to go by.
    var contextStampText: String? {
        (attrs["created"] ?? attrs["ts"])?.stringValue
    }

    /// The zone the logline was stamped in. A logline is a record of a moment
    /// somewhere, so it is read back in the zone it was written in rather than
    /// wherever the reader happens to be now — otherwise flying home rewrites
    /// every entry in the notebook.
    var contextZone: TimeZone {
        attrs["tz"]?.stringValue.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    /// How a logline says when it was written: day, month, year, time and the
    /// zone. One string for both renderers, so the inline view and the drawn
    /// line can't drift apart.
    ///
    /// Loglines stamped before the zone was recorded have only the reader's to
    /// go on, and fall back to it — the label still describes the time printed
    /// beside it, which is the part that has to stay true.
    var contextDisplayStamp: String? {
        guard let date = contextStamp else { return nil }
        return LoglineStampFormat.string(for: date, zone: contextZone)
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

    private var dateText: String? { block.contextDisplayStamp }

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

    /// Extra logline sources. Each stamp asks every provider for a value; the
    /// key becomes the context block's attribute name.
    var providers: [String: @MainActor () -> String?] = [:]

    private let locationDelegate = _LocationDelegate()
    private var locationManager: CLLocationManager?
    private var lastWeatherFetch: Date = .distantPast
    private var lastWeatherLocation: (Double, Double)?
    private var lastWeatherText: String?
    private var lastLocation: CLLocation?
    private var lastLocationFix: Date = .distantPast
    private var lastPlaceName: String?
    private var lastNamedLocation: CLLocation?
    private var locationRequestInFlight = false
    private var lastAuthorization: CLAuthorizationStatus?
    private var fixWaiters: [UUID: CheckedContinuation<CLLocation?, Never>] = [:]
    private var refreshTask: Task<Void, Never>?

    /// Nothing here is collected on a timer: a logline asks, and only then does
    /// the radio wake. These are how much of the last answer a stamp will take
    /// rather than ask again — a note records a place, not a pace, and the
    /// snapshot's own substantial-change threshold is 500m.
    private static let fixReuse: TimeInterval = 60
    /// The open check only wants to know whether the place changed since the
    /// last logline, so it settles for what the old minute-by-minute poll used
    /// to guarantee anyway.
    static let openCheckFixReuse: TimeInterval = 300
    /// The radio's own deadline, well past any spinner's — a fix that arrives
    /// after a stamp gave up is still worth having for the next one.
    private static let fixTimeout: TimeInterval = 15
    private static let weatherReuse: TimeInterval = 900
    /// About a kilometre in degrees — closer than that is the same weather.
    private static let weatherReuseDegrees = 0.01
    private static let placeReuseDistance: CLLocationDistance = 50

    init() {
        locationDelegate.owner = self
    }

    /// Readies the radio without waking it. Authorization is asked for at the
    /// first stamp that needs it, not here.
    func start() {
        guard Self.stampsContext, locationManager == nil else { return }
        let mgr = CLLocationManager()
        mgr.delegate = locationDelegate
        // accuracy stays where it was: saved places are 150m wide and the POI
        // lookup gates on 150m, so a coarser fix would cost naming precision
        mgr.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        locationManager = mgr
    }

    func setPlacesEnabled(_ enabled: Bool) {
        SavedPlaces.setEnabled(enabled)
        forgetPlaceName()
        if enabled {
            start()
            Task { await refresh() }
            return
        }
        snapshot.locationName = nil
        snapshot.latitude = nil
        snapshot.longitude = nil
        if !Self.weatherEnabled { stopTracking() }
    }

    func setWeatherEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.weatherEnabledKey)
        lastWeatherFetch = .distantPast
        lastWeatherLocation = nil
        lastWeatherText = nil
        if enabled {
            start()
            Task { await refresh() }
            return
        }
        snapshot.weatherDescription = nil
        if !SavedPlaces.enabled { stopTracking() }
    }

    private func stopTracking() {
        // stopping cancels a one-shot request without any delegate call back,
        // so the in-flight flag has to be released by hand
        locationManager?.stopUpdatingLocation()
        locationManager = nil
        locationRequestInFlight = false
        lastAuthorization = nil
        lastLocation = nil
        lastWeatherText = nil
        deliverFix(nil)
    }

    /// One fix, then the radio goes back to sleep.
    private func requestFix() {
        guard Self.stampsContext, let mgr = locationManager else { return }
        switch mgr.authorizationStatus {
        case .notDetermined:
            // the answer arrives too late for the stamp that asked; the
            // authorization callback refreshes the snapshot for the next one
            mgr.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            guard !locationRequestInFlight else { return }
            locationRequestInFlight = true
            mgr.requestLocation()
        default:
            break
        }
    }

    /// The context as of now: providers, then the freshest fix and weather that
    /// `timeout` seconds can buy. Nothing collects any of this in the
    /// background, so every reader of `snapshot` comes through here first.
    ///
    /// `maxAge` is how old a fix may be before the radio is woken for a new
    /// one — a stamp wants a recent one, the open check will take the last few
    /// minutes. Loglines stamped in the same moment share the one refresh, and
    /// `timeout` is only how long *this* caller waits: the work runs on, and
    /// each reading lands in the snapshot as it arrives, so what misses one
    /// stamp is there for the next — or for `settled()`.
    @discardableResult
    func refresh(
        maxAge: TimeInterval = ContextTracker.fixReuse,
        timeout: TimeInterval = ContextTracker.refreshTimeout
    ) async -> ContextSnapshot {
        collectProviders()
        snapshot.timestamp = Date()
        await wait(for: refreshTask ?? startRefresh(maxAge: maxAge), upTo: timeout)
        return snapshot
    }

    /// What the refresh in flight settles on, however long it takes. A cold fix
    /// and its weather rarely beat a spinner's deadline; this is how the
    /// logline that gave up waiting still gets them.
    func settled() async -> ContextSnapshot {
        while let work = refreshTask { await work.value }
        return snapshot
    }

    private func startRefresh(maxAge: TimeInterval) -> Task<Void, Never> {
        let work = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(maxAge: maxAge)
            self.refreshTask = nil
        }
        refreshTask = work
        return work
    }

    /// Waits on the refresh, but not past the deadline — a slow geocode or a
    /// stalled weather host must not hold a spinner open. Giving up on the wait
    /// is not giving up on the work: what it fetches is still worth having.
    private func wait(for work: Task<Void, Never>, upTo timeout: TimeInterval) async {
        let deadline = Task {
            _ = try? await Task.sleep(for: .seconds(timeout))
        }
        let waiter = Task {
            await work.value
            deadline.cancel()
        }
        await deadline.value
        waiter.cancel()
    }

    private func collectProviders() {
        guard !providers.isEmpty else { return }
        var extras: [String: String] = [:]
        for (key, provide) in providers {
            if let value = provide() { extras[key] = value }
        }
        snapshot.extras = extras
    }

    private func performRefresh(maxAge: TimeInterval) async {
        guard Self.stampsContext else { return }
        start()
        guard let loc = await nextFix(maxAge: maxAge) else { return }
        lastLocation = loc
        let lat = loc.coordinate.latitude
        let lon = loc.coordinate.longitude
        if SavedPlaces.enabled {
            snapshot.latitude = lat
            snapshot.longitude = lon
            snapshot.timestamp = Date()
        }
        // each reading is written the moment it arrives rather than all at the
        // end: a stamp whose deadline falls between the two still keeps the
        // first, and one that catches neither leaves both for the next stamp
        async let place: Void = applyPlaceName(at: loc)
        async let sky: Void = applyWeather(lat: lat, lon: lon)
        _ = await (place, sky)
    }

    private func applyPlaceName(at loc: CLLocation) async {
        guard let name = await refreshedPlaceName(at: loc) else { return }
        snapshot.locationName = name
        snapshot.timestamp = Date()
    }

    private func applyWeather(lat: Double, lon: Double) async {
        guard let text = await refreshedWeather(lat: lat, lon: lon) else { return }
        snapshot.weatherDescription = text
        snapshot.timestamp = Date()
    }

    /// The name already found for this spot, or a fresh lookup. A reused fix
    /// would otherwise be geocoded again for the same answer.
    private func refreshedPlaceName(at loc: CLLocation) async -> String? {
        guard SavedPlaces.enabled else { return nil }
        if let name = lastPlaceName, let named = lastNamedLocation,
           loc.distance(from: named) < Self.placeReuseDistance {
            return name
        }
        guard let name = await placeName(at: loc) else { return nil }
        lastPlaceName = name
        lastNamedLocation = loc
        return name
    }

    private func forgetPlaceName() {
        lastPlaceName = nil
        lastNamedLocation = nil
    }

    private func refreshedWeather(lat: Double, lon: Double) async -> String? {
        guard Self.weatherEnabled else { return nil }
        if let current = lastWeatherText, let last = lastWeatherLocation,
           Date().timeIntervalSince(lastWeatherFetch) < Self.weatherReuse,
           sqrt(pow(lat - last.0, 2) + pow(lon - last.1, 2)) < Self.weatherReuseDegrees {
            return current
        }
        guard let text = await weatherText(lat: lat, lon: lon) else { return nil }
        lastWeatherFetch = Date()
        lastWeatherLocation = (lat, lon)
        lastWeatherText = text
        return text
    }

    /// The last fix while it's younger than `maxAge`, else the one the radio is
    /// about to hand over. The deadline is what guarantees the wait ends — a
    /// one-shot request that never answers has no delegate call back.
    private func nextFix(maxAge: TimeInterval) async -> CLLocation? {
        if let lastLocation, Date().timeIntervalSince(lastLocationFix) < maxAge {
            return lastLocation
        }
        requestFix()
        guard locationRequestInFlight else { return lastLocation }
        let id = UUID()
        let limit = Self.fixTimeout
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
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

    /// Only a refresh asks for a fix now, so this hands the fix to whoever is
    /// waiting on it and does nothing else — naming it and reading its weather
    /// belong to the refresh that wanted it.
    func didUpdateLocation(_ loc: CLLocation) {
        locationRequestInFlight = false
        lastLocationFix = Date()
        lastLocation = loc
        deliverFix(loc)
    }

    /// The saved places changed, so the name found for this spot may have too.
    func refreshPlaceName() {
        forgetPlaceName()
        guard SavedPlaces.enabled else { return }
        Task { await refresh() }
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

    /// The stamp that triggered the permission prompt is long gone by the time
    /// it's answered; fill the snapshot in so the next one has something.
    func didChangeAuthorization() {
        guard let mgr = locationManager else { return }
        let status = mgr.authorizationStatus
        let previous = lastAuthorization
        lastAuthorization = status
        // the delegate reports the state as it stands the moment it's set, and
        // that report is not a decision anyone just made
        guard let previous, previous != status, Self.stampsContext else { return }
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            Task { await refresh(maxAge: 0) }
        default:
            deliverFix(nil)
        }
    }

    /// WeatherKit when it answers, open-meteo when it doesn't. No caching and
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
