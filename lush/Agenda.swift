import SwiftUI
import EventKit

struct AgendaItem: Identifiable, Equatable {
    enum Kind: String {
        case event
        case reminder
    }

    var id: String
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
    init?(_ event: EKEvent) {
        guard let start = event.startDate else { return nil }
        let base = event.eventIdentifier ?? event.calendarItemIdentifier
        id = "\(base)|\(Agenda.iso.string(from: start))"
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
        id = "reminder:\(reminder.calendarItemIdentifier)"
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
    static let sidebarTag = "agenda:calendar"
    static let dayInIconKey = "calendarIconShowsDay"
    static let horizonDays = 14

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
        let calendar = Calendar.current
        let first = calendar.startOfDay(for: Date())
        let window = (0..<horizonDays).compactMap {
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

    var body: some View {
        Label {
            Text("Calendar")
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.red)
        }
    }
}

@MainActor
@Observable
final class AgendaStore {
    static let shared = AgendaStore()

    private(set) var items: [AgendaItem] = []
    /// Set by a link into the Calendar view: the day to scroll to, and the
    /// item to pick out when it gets there.
    var focusDay: Date?
    var focusItem: String?
    private(set) var access = EKEventStore.authorizationStatus(for: .event)
    private(set) var reminderAccess = EKEventStore.authorizationStatus(for: .reminder)

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?

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
        let calendar = Calendar.current
        let from = calendar.startOfDay(for: Date())
        let to = calendar.date(byAdding: .day, value: Agenda.horizonDays, to: from) ?? from
        var next: [AgendaItem] = []
        if access == .fullAccess {
            let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
            next += store.events(matching: predicate).compactMap(AgendaItem.init)
        }
        if reminderAccess == .fullAccess {
            next += await reminders(from: from, to: to)
        }
        items = next.sorted { $0.start < $1.start }
    }

    private func reminders(from: Date, to: Date) async -> [AgendaItem] {
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: from,
            ending: to,
            calendars: nil
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
    static func calendarEventBlock(_ item: AgendaItem) -> BlockValue {
        var attrs: [String: JSONValue] = [
            "event": .string(item.id),
            "kind": .string(item.kind.rawValue),
            "title": .string(item.title),
            "start": .string(Agenda.iso.string(from: item.start)),
        ]
        if let end = item.end { attrs["end"] = .string(Agenda.iso.string(from: end)) }
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

    /// Opens the item in Calendar.app — the specific event when its identifier
    /// survived, otherwise the day it sits on.
    var calendarAppURL: URL? {
        guard let start = calendarEventStart else { return nil }
        #if os(macOS)
        if attrs["kind"]?.stringValue != AgendaItem.Kind.reminder.rawValue,
           let identifier = attrs["event"]?.stringValue?.split(separator: "|").first,
           let escaped = String(identifier).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            return URL(string: "ical://ekevent/\(escaped)?method=show&options=more")
        }
        #endif
        return URL(string: "calshow:\(Int(start.timeIntervalSinceReferenceDate))")
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
                    .font(.system(size: max(11, RichText.bodySize - 1), weight: .semibold))
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
                .font(.system(size: max(10, RichText.bodySize - 3)))
                .opacity(0.75)
            }
            Spacer(minLength: 8)
            if block.calendarAppURL != nil {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: max(13, RichText.bodySize - 1), weight: .semibold))
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
    var calendarAppURL: URL? {
        #if os(macOS)
        if kind == .event,
           let identifier = id.split(separator: "|").first,
           let escaped = String(identifier).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            return URL(string: "ical://ekevent/\(escaped)?method=show&options=more")
        }
        #endif
        return URL(string: "calshow:\(Int(start.timeIntervalSinceReferenceDate))")
    }
}

extension NotesModel {
    func noteUrl(for item: AgendaItem) -> String? {
        CalendarLinks.notes(for: item.id).first
    }

    @discardableResult
    func createNote(for item: AgendaItem, snap: ContextSnapshot? = nil) async -> String? {
        guard let core else { return nil }
        guard let folder = folderUrl ?? inboxUrl ?? rootFolderUrls.first else {
            status = "Couldn't create note: no folder yet"
            return nil
        }
        do {
            let url = try await Task.detached { [core, folder, item, snap] () -> String in
                let url = try core.createNoteIn(folderUrl: folder, title: item.title)
                let initial: [SpanNode] = [
                    .block(.creationBlock(snap: snap)),
                    .block(.calendarEventBlock(item)),
                    .block(.heading(level: 1)),
                    .text(item.title, [:]),
                ]
                _ = try? core.updateNoteSpans(url: url, spansJson: SpanNode.encodeList(initial), heads: nil)
                return url
            }.value
            CalendarLinks.set([item.id], for: url)
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
