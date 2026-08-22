import SwiftUI
import EventKit

struct AgendaItem: Identifiable, Equatable {
    enum Kind: String {
        case event
        case reminder
    }

    var id: String
    /// EventKit's own per-item identifier. A feed can give two genuinely
    /// different events one UID — the same holiday under its Spanish and its
    /// Catalan name — and `eventIdentifier` doesn't separate them either, since
    /// it is only `<store UUID>:<that same UID>`. This does.
    var calendarItemId: String
    var seriesId: String?
    var recurrenceText: String?
    var kind: Kind
    var title: String
    var start: Date
    var end: Date?
    var isAllDay: Bool
    var listName: String
    var color: Color
    var location: String?
    var colorHex: String?
    var isCompleted = false

    var isRecurring: Bool { seriesId != nil }

    var rowKey: String { "\(id)|\(calendarItemId)" }

    var timeText: String? {
        guard !isAllDay else { return nil }
        return start.formatted(date: .omitted, time: .shortened)
    }

    var rangeText: String {
        if isAllDay { return "all day" }
        let from = start.formatted(date: .omitted, time: .shortened)
        guard let end, end > start else { return from }
        return "\(from) – \(end.formatted(date: .omitted, time: .shortened))"
    }
}

extension AgendaItem {
    /// Identity comes from the CalDAV UID, which every device sees the same
    /// way — `eventIdentifier` is local to one EventKit store, so a note
    /// linked on the laptop pointed at nothing on the phone. Every occurrence
    /// of a series shares that UID, so the note is pinned to the occurrence by
    /// its original start: `occurrenceDate` survives rescheduling one instance,
    /// `startDate` does not.
    init?(_ event: EKEvent) {
        guard let start = event.startDate else { return nil }
        let uid = event.calendarItemExternalIdentifier
            ?? event.eventIdentifier
            ?? event.calendarItemIdentifier
        id = "\(uid)|\(Agenda.iso.string(from: event.occurrenceDate ?? start))"
        calendarItemId = event.calendarItemIdentifier
        seriesId = event.hasRecurrenceRules ? uid : nil
        recurrenceText = event.recurrenceRules?.first.map(Agenda.recurrenceText)
        kind = .event
        title = event.title ?? "Untitled Event"
        self.start = start
        end = event.endDate
        isAllDay = event.isAllDay
        listName = event.calendar?.title ?? ""
        color = Agenda.color(event.calendar)
        colorHex = Agenda.hex(event.calendar)
        location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines).presence
    }

    init?(_ reminder: EKReminder) {
        guard let due = reminder.dueDateComponents,
              let start = Calendar.current.date(from: due)
        else { return nil }
        id = Agenda.reminderPrefix + (reminder.calendarItemExternalIdentifier ?? reminder.calendarItemIdentifier)
        calendarItemId = reminder.calendarItemIdentifier
        seriesId = nil
        recurrenceText = nil
        kind = .reminder
        title = reminder.title ?? "Untitled Reminder"
        self.start = start
        end = nil
        isAllDay = due.hour == nil
        listName = reminder.calendar?.title ?? ""
        color = Agenda.color(reminder.calendar)
        colorHex = Agenda.hex(reminder.calendar)
        location = nil
        isCompleted = reminder.isCompleted
    }
}

extension String {
    var presence: String? { isEmpty ? nil : self }
}

enum Agenda {
    static let iso = ISO8601DateFormatter()
    /// For stamps written into note blocks: carries the local offset so the
    /// wall-clock time survives into search text. Never used for event ids —
    /// those stay on `iso`, and changing their format would orphan every
    /// stored calendar link.
    static let isoLocal: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.timeZone = .autoupdatingCurrent
        return fmt
    }()
    static let sidebarTag = "agenda:calendar"
    static let meetingNotesTag = "agenda:meeting-notes"
    static let reminderPrefix = "reminder:"
    static let dayInIconKey = "calendarIconShowsDay"
    static let horizonDays = 14
    /// How many days stay loaded at once. The window slides: scrolling past
    /// this lets the far edge go rather than accumulating the whole calendar.
    static let windowLimit = 180

    #if os(macOS)
    private static func fourCharCode(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { ($0 << 8) + FourCharCode($1) }
    }

    /// Moves Calendar to a day: its `view calendar at` command, sent as a raw
    /// Apple Event rather than compiled from AppleScript source, which costs a
    /// round trip instead of a compile. Noon keeps an hour of slop from landing
    /// on the day either side. Waits for the reply, so it returns once Calendar
    /// has actually arrived and the occurrence link has something to select.
    static func showDay(_ date: Date) {
        let noon = Foundation.Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: fourCharCode("wrbt"),
            eventID: fourCharCode("aec9"),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.iCal"),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setDescriptor(NSAppleEventDescriptor(date: noon), forKeyword: fourCharCode("wtdt"))
        _ = try? event.sendEvent(options: .waitForReply, timeout: 10)
    }
    #endif

    /// `<uid>|<occurrence>`, or a bare uid for a series or a reminder.
    static func eventKey(_ id: String) -> (uid: String, occurrence: Date?) {
        guard let separator = id.lastIndex(of: "|") else { return (id, nil) }
        return (
            String(id[id.startIndex..<separator]),
            iso.date(from: String(id[id.index(after: separator)...]))
        )
    }

    /// The form Calendar's occurrence links take, always in UTC.
    static let occurrenceStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    /// An identifier is `<uuid>:<uid>` and a Google uid is an email address —
    /// Calendar wants those colons and at-signs intact, and only the slash a
    /// detached occurrence carries has to go.
    static func escapePath(_ component: String) -> String {
        component.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        ) ?? component
    }

    /// The iOS form escapes the uid down to the unreserved set.
    static func escapeStrict(_ component: String) -> String {
        component.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        ) ?? component
    }

    static func recurrenceText(_ rule: EKRecurrenceRule) -> String {
        let unit: String
        switch rule.frequency {
        case .daily: unit = "day"
        case .weekly: unit = "week"
        case .monthly: unit = "month"
        case .yearly: unit = "year"
        @unknown default: unit = "time"
        }
        guard rule.interval > 1 else { return "every \(unit)" }
        return "every \(rule.interval) \(unit)s"
    }

    static func color(_ calendar: EKCalendar?) -> Color {
        guard let cgColor = calendar?.cgColor else { return .secondary }
        return Color(cgColor: cgColor)
    }

    static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// `lush://calendar?date=2026-08-10&event=<id>` — the day to scroll to and
    /// the item to pick out once it is on screen.
    static func url(day: Date?, item: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "lush"
        components.host = "calendar"
        var query: [URLQueryItem] = []
        if let day { query.append(URLQueryItem(name: "date", value: dayFormat.string(from: day))) }
        if let item { query.append(URLQueryItem(name: "event", value: item)) }
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }

    static func hex(_ calendar: EKCalendar?) -> String? {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = calendar?.cgColor?.converted(to: sRGB, intent: .defaultIntent, options: nil),
              let parts = converted.components, parts.count >= 3
        else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int((parts[0] * 255).rounded()),
            Int((parts[1] * 255).rounded()),
            Int((parts[2] * 255).rounded())
        )
    }

    static func color(hex: String) -> Color? {
        var value = hex
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let packed = Int(value, radix: 16) else { return nil }
        return Color(
            red: Double((packed >> 16) & 0xFF) / 255,
            green: Double((packed >> 8) & 0xFF) / 255,
            blue: Double(packed & 0xFF) / 255
        )
    }

    /// Every day in the window gets a section, empty or not, and an item that
    /// runs over several days appears on each of them.
    static func days(_ items: [AgendaItem]) -> [(day: Date, items: [AgendaItem])] {
        days(items, from: Calendar.current.startOfDay(for: Date()), count: horizonDays)
    }

    static func days(
        _ items: [AgendaItem],
        from first: Date,
        count: Int
    ) -> [(day: Date, items: [AgendaItem])] {
        let calendar = Calendar.current
        let window = (0..<count).compactMap {
            calendar.date(byAdding: .day, value: $0, to: first)
        }
        guard let last = window.last else { return [] }
        var byDay: [Date: [AgendaItem]] = [:]
        for item in items {
            let ends = item.end.map { $0 > item.start ? $0.addingTimeInterval(-1) : item.start } ?? item.start
            var day = max(calendar.startOfDay(for: item.start), first)
            let final = min(calendar.startOfDay(for: ends), last)
            while day <= final {
                byDay[day, default: []].append(item)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return window.map { day in
            let items = (byDay[day] ?? []).sorted {
                ($0.isAllDay ? 0 : 1, $0.start, $0.title) < ($1.isAllDay ? 0 : 1, $1.start, $1.title)
            }
            return (day, items)
        }
    }

    static func dayName(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide))
    }
}

struct CalendarSidebarLabel: View {
    @AppStorage(Agenda.dayInIconKey) private var showsDay = false

    private var symbol: String {
        guard showsDay else { return "calendar" }
        return "\(Calendar.current.component(.day, from: Date())).calendar"
    }

    private var tint: Color {
        #if os(iOS)
        .lushPink
        #else
        .red
        #endif
    }

    var body: some View {
        Label {
            Text("Calendar")
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
        }
    }
}

struct LocalEvent: Sendable {
    var identifier: String?
    var itemIdentifier: String
    var externalIdentifier: String?
    var start: Date?
    var repeats: Bool

    init(_ event: EKEvent) {
        identifier = event.eventIdentifier
        itemIdentifier = event.calendarItemIdentifier
        externalIdentifier = event.calendarItemExternalIdentifier
        start = event.occurrenceDate ?? event.startDate
        repeats = event.hasRecurrenceRules
    }
}

@MainActor
@Observable
final class AgendaStore {
    static let shared = AgendaStore()

    private(set) var items: [AgendaItem] = []
    /// The stretch of days currently loaded. Fresh, it runs from yesterday —
    /// a little past showing above today says the list scrolls both ways — to
    /// a fortnight out. It slides as she scrolls, and once it would pass
    /// `Agenda.windowLimit` the far edge is let go, so neither the list nor
    /// its memory grows without bound. The calendar itself has no edge: any
    /// day is reachable, it just isn't all held at once.
    private(set) var windowStart = AgendaStore.freshStart
    private(set) var windowEnd = AgendaStore.freshEnd

    static var freshStart: Date {
        let today = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .day, value: -1, to: today) ?? today
    }

    static var freshEnd: Date {
        let today = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .day, value: Agenda.horizonDays, to: today) ?? today
    }

    var windowDayCount: Int {
        Calendar.current.dateComponents([.day], from: windowStart, to: windowEnd).day ?? 0
    }

    var isFreshWindow: Bool {
        windowStart == Self.freshStart && windowEnd == Self.freshEnd
    }

    func resetWindow() {
        windowStart = Self.freshStart
        windowEnd = Self.freshEnd
    }

    /// Brings a linked day into the window if it has wandered off — the
    /// window may have slid months away by the time a note link is clicked.
    func ensureWindow(around day: Date) async {
        let calendar = Calendar.current
        let target = calendar.startOfDay(for: day)
        guard target < windowStart || target >= windowEnd else { return }
        windowStart = calendar.date(byAdding: .day, value: -1, to: target) ?? target
        windowEnd = calendar.date(byAdding: .day, value: Agenda.horizonDays, to: target) ?? target
        await reload()
    }
    /// Where she was when she last left the calendar, so coming back lands
    /// there instead of at today. Ignored by observation: it is written on
    /// every scroll tick, and observed writes at that rate invalidate the
    /// view mid-gesture. It is only ever read at screen creation.
    @ObservationIgnored var restoreDay: Date?
    /// Set by a link into the Calendar view: the day to scroll to, and the
    /// item to pick out when it gets there.
    var focusDay: Date?
    var focusItem: String?
    private(set) var access = EKEventStore.authorizationStatus(for: .event)
    private(set) var reminderAccess = EKEventStore.authorizationStatus(for: .reminder)

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?

    /// `eventIdentifier` is `<store UUID>:<external UID>` — only the half after
    /// the colon travels, so a note written on another device has to find the
    /// event again through the UID they share. A clean series comes back as
    /// just its master; detached occurrences come back alongside it, and the
    /// one starting nearest the occurrence the note was taken at is the one
    /// she meant.
    func localEvent(uid: String, occurrence: Date?) async -> LocalEvent? {
        guard access == .fullAccess else { return nil }
        let events = await items(for: uid)
        guard let occurrence, events.count > 1 else { return events.first }
        func gap(_ event: LocalEvent) -> TimeInterval {
            abs((event.start ?? .distantPast).timeIntervalSince(occurrence))
        }
        return events.min { gap($0) < gap($1) }
    }

    /// Notes written before links moved to the shared UID stored this device's
    /// `eventIdentifier` instead — but that is `<store UUID>:<uid>`, so the uid
    /// is still in there and those notes keep working without being rewritten.
    private func items(for uid: String) async -> [LocalEvent] {
        let store = self.store
        return await Task.detached {
            var found = store.calendarItems(withExternalIdentifier: uid)
            if found.isEmpty, let colon = uid.firstIndex(of: ":") {
                found = store.calendarItems(withExternalIdentifier: String(uid[uid.index(after: colon)...]))
            }
            return found.compactMap { $0 as? EKEvent }.map(LocalEvent.init)
        }.value
    }

    /// Opens the item where the note means it. Everything is built from the
    /// event this device found, so it works wherever the note was written. A
    /// detached occurrence carries `/RID=` on its UID; Calendar wants the master
    /// it broke off from, with the date doing the work of picking the instance.
    @discardableResult
    func openExternally(for id: String) async -> Bool {
        if id.hasPrefix(Agenda.reminderPrefix) {
            let uuid = String(id.dropFirst(Agenda.reminderPrefix.count))
            guard let url = URL(string: "x-apple-reminderkit://REMCDReminder/\(uuid)") else { return false }
            ExternalBrowser.open(url)
            return true
        }
        let key = Agenda.eventKey(id)
        let master = key.uid.components(separatedBy: "/RID=").first ?? key.uid
        guard let event = await localEvent(uid: master, occurrence: key.occurrence),
              let identifier = event.identifier
        else { return false }
        #if os(macOS)
        // The event link travels to where the event *starts*, which for a
        // series is its first occurrence — years back from the one the note is
        // about. The occurrence link goes the other way: it picks its date out
        // of whatever Calendar already shows, but won't travel to it. So a
        // series is scripted to the day first, then sent the link that selects
        // it once it is there.
        guard let occurrence = key.occurrence, event.repeats else {
            guard let url = URL(
                string: "ical://ekevent/\(Agenda.escapePath(identifier))?method=show&options=more"
            ) else { return false }
            ExternalBrowser.open(url)
            return true
        }
        let stamp = Agenda.occurrenceStamp.string(from: occurrence)
        guard let select = URL(
            string: "ical://occurrence/\(stamp)/\(event.itemIdentifier)?method=show&options=more"
        ) else { return false }
        // Scripting Calendar blocks until it has launched and navigated, which
        // is far too long to hold the main actor. The script is built and run
        // entirely on this task, never shared across threads.
        Task.detached {
            Agenda.showDay(occurrence)
            await MainActor.run { ExternalBrowser.open(select) }
        }
        return true
        #else
        // iOS carries the occurrence in the link itself and needs none of this.
        guard let uuid = identifier.components(separatedBy: ":").first,
              let external = event.externalIdentifier
        else { return false }
        let when = key.occurrence ?? event.start ?? Date()
        let seconds = Int(when.timeIntervalSinceReferenceDate)
        guard let url = URL(
            string: "x-apple-calevent://\(uuid)/\(Agenda.escapeStrict(external))?o=\(seconds)"
        ) else { return false }
        ExternalBrowser.open(url)
        return true
        #endif
    }

    var today: [AgendaItem] {
        items.filter { Calendar.current.isDateInToday($0.start) }
    }

    var upcoming: [AgendaItem] {
        items.filter { !Calendar.current.isDateInToday($0.start) }
    }

    func refresh() async {
        watchStore()
        access = EKEventStore.authorizationStatus(for: .event)
        if access == .notDetermined {
            _ = try? await store.requestFullAccessToEvents()
            access = EKEventStore.authorizationStatus(for: .event)
        }
        reminderAccess = EKEventStore.authorizationStatus(for: .reminder)
        if reminderAccess == .notDetermined {
            _ = try? await store.requestFullAccessToReminders()
            reminderAccess = EKEventStore.authorizationStatus(for: .reminder)
        }
        await reload()
    }

    func requestAccess() async {
        _ = try? await store.requestFullAccessToEvents()
        _ = try? await store.requestFullAccessToReminders()
        access = EKEventStore.authorizationStatus(for: .event)
        reminderAccess = EKEventStore.authorizationStatus(for: .reminder)
        await reload()
    }

    private func watchStore() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.reload() }
            }
        }
    }

    private func reload() async {
        items = await fetch(from: windowStart, to: windowEnd)
    }

    /// Another fortnight of the future. Only the new slice is fetched — an
    /// item spanning the seam arrives twice and is dropped by its row key —
    /// and once the window would pass its limit, the deepest past is let go.
    func extendHorizon() async {
        let calendar = Calendar.current
        guard let end = calendar.date(byAdding: .day, value: Agenda.horizonDays, to: windowEnd) else { return }
        let seam = windowEnd
        windowEnd = end
        if let floor = calendar.date(byAdding: .day, value: -Agenda.windowLimit, to: end), windowStart < floor {
            windowStart = floor
        }
        let newer = await fetch(from: seam, to: end)
        let known = Set(items.map(\.rowKey))
        let start = windowStart
        items = (items.filter { ($0.end ?? $0.start) >= start } + newer.filter { !known.contains($0.rowKey) })
            .sorted { $0.start < $1.start }
    }

    /// Another fortnight of the past, mirrored: the farthest future is let go
    /// once the window would pass its limit.
    func extendBack() async {
        let calendar = Calendar.current
        guard let start = calendar.date(byAdding: .day, value: -Agenda.horizonDays, to: windowStart) else { return }
        let seam = windowStart
        windowStart = start
        if let ceiling = calendar.date(byAdding: .day, value: Agenda.windowLimit, to: start), windowEnd > ceiling {
            windowEnd = ceiling
        }
        let older = await fetch(from: start, to: seam)
        let known = Set(items.map(\.rowKey))
        let end = windowEnd
        items = (older.filter { !known.contains($0.rowKey) } + items.filter { $0.start < end })
            .sorted { $0.start < $1.start }
    }

    /// A straight read for the chat tools: the coming days, fetched fresh so
    /// it doesn't depend on where the window has slid to.
    func next(days: Int) async -> [AgendaItem] {
        let calendar = Calendar.current
        let from = calendar.startOfDay(for: Date())
        let to = calendar.date(byAdding: .day, value: days, to: from) ?? from
        return await fetch(from: from, to: to)
    }

    private func fetch(from: Date, to: Date) async -> [AgendaItem] {
        let shownIds = Set(NotesModel.shared.focus.state?.shownCalendarIds ?? [])
        var next: [AgendaItem] = []
        if access == .fullAccess {
            let ekCalendars: [EKCalendar]? = shownIds.isEmpty
                ? nil
                : store.calendars(for: .event).filter { shownIds.contains($0.calendarIdentifier) }
            let predicate = store.predicateForEvents(withStart: from, end: to, calendars: ekCalendars)
            let store = self.store
            next += await Task.detached {
                store.events(matching: predicate).compactMap(AgendaItem.init)
            }.value
        }
        if reminderAccess == .fullAccess {
            next += await reminders(from: from, to: to, shownIds: shownIds)
        }
        return next.sorted { $0.start < $1.start }
    }

    private func reminders(from: Date, to: Date, shownIds: Set<String>) async -> [AgendaItem] {
        let ekCalendars: [EKCalendar]?
        if shownIds.isEmpty {
            ekCalendars = nil
        } else {
            let filtered = store.calendars(for: .reminder).filter { shownIds.contains($0.calendarIdentifier) }
            guard !filtered.isEmpty else { return [] }
            ekCalendars = filtered
        }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: from,
            ending: to,
            calendars: ekCalendars
        )
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).compactMap(AgendaItem.init))
            }
        }
    }
}

enum CalendarLinks {
    static let changed = Notification.Name("io.lush.calendarLinksChanged")

    private static let key = "calendarEventNotes"
    private static let headsKey = "calendarEventNoteHeads"

    /// The doc state each note was last read at, so a rebuild only opens the
    /// notes that have actually moved since.
    static var scannedHeads: [String: String] {
        UserDefaults.standard.dictionary(forKey: headsKey) as? [String: String] ?? [:]
    }

    private static var map: [String: [String]] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
    }

    static var noteUrls: [String] { Array(map.keys) }

    static var noteUrlByItem: [String: String] {
        var result: [String: String] = [:]
        for (note, items) in map {
            for item in items where result[item] == nil { result[item] = note }
        }
        return result
    }

    static func notes(for itemId: String) -> [String] {
        map.compactMap { $0.value.contains(itemId) ? $0.key : nil }
    }

    static func itemIds(for noteUrl: String) -> [String] {
        map[noteUrl] ?? []
    }

    /// A note pinned to this occurrence wins; a note kept for the whole series
    /// stands in when the occurrence has none of its own.
    static func notes(for item: AgendaItem) -> [String] {
        let occurrence = notes(for: item.id)
        guard occurrence.isEmpty, let seriesId = item.seriesId else { return occurrence }
        return notes(for: seriesId)
    }

    /// The map is a cache of what the notes themselves say, so it can always be
    /// rebuilt from their spans — which is how it reaches a second device,
    /// where the notes sync but this index never did. Only the notes actually
    /// read are replaced; the rest keep whatever they had.
    static func replace(_ links: [String: [String]], scanned: Set<String>, heads: [String: String]) {
        var nextHeads = scannedHeads
        nextHeads.merge(heads) { _, new in new }
        UserDefaults.standard.set(nextHeads, forKey: headsKey)
        var next = map.filter { !scanned.contains($0.key) }
        next.merge(links) { _, new in new }
        guard next != map else { return }
        UserDefaults.standard.set(next, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func set(_ itemIds: [String], for noteUrl: String) {
        var next = map
        if itemIds.isEmpty {
            guard next.removeValue(forKey: noteUrl) != nil else { return }
        } else {
            guard next[noteUrl] != itemIds else { return }
            next[noteUrl] = itemIds
        }
        UserDefaults.standard.set(next, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func eventIds(in spans: [SpanNode]) -> [String] {
        spans.compactMap { span in
            guard case .block(let block) = span, block.type == "calendar-event" else { return nil }
            return block.attrs["event"]?.stringValue
        }
    }
}

extension BlockValue {
    static func calendarEventBlock(_ item: AgendaItem, series: Bool = false) -> BlockValue {
        var attrs: [String: JSONValue] = [
            "event": .string(series ? (item.seriesId ?? item.id) : item.id),
            "kind": .string(item.kind.rawValue),
            "title": .string(item.title),
            "start": .string(Agenda.isoLocal.string(from: item.start)),
        ]
        if series {
            attrs["series"] = .bool(true)
            if let text = item.recurrenceText { attrs["repeat"] = .string(text) }
        }
        if let end = item.end { attrs["end"] = .string(Agenda.isoLocal.string(from: end)) }
        if item.isAllDay { attrs["allDay"] = .bool(true) }
        if !item.listName.isEmpty { attrs["calendar"] = .string(item.listName) }
        if let location = item.location { attrs["location"] = .string(location) }
        if let hex = item.colorHex { attrs["color"] = .string(hex) }
        return BlockValue(type: "calendar-event", attrs: attrs, isEmbed: true)
    }

    var calendarEventColor: Color {
        attrs["color"]?.stringValue.flatMap(Agenda.color(hex:)) ?? .accentColor
    }

    var calendarEventDay: Date? {
        calendarEventStart.map { Calendar.current.startOfDay(for: $0) }
    }

    /// Whether the trailing glyph is worth drawing. Cheap enough for a view
    /// body — finding the item costs an EventKit lookup, so that waits for the
    /// click.
    var opensExternally: Bool { type == "calendar-event" }

    @MainActor
    @discardableResult
    func openExternally() async -> Bool {
        guard opensExternally, let id = attrs["event"]?.stringValue else { return false }
        return await AgendaStore.shared.openExternally(for: id)
    }

    var calendarEventTitle: String? {
        guard type == "calendar-event" else { return nil }
        return attrs["title"]?.stringValue
    }

    var calendarEventStart: Date? {
        guard type == "calendar-event" else { return nil }
        return attrs["start"]?.stringValue.flatMap(Agenda.iso.date(from:))
    }

    var calendarEventEnd: Date? {
        guard type == "calendar-event" else { return nil }
        return attrs["end"]?.stringValue.flatMap(Agenda.iso.date(from:))
    }

    var calendarEventSearchText: String? {
        guard let title = calendarEventTitle else { return nil }
        var parts = [title]
        if let start = calendarEventStart {
            parts.append(start.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
            if attrs["allDay"]?.boolValue == true {
                parts.append("all day")
            } else {
                parts.append(start.formatted(date: .omitted, time: .shortened))
            }
        }
        if let location = attrs["location"]?.stringValue { parts.append(location) }
        if let calendar = attrs["calendar"]?.stringValue { parts.append(calendar) }
        if let repeats = attrs["repeat"]?.stringValue { parts.append(repeats) }
        parts.append(attrs["kind"]?.stringValue == AgendaItem.Kind.reminder.rawValue ? "reminder" : "calendar event")
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct CalendarEventInlineView: View {
    let block: BlockValue

    private var isReminder: Bool {
        block.attrs["kind"]?.stringValue == AgendaItem.Kind.reminder.rawValue
    }

    private var whenText: String {
        guard let start = block.calendarEventStart else { return "" }
        if block.attrs["series"]?.boolValue == true {
            return block.attrs["repeat"]?.stringValue ?? "repeating"
        }
        let day = start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        if block.attrs["allDay"]?.boolValue == true { return "\(day) · all day" }
        let from = start.formatted(date: .omitted, time: .shortened)
        guard let end = block.calendarEventEnd, end > start else { return "\(day) · \(from)" }
        return "\(day) · \(from) – \(end.formatted(date: .omitted, time: .shortened))"
    }

    var body: some View {
        let tint = block.calendarEventColor
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(block.calendarEventTitle ?? "Calendar Item")
                    .font(.system(size: RichText.bodySize * 0.92, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: isReminder ? "checklist" : "clock")
                    Text(whenText)
                    if let location = block.attrs["location"]?.stringValue {
                        Image(systemName: "mappin.and.ellipse")
                            .padding(.leading, 4)
                        Text(location).lineLimit(1)
                    }
                    if let calendar = block.attrs["calendar"]?.stringValue {
                        Text("· \(calendar)").lineLimit(1)
                    }
                }
                .font(.system(size: RichText.bodySize * 0.82))
                .opacity(0.75)
            }
            Spacer(minLength: 8)
            if block.opensExternally {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: RichText.bodySize * 0.92, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(tint.opacity(0.45))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(tint.opacity(0.6), lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .foregroundStyle(tint.mix(with: .primary, by: 0.65))
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(0.28))
        )
    }

    /// The trailing zone of the drawn box, where the Calendar.app glyph sits.
    static let buttonZone: CGFloat = 48
}

extension AgendaItem {
    @MainActor
    func openExternally() { Task { await AgendaStore.shared.openExternally(for: id) } }
}

extension NotesModel {
    func noteUrl(for item: AgendaItem) -> String? {
        CalendarLinks.notes(for: item).first
    }

    @discardableResult
    func createNote(for item: AgendaItem, series: Bool = false, snap: ContextSnapshot? = nil) async -> String? {
        guard let core else { return nil }
        guard let folder = await calendarFolder() ?? folderUrl ?? inboxUrl ?? rootFolderUrls.first
        else {
            status = "Couldn't create note: no folder yet"
            return nil
        }
        let pending = snap != nil && ContextTracker.stampsContext
        do {
            let url = try await Task.detached { [core, folder, item, series, snap, pending] () -> String in
                let url = try core.createNoteIn(folderUrl: folder, title: item.title)
                let initial: [SpanNode] = [
                    .block(.creationBlock(snap: snap, pending: pending)),
                    .block(.calendarEventBlock(item, series: series)),
                    .block(.heading(level: 1)),
                    .text(item.title, [:]),
                ]
                _ = try? core.updateNoteSpans(url: url, spansJson: SpanNode.encodeList(initial), heads: nil)
                return url
            }.value
            CalendarLinks.set([series ? (item.seriesId ?? item.id) : item.id], for: url)
            pendingFocusUrl = url
            selectedNoteUrl = url
            refreshNotes()
            return url
        } catch {
            status = "Couldn't create note: \(error.localizedDescription)"
            return nil
        }
    }
}
