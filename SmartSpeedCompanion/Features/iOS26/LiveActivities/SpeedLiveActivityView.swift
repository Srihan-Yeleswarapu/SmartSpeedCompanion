// Path: Features/iOS26/LiveActivities/SpeedLiveActivityView.swift
import SwiftUI
import WidgetKit
import ActivityKit
import CoreLocation

@available(iOS 16.1, *)
struct SpeedLiveActivityView: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SpeedActivityAttributes.self) { context in
            // Lock Screen / StandBy.
            //
            // TestFlight 2.1.4 feedback: the Live Activity previously hard-coded
            // "LIMIT \(speedLimit) MPH" regardless of the user's UNITS setting.
            // The Activity runs in a separate target and can't read the
            // main app's standard UserDefaults, so we mirror the unit via
            // `SpeedFormatting.measurementSystemFromAppGroup()` (mirror is
            // written in `SettingsView.onChange(of: measurementSystem)`).
            let measurementSystem = SpeedFormatting.measurementSystemFromAppGroup()
            let unitShort = SpeedFormatting.unitLabelShort(measurementSystem: measurementSystem)
            let limitDisplay = SpeedFormatting.displayLimit(
                forMph: context.state.speedLimit,
                measurementSystem: measurementSystem
            )

            // ── Top status edge ─────────────────────────────────────────────
            // A 3pt stripe of the status color renders ABOVE the card content
            // so users see SAFE/WARNING/OVER before they read the number.
            // The bottom-bar from the previous build was hard to spot on a
            // dark Lock Screen wallpaper — top-edge wins on visibility.
            // ─────────────────────────────────────────────────────────────
            VStack(spacing: 0) {
                Rectangle()
                    .fill(colorForStatus(context.state.status))
                    .frame(height: 3)

                HStack(alignment: .center, spacing: 16) {
                    // LEFT column: status pill + speed number + LIMIT caption.
                    VStack(alignment: .leading, spacing: 4) {
                        // Compact SAFE / WARNING / OVER LIMIT badge. Inlined
                        // as a local `some View` so we keep Swift's stricter
                        // `private` (file-scope) access on the helpers below
                        // without adding a new method to `SpeedLiveActivityView`
                        // solely for visual clarity.
                        let pillLabel: String = {
                            switch context.state.status {
                            case "over":    return "OVER LIMIT"
                            case "warning": return "WARNING"
                            default:        return "SAFE"
                            }
                        }()
                        let pillColor = colorForStatus(context.state.status)
                        Text(pillLabel)
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(pillColor.opacity(0.85)))
                            .overlay(Capsule().stroke(pillColor, lineWidth: 0.5))
                            .accessibilityLabel(pillLabel)
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
                        Text(context.state.speedLimit == 0
                             ? "LIMIT \u{2014}"
                             : "LIMIT \(limitDisplay) \(unitShort)")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.gray)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    // RIGHT column: REC pill + duration, OR maneuver summary.
                    VStack(alignment: .trailing, spacing: 4) {
                        if context.state.isRecording {
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
                        } else if let maneuver = context.state.nextManeuver {
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
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(DesignSystem.bgCard.opacity(0.92))
            .widgetBackground(DesignSystem.bgCard.opacity(0.8))
            
        } dynamicIsland: { context in
            // IMPORTANT: We have to recompute these here, NOT share through
            // a value captured by the outer `content:` closure. Swift's
            // closure args to `ActivityConfiguration.init(...)` are
            // SIBLING scopes — a `let` declared in `content:` does not
            // leak into `dynamicIsland:`. Without this re-declaration the
            // widget extension target fails to compile.
            let measurementSystemDI = SpeedFormatting.measurementSystemFromAppGroup()
            let unitShortDI = SpeedFormatting.unitLabelShort(measurementSystem: measurementSystemDI)
            let limitDisplayDI = SpeedFormatting.displayLimit(
                forMph: context.state.speedLimit,
                measurementSystem: measurementSystemDI
            )
            DynamicIsland {
                // Expanded
                DynamicIslandExpandedRegion(.center) {
                    if let maneuver = context.state.nextManeuver {
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
                    } else {
                        VStack {
                            Text("\(Int(context.state.speed))")
                                .font(.system(size: 60, weight: .black, design: .rounded))
                                .foregroundColor(colorForStatus(context.state.status))

                            // Dynamic-Island expanded center without a maneuver
                            // also gets the metric/imperial-aware limit + unit.
                            // NOTE: uses the `…DI` locals (scope is the
                            // `dynamicIsland:` closure, not the `content:`
                            // closure — see sibling-closure note above).
                            HStack(spacing: 20) {
                                Text("LIMIT: \(limitDisplayDI) \(unitShortDI)")
                                if context.state.isRecording {
                                    Text(formatTime(context.state.sessionDuration))
                                        .monospacedDigit()
                                }
                            }
                            .font(.caption.bold())
                            .foregroundColor(.gray)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ZStack {
                        Capsule()
                            .fill(colorForStatus(context.state.status).opacity(0.2))
                            .frame(height: 30)
                        
                        Text(context.state.status.uppercased())
                            .font(.caption.bold())
                            .foregroundColor(colorForStatus(context.state.status))
                    }
                    .padding(.horizontal)
                }
            } compactLeading: {
                if let img = context.state.nextManeuverImageName {
                    Image(systemName: img)
                        .foregroundColor(DesignSystem.cyan)
                } else {
                    Text("\(Int(context.state.speed))")
                        .font(.system(.headline, design: .rounded).bold())
                        .foregroundColor(colorForStatus(context.state.status))
                }
            } compactTrailing: {
                if context.state.nextManeuver != nil {
                    Text(formatDistance(context.state.distanceToNextTurn ?? 0))
                        .font(.caption.bold())
                        .foregroundColor(DesignSystem.cyan)
                } else {
                    Circle()
                        .fill(colorForStatus(context.state.status))
                        .frame(width: 8, height: 8)
                }
            } minimal: {
                if let img = context.state.nextManeuverImageName {
                    Image(systemName: img)
                        .foregroundColor(DesignSystem.cyan)
                } else {
                    Text("\(Int(context.state.speed))")
                        .font(.system(.caption, design: .rounded).bold())
                        .foregroundColor(colorForStatus(context.state.status))
                }
            }
        }
    }
    
    private func formatDistance(_ distance: CLLocationDistance) -> String {
        let miles = distance * 0.000621371
        if miles < 0.1 {
            let feet = distance * 3.28084
            return "\(Int(feet)) ft"
        }
        return String(format: "%.1f mi", miles)
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