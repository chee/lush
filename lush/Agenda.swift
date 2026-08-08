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

    static func days(_ items: [AgendaItem]) -> [(day: Date, items: [AgendaItem])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: items) { calendar.startOfDay(for: $0.start) }
        return grouped.keys.sorted().map { day in
            let items = (grouped[day] ?? []).sorted {
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
            Text("Calendar").fontWeight(.bold)
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
        return BlockValue(type: "calendar-event", attrs: attrs, isEmbed: true)
    }

    var calendarEventTitle: String? {
        guard type == "calendar-event" else { return nil }
        return attrs["title"]?.stringValue
    }
}

struct CalendarEventInlineView: View {
    let block: BlockValue

    private var isReminder: Bool {
        block.attrs["kind"]?.stringValue == AgendaItem.Kind.reminder.rawValue
    }

    private var start: Date? {
        block.attrs["start"]?.stringValue.flatMap(Agenda.iso.date(from:))
    }

    private var end: Date? {
        block.attrs["end"]?.stringValue.flatMap(Agenda.iso.date(from:))
    }

    private var whenText: String {
        guard let start else { return "" }
        let day = start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        if block.attrs["allDay"]?.boolValue == true { return "\(day) · all day" }
        let from = start.formatted(date: .omitted, time: .shortened)
        guard let end, end > start else { return "\(day) · \(from)" }
        return "\(day) · \(from) – \(end.formatted(date: .omitted, time: .shortened))"
    }

    var body: some View {
        Button {
            AppRouter.shared.pending = .calendar
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isReminder ? "checklist" : "calendar")
                    .font(.system(size: 16))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(block.attrs["title"]?.stringValue ?? "Untitled Event")
                        .font(.system(size: RichText.bodySize, weight: .medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(whenText)
                        if let location = block.attrs["location"]?.stringValue {
                            Text("·")
                            Text(location).lineLimit(1)
                        }
                        if let calendar = block.attrs["calendar"]?.stringValue {
                            Text("·")
                            Text(calendar).lineLimit(1)
                        }
                    }
                    .font(.system(size: max(10, RichText.bodySize - 3)))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.1))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show in Calendar")
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
