// Path: Features/iOS26/LiveActivities/SpeedLiveActivityView.swift
//
// Refactored to delegate from `body` into private helper closures so
// the Swift type-checker evaluates each region in bounded time rather
// than blowing up on the combined view-graph (CI was OOM-killed during
// `SwiftDriver SmartSpeedCompanionWidget normal arm64`). Behavior is
// unchanged from the previous inlined version.
import SwiftUI
import WidgetKit
import ActivityKit
import CoreLocation

@available(iOS 16.1, *)
struct SpeedLiveActivityView: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SpeedActivityAttributes.self) { context in
            lockScreenView(context: context)
        } dynamicIsland: { context in
            dynamicIsland(context: context)
        }
    }

    // MARK: - Lock-screen / StandBy card
    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<SpeedActivityAttributes>) -> some View {
        let measurementSystem = SpeedFormatting.measurementSystemFromAppGroup()
        let unitShort = SpeedFormatting.unitLabelShort(measurementSystem: measurementSystem)
        let limitDisplay = SpeedFormatting.displayLimit(
            forMph: context.state.speedLimit,
            measurementSystem: measurementSystem
        )

        VStack(spacing: 0) {
            Rectangle()
                .fill(colorForStatus(context.state.status))
                .frame(height: 3)

            HStack(alignment: .center, spacing: 16) {
                leftColumn(context: context, unitShort: unitShort, limitDisplay: limitDisplay)
                Spacer(minLength: 8)
                rightColumn(context: context)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(DesignSystem.bgCard.opacity(0.92))
        .widgetBackground(DesignSystem.bgCard.opacity(0.8))
    }

    @ViewBuilder
    private func leftColumn(
        context: ActivityViewContext<SpeedActivityAttributes>,
        unitShort: String,
        // `SpeedFormatting.displayLimit` returns `Int`; the LIMIT caption
        // below uses it inside `\(limitDisplay)` so the Int is fine.
        limitDisplay: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            statusPill(status: context.state.status)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(context.state.speed))")
                    .font(.system(size: 40, weight: .black, design: .rounded))
                    .foregroundColor(colorForStatus(context.state.status))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unitShort)
                    .font(.system(size: 12, weight: .black))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }

            let limitText = context.state.speedLimit == 0
                ? "LIMIT \u{2014}"
                : "LIMIT \(limitDisplay) \(unitShort)"
            Text(limitText)
                .font(.caption2.weight(.bold))
                .foregroundColor(.gray)
                .lineLimit(1)
        }
    }

    // NOTE: deliberately NOT @ViewBuilder — the body mixes a `switch`
    // statement with multiple `let` declarations and a single returned
    // `Text`. @ViewBuilder would force `let label: String` to flow
    // through `buildExpression` (which requires `View`), producing
    // `'buildExpression' is unavailable: this expression does not
    // conform to 'View'`. Plain `func ... -> some View` with an
    // explicit `return` lets us treat the lets as ordinary locals.
    private func statusPill(status: String) -> some View {
        let label: String
        switch status {
        case "over":    label = "OVER LIMIT"
        case "warning": label = "WARNING"
        default:        label = "SAFE"
        }
        let tint = colorForStatus(status)
        return Text(label)
            .font(.system(size: 10, weight: .black, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.85)))
            .overlay(Capsule().stroke(tint, lineWidth: 0.5))
            .accessibilityLabel(label)
    }

    @ViewBuilder
    private func rightColumn(context: ActivityViewContext<SpeedActivityAttributes>) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            if context.state.isRecording {
                recordingBadge(context: context)
            } else if let maneuver = context.state.nextManeuver {
                maneuverSummary(context: context, maneuver: maneuver)
            }
        }
    }

    @ViewBuilder
    private func recordingBadge(context: ActivityViewContext<SpeedActivityAttributes>) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(DesignSystem.alertRed)
                .frame(width: 6, height: 6)
            Text("REC")
                .font(.caption.weight(.black))
                .foregroundColor(DesignSystem.alertRed)
        }
        Text(formatTime(context.state.sessionDuration))
            .font(.system(.caption2, design: .monospaced).bold())
            .foregroundColor(.white)
    }

    @ViewBuilder
    private func maneuverSummary(
        context: ActivityViewContext<SpeedActivityAttributes>,
        maneuver: String
    ) -> some View {
        HStack(spacing: 4) {
            if let img = context.state.nextManeuverImageName {
                Image(systemName: img)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(DesignSystem.cyan)
            }
            Text(maneuver)
                .font(.caption.weight(.bold))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        Text(formatDistance(context.state.distanceToNextTurn ?? 0))
            .font(.caption2.weight(.bold))
            .foregroundColor(DesignSystem.cyan)
    }

    // MARK: - Dynamic Island
    private func dynamicIsland(context: ActivityViewContext<SpeedActivityAttributes>) -> DynamicIsland {
        let measurementSystem = SpeedFormatting.measurementSystemFromAppGroup()
        let unitShort = SpeedFormatting.unitLabelShort(measurementSystem: measurementSystem)
        let limitDisplay = SpeedFormatting.displayLimit(
            forMph: context.state.speedLimit,
            measurementSystem: measurementSystem
        )

        return DynamicIsland {
            // Inlined (not via a private helper) so the
            // `DynamicIslandExpandedContentBuilder` can see the actual
            // `ConditionalContent<...>` type from the `if let` branch.
            // When wrapped in an opaque `some View` helper, the
            // `Expanded` generic parameter of `DynamicIslandExpandedRegion`
            // could not be inferred.
            DynamicIslandExpandedRegion(.center) {
                if let maneuver = context.state.nextManeuver {
                    expandedWithManeuver(context: context, maneuver: maneuver)
                } else {
                    expandedWithoutManeuver(context: context, unitShort: unitShort, limitDisplay: limitDisplay)
                }
            }
            DynamicIslandExpandedRegion(.bottom) {
                expandedBottom(status: context.state.status)
            }
        } compactLeading: {
            compactLeading(context: context)
        } compactTrailing: {
            compactTrailing(context: context)
        } minimal: {
            minimal(context: context)
        }
    }

    // `expandedCenter` was inlined into the `DynamicIslandExpandedRegion(.center)`
    // closure above to satisfy `DynamicIslandExpandedContentBuilder`'s generic
    // `Expanded` parameter inference — see the inline note at the call site.

    @ViewBuilder
    private func expandedWithManeuver(
        context: ActivityViewContext<SpeedActivityAttributes>,
        maneuver: String
    ) -> some View {
        HStack(spacing: 20) {
            if let img = context.state.nextManeuverImageName {
                Image(systemName: img)
                    .font(.title)
                    .foregroundColor(DesignSystem.cyan)
            }
            VStack(alignment: .leading) {
                Text(maneuver)
                    .font(.headline)
                Text(formatDistance(context.state.distanceToNextTurn ?? 0))
                    .font(.subheadline.bold())
                    .foregroundColor(DesignSystem.cyan)
            }
            Spacer()
            if let eta = context.state.eta {
                VStack(alignment: .trailing) {
                    Text("ETA")
                        .font(.caption)
                    Text(eta, format: .dateTime.hour().minute())
                        .font(.headline)
                }
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func expandedWithoutManeuver(
        context: ActivityViewContext<SpeedActivityAttributes>,
        unitShort: String,
        // See `leftColumn` for why this is `Int` (mirrors the actual
        // return type of `SpeedFormatting.displayLimit`).
        limitDisplay: Int
    ) -> some View {
        VStack {
            Text("\(Int(context.state.speed))")
                .font(.system(size: 60, weight: .black, design: .rounded))
                .foregroundColor(colorForStatus(context.state.status))

            HStack(spacing: 20) {
                Text("LIMIT: \(limitDisplay) \(unitShort)")
                if context.state.isRecording {
                    Text(formatTime(context.state.sessionDuration))
                        .monospacedDigit()
                }
            }
            .font(.caption.bold())
            .foregroundColor(.gray)
        }
    }

    @ViewBuilder
    private func expandedBottom(status: String) -> some View {
        let tint = colorForStatus(status)
        ZStack {
            Capsule()
                .fill(tint.opacity(0.2))
                .frame(height: 30)
            Text(status.uppercased())
                .font(.caption.bold())
                .foregroundColor(tint)
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func compactLeading(context: ActivityViewContext<SpeedActivityAttributes>) -> some View {
        if let img = context.state.nextManeuverImageName {
            Image(systemName: img)
                .foregroundColor(DesignSystem.cyan)
        } else {
            Text("\(Int(context.state.speed))")
                .font(.system(.headline, design: .rounded).bold())
                .foregroundColor(colorForStatus(context.state.status))
        }
    }

    @ViewBuilder
    private func compactTrailing(context: ActivityViewContext<SpeedActivityAttributes>) -> some View {
        if context.state.nextManeuver != nil {
            Text(formatDistance(context.state.distanceToNextTurn ?? 0))
                .font(.caption.bold())
                .foregroundColor(DesignSystem.cyan)
        } else {
            Circle()
                .fill(colorForStatus(context.state.status))
                .frame(width: 8, height: 8)
        }
    }

    @ViewBuilder
    private func minimal(context: ActivityViewContext<SpeedActivityAttributes>) -> some View {
        if let img = context.state.nextManeuverImageName {
            Image(systemName: img)
                .foregroundColor(DesignSystem.cyan)
        } else {
            Text("\(Int(context.state.speed))")
                .font(.system(.caption, design: .rounded).bold())
                .foregroundColor(colorForStatus(context.state.status))
        }
    }

    // MARK: - Helpers
    private func formatDistance(_ distance: CLLocationDistance) -> String {
        SpeedFormatting.navigationDistanceLabel(
            forMeters: distance,
            measurementSystem: SpeedFormatting.measurementSystemFromAppGroup()
        )
    }

    private func colorForStatus(_ status: String) -> Color {
        switch status {
        case "over": return DesignSystem.alertRed
        case "warning": return DesignSystem.amber
        default: return DesignSystem.neonGreen
        }
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let i = Int(interval)
        return String(format: "%02d:%02d", (i % 3600) / 60, i % 60)
    }
}

extension View {
    // Helper to support StandBy seamlessly in iOS 17 while targeting 16
    @ViewBuilder
    func widgetBackground(_ color: Color) -> some View {
        if #available(iOS 17.0, *) {
            self.containerBackground(for: .widget) { color }
        } else {
            self.background(color)
        }
    }
}
