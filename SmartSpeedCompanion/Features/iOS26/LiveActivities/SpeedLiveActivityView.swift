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
                Text("\(Int(context.state.speed))")
                    .font(.system(.headline, design: .rounded).bold())
                    .foregroundColor(colorForStatus(context.state.status))
            } compactTrailing: {
                Circle()
                    .fill(colorForStatus(context.state.status))
                    .frame(width: 8, height: 8)
            } minimal: {
                Text("\(Int(context.state.speed))")
                    .font(.system(.caption, design: .rounded).bold())
                    .foregroundColor(colorForStatus(context.state.status))
            }
        }
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
