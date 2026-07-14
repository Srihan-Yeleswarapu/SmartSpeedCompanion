// iOS 26+ WidgetKit
import WidgetKit
import SwiftUI

struct SpeedWidgetEntry: TimelineEntry {
    let date: Date
    let speed: Int
    let limit: Int
    let statusId: String
    /// "Metric" / "Imperial" — mirrored from the main app's
    /// `Settings → NAVIGATION → UNITS` picker via
    /// `SpeedFormatting.writeMeasurementSystemToAppGroup(_:)`. Defaults
    /// to Imperial so pre-mirror widgets still render sanely.
    let measurementSystem: String
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SpeedWidgetEntry {
        SpeedWidgetEntry(
            date: Date(),
            speed: 45,
            limit: 45,
            statusId: "safe",
            measurementSystem: "Imperial"
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (SpeedWidgetEntry) -> ()) {
        let entry = SpeedWidgetEntry(
            date: Date(),
            speed: 50,
            limit: 45,
            statusId: "warning",
            measurementSystem: SpeedFormatting.measurementSystemFromAppGroup()
        )
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
        // Reads from AppGroup UserDefaults set by the main app. Widgets run
        // in their own process, so we cannot use standard UserDefaults —
        // every value must come through the shared App Group suite
        // (`SpeedFormatting.appGroupSuite`).
        let sharedDefaults = UserDefaults(suiteName: SpeedFormatting.appGroupSuite)
        let speed = sharedDefaults?.integer(forKey: "widgetSpeed") ?? 0
        let limit = sharedDefaults?.integer(forKey: "widgetLimit") ?? 0
        let status = sharedDefaults?.string(forKey: "widgetStatus") ?? "safe"
        let measurementSystem = sharedDefaults?.string(
            forKey: SpeedFormatting.widgetMeasurementSystemAppGroupKey) ?? "Imperial"

        let entry = SpeedWidgetEntry(
            date: Date(),
            speed: speed,
            limit: limit,
            statusId: status,
            measurementSystem: measurementSystem
        )
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
        // TestFlight 2.1.4 feedback: widget previously hard-coded "MPH"
        // and the raw mph limit, so metric users saw "Limit 65 MPH"
        // instead of "Limit 105 KMH". Route through SpeedFormatting for
        // both the value and the unit so the App-Group-mirrored setting
        // controls every label on screen.
        let unitShort = SpeedFormatting.unitLabelShort(measurementSystem: entry.measurementSystem)
        let limitDisplay = SpeedFormatting.displayLimit(
            forMph: entry.limit,
            measurementSystem: entry.measurementSystem
        )

        VStack {
            Text("\(entry.speed)")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(unitShort)
                .font(.caption.weight(.semibold))
                .foregroundColor(color.opacity(0.75))
            Text(entry.limit == 0 ? "Limit --" : "Limit \(limitDisplay) \(unitShort)")
                .font(.caption2)
                .foregroundColor(.gray)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .containerBackground(DesignSystem.bgCard, for: .widget)
    }
}

@main
struct SpeedWidgetBundle: WidgetBundle {
    var body: some Widget {
        SpeedWidget()
        SpeedLiveActivityView()
    }
}

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