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
            Text("SPEED VS. TIME")
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
                        let elapsedMinutes = point.timestamp.timeIntervalSince(session.startTime) / 60.0
                        AreaMark(
                            x: .value("Time", elapsedMinutes),
                            yStart: .value("Base", 0),
                            yEnd: .value("Speed", point.speed)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [DesignSystem.cyan.opacity(0.18), .clear],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.linear)
                    }
                    
                    // Speed Line
                    ForEach(downsampled, id: \.timestamp) { point in
                        let elapsedMinutes = point.timestamp.timeIntervalSince(session.startTime) / 60.0
                        LineMark(
                            x: .value("Time", elapsedMinutes),
                            y: .value("Speed", point.speed)
                        )
                        .foregroundStyle(DesignSystem.cyan)
                        .interpolationMethod(.linear)
                    }
                    
                    // Limit Line
                    ForEach(downsampled, id: \.timestamp) { point in
                        let elapsedMinutes = point.timestamp.timeIntervalSince(session.startTime) / 60.0
                        LineMark(
                            x: .value("Time", elapsedMinutes),
                            y: .value("Limit", Double(point.speedLimit))
                        )
                        .foregroundStyle(DesignSystem.amber)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, dash: [6, 4]))
                        .interpolationMethod(.linear)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 8)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2]))
                            .foregroundStyle(.white.opacity(0.1))
                        AxisValueLabel() {
                            if let minutes = value.as(Double.self) {
                                if minutes < 1.0 {
                                    let seconds = Int(minutes * 60)
                                    Text("\(seconds)s")
                                } else {
                                    Text(String(format: "%.1fm", minutes))
                                }
                            }
                        }
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
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
