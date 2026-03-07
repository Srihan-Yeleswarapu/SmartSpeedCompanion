// Path: Views/Analytics/SpeedChartView.swift
import SwiftUI
import Charts

public struct SpeedChartView: View {
    let session: DriveSession
    
    // Downsample large sessions to ~120 points for Charts performance
    private var downsampled: [SpeedReading] {
        let count = session.readings.count
        guard count > 120 else { return session.readings }
        let step = count / 120
        return stride(from: 0, to: count, by: step).map { session.readings[$0] }
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SPEED VS. LIMIT")
                .font(.headline)
                .foregroundColor(.white)
            
            if session.readings.isEmpty {
                Spacer()
                CenterPlaceholder(text: "No GPS data for this session.")
                Spacer()
            } else {
                Chart {
                    // Speed Area Gradient
                    ForEach(downsampled, id: \.timestamp) { point in
                        AreaMark(
                            x: .value("Time", point.timestamp),
                            yStart: .value("Base", 0),
                            yEnd: .value("Speed", point.speed)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [DesignSystem.cyan.opacity(0.18), .clear],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    }
                    
                    // Speed Line
                    ForEach(downsampled, id: \.timestamp) { point in
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Speed", point.speed)
                        )
                        .foregroundStyle(DesignSystem.cyan)
                        .interpolationMethod(.catmullRom)
                    }
                    
                    // Limit Line
                    ForEach(downsampled, id: \.timestamp) { point in
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Limit", Double(point.speedLimit))
                        )
                        .foregroundStyle(DesignSystem.amber)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [4]))
                            .foregroundStyle(.gray.opacity(0.2))
                        AxisValueLabel(format: .dateTime.minute().second())
                            .font(DesignSystem.labelFont)
                            .foregroundStyle(.gray)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [4]))
                            .foregroundStyle(.gray.opacity(0.2))
                        AxisValueLabel()
                            .font(DesignSystem.labelFont)
                            .foregroundStyle(Color(white: 0.4))
                    }
                }
                .chartBackground { chartProxy in
                    DesignSystem.bgDeep.opacity(0.5)
                }
                .frame(height: 230)
            }
        }
        .padding()
        .background(DesignSystem.bgPanel)
        .cornerRadius(16)
    }
}

fileprivate struct CenterPlaceholder: View {
    let text: String
    var body: some View {
        HStack {
            Spacer()
            Text(text).foregroundColor(.gray)
            Spacer()
        }
    }
}
