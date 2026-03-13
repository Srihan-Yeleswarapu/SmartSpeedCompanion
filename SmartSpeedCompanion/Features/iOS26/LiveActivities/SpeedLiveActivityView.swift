// Path: Features/iOS26/LiveActivities/SpeedLiveActivityView.swift
import SwiftUI
import WidgetKit
import ActivityKit

@available(iOS 16.1, *)
struct SpeedLiveActivityView: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SpeedActivityAttributes.self) { context in
            // Lock Screen / StandBy
            HStack {
                VStack(alignment: .leading) {
                    Text("\(Int(context.state.speed))")
                        .font(.system(size: 40, weight: .black, design: .rounded))
                        .foregroundColor(colorForStatus(context.state.status))
                    
                    Text("LIMIT \(context.state.speedLimit) MPH")
                        .font(.caption.bold())
                        .foregroundColor(.gray)
                }
                Spacer()
                
                if context.state.isRecording {
                    VStack(alignment: .trailing) {
                        Text("REC")
                            .font(.caption.bold())
                            .foregroundColor(.red)
                        Text(formatTime(context.state.sessionDuration))
                            .font(.system(.body, design: .monospaced))
                    }
                } else if let maneuver = context.state.nextManeuver {
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 4) {
                            if let img = context.state.nextManeuverImageName {
                                Image(systemName: img)
                                    .foregroundColor(DesignSystem.cyan)
                            }
                            Text(formatDistance(context.state.distanceToNextTurn ?? 0))
                                .font(.headline.bold())
                        }
                        Text(maneuver)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding()
            // Add a bottom color bar to represent status instantly
            .background(
                VStack {
                    Spacer()
                    Rectangle()
                        .fill(colorForStatus(context.state.status))
                        .frame(height: 4)
                }
            )
            .widgetBackground(DesignSystem.bgCard.opacity(0.8))
            
        } dynamicIsland: { context in
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
                            
                            HStack(spacing: 20) {
                                Text("LIMIT: \(context.state.speedLimit)")
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
