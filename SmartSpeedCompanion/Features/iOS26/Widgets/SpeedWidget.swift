// iOS 26+ WidgetKit
import WidgetKit
import SwiftUI

struct SpeedWidgetEntry: TimelineEntry {
    let date: Date
    let speed: Int
    let limit: Int
    let statusId: String
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SpeedWidgetEntry {
        SpeedWidgetEntry(date: Date(), speed: 45, limit: 45, statusId: "safe")
    }

    func getSnapshot(in context: Context, completion: @escaping (SpeedWidgetEntry) -> ()) {
        let entry = SpeedWidgetEntry(date: Date(), speed: 50, limit: 45, statusId: "warning")
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
        // Reads from AppGroup UserDefaults set by the main app
        let sharedDefaults = UserDefaults(suiteName: "group.com.smartspeedcompanion.app")
        let speed = sharedDefaults?.integer(forKey: "widgetSpeed") ?? 0
        let limit = sharedDefaults?.integer(forKey: "widgetLimit") ?? 0
        let status = sharedDefaults?.string(forKey: "widgetStatus") ?? "safe"
        
        let entry = SpeedWidgetEntry(date: Date(), speed: speed, limit: limit, statusId: status)
        let timeline = Timeline(entries: [entry], policy: .atEnd)
        completion(timeline)
    }
}

struct SpeedWidgetEntryView : View {
    var entry: Provider.Entry

    var color: Color {
        if entry.statusId == "over" { return DesignSystem.alertRed }
        if entry.statusId == "warning" { return DesignSystem.amber }
        return DesignSystem.neonGreen
    }

    var body: some View {
        VStack {
            Text("\(entry.speed)")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text("MPH")
                .font(.caption)
            Text("Limit \(entry.limit)")
                .font(.caption2)
                .foregroundColor(.gray)
        }
        .containerBackground(DesignSystem.bgCard, for: .widget)
    }
}

@main
struct SpeedWidget: Widget {
    let kind: String = "SpeedWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            SpeedWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Smart Speed")
        .description("Shows your current speed.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}
