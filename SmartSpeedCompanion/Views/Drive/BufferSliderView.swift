// BufferSliderView.swift
// Custom slider for adjusting the speed alert buffer threshold.

import SwiftUI

struct BufferSliderView: View {

    @Binding var buffer: Double

    // Formatter defined as property — NOT inside body
    private let formatter: MeasurementFormatter = {
        let f = MeasurementFormatter()
        f.unitOptions = .providedUnit
        f.numberFormatter.maximumFractionDigits = 0
        return f
    }()

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("ALERT BUFFER")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.gray)
                Spacer()
                Text("+\(Int(buffer)) mph")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(hex: "#FFB800"))
            }

            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 4)

                // Filled portion
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: "#FFB800"))
                        .frame(width: geo.size.width * CGFloat(buffer / 15.0), height: 4)
                }
                .frame(height: 4)

                // Invisible system slider for input
                Slider(value: $buffer, in: 0...15, step: 1)
                    .opacity(0.015)
            }
            .frame(height: 20)

            HStack {
                Text("0")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray)
                Spacer()
                Text("15")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray)
            }
        }
    }
}
