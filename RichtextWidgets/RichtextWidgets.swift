// Widget extension sources — add via File > New > Target > Widget Extension
// (name it RichtextWidgets, uncheck "Include Configuration App Intent"),
// then replace the generated Swift file with this one.
import WidgetKit
import SwiftUI

struct LaunchEntry: TimelineEntry {
    let date = Date()
}

struct LaunchProvider: TimelineProvider {
    func placeholder(in context: Context) -> LaunchEntry {
        LaunchEntry()
    }

    func getSnapshot(in context: Context, completion: @escaping (LaunchEntry) -> Void) {
        completion(LaunchEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LaunchEntry>) -> Void) {
        completion(Timeline(entries: [LaunchEntry()], policy: .never))
    }
}

struct LaunchWidgetView: View {
    let symbol: String
    let title: String
    let url: URL

    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if family == .accessoryCircular {
                Image(systemName: symbol)
                    .font(.title2)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.title)
                    Text(title)
                        .font(.caption.weight(.medium))
                }
            }
        }
        .widgetURL(url)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct NewNoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "party.chee.richtext.new-note", provider: LaunchProvider()) { _ in
            LaunchWidgetView(
                symbol: "square.and.pencil",
                title: "New Note",
                url: URL(string: "richtext://new-note")!
            )
        }
        .configurationDisplayName("New Note")
        .description("Start a new note.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

struct QuickNoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "party.chee.richtext.quick-note", provider: LaunchProvider()) { _ in
            LaunchWidgetView(
                symbol: "bolt.circle",
                title: "Quick Note",
                url: URL(string: "richtext://quick-note")!
            )
        }
        .configurationDisplayName("Quick Note")
        .description("Open your Quick Note.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

@main
struct RichtextWidgets: WidgetBundle {
    var body: some Widget {
        NewNoteWidget()
        QuickNoteWidget()
    }
}
