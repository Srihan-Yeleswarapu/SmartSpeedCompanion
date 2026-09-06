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
    /// Maps a drag location across the track to a stepped buffer value.
    /// Pure so the mapping is unit-testable; returns nil when the geometry
    /// isn't usable (zero-width track / NaN location).
    static func buffer(fromDragAtX x: CGFloat, trackWidth: CGFloat, step: Double) -> Double? {
        guard x.isFinite, trackWidth.isFinite, trackWidth > 0 else { return nil }
        let clampedX = max(0, min(trackWidth, x))
        let raw = -5.0 + (clampedX / trackWidth) * 15.0
        let stepped = (raw / step).rounded() * step
        return max(-5, min(10, stepped))
    }

    /// Live width of the track, measured from the ZStack itself (varies by
    /// device and container inset — a hard-coded width would mis-map drags).
    @State private var measuredTrackWidth: CGFloat = 0

    var body: some View {
        // TestFlight 2.1.4 feedback: the buffer chip value previously
        // hard-coded "+X mph". The underlying `@AppStorage("userBuffer")`
        // value is the raw mph (SpeedEngine thresholds are mph-stable),
        // so we convert on render to honor Settings → UNITS.
        let measurementSystem = SpeedFormatting.measurementSystem()
        let displayBuffer = Int(SpeedFormatting.displayBuffer(
            forMph: buffer,
            measurementSystem: measurementSystem))
        let bufferUnit = SpeedFormatting.unitLabelLong(measurementSystem: measurementSystem)

        VStack(spacing: 8) {
            HStack {
                Text("ALERT BUFFER")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.gray)
                Spacer()
                let displaySign = displayBuffer > 0 ? "+" : ""
                Text("\(displaySign)\(displayBuffer) \(bufferUnit)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(hex: "#FFB800"))
            }      

            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 4)

                // Filled portion — maps the −5…10 track exactly like the
                // invisible system Slider does: fraction = (value − min) /
                // (max − min). The previous `buffer / 10.0` ignored the −5
                // minimum, so the amber fill and the thumb disagreed (FB
                // 2.3.0 b640: fill showed +3's position while the thumb sat
                // where +3 actually maps on the wider track).
                GeometryReader { geo in
                    let fraction = (buffer + 5.0) / 15.0
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: "#FFB800"))
                        .frame(width: geo.size.width * CGFloat(max(0, min(1, fraction))), height: 4)
                }
                .frame(height: 4)

                // Value thumb — drawn by the app so its position is the
                // single source of truth. Previously input came from a
                // near-invisible system `Slider` (opacity 0.015), but iOS 26
                // still renders its liquid-glass thumb — a large pill whose
                // centered position read as "+5" regardless of the actual
                // value (the same FB report).
                GeometryReader { geo in
                    let fraction = CGFloat(max(0, min(1, (buffer + 5.0) / 15.0)))
                    Circle()
                        .fill(Color(hex: "#FFB800"))
                        .frame(width: 14, height: 14)
                        .shadow(color: Color(hex: "#FFB800").opacity(0.55), radius: 5)
                        // Center spans x ∈ [7, width−7] so the thumb's edge
                        // (not its center) lines up with the track ends.
                        .position(x: 7 + fraction * (geo.size.width - 14),
                                  y: geo.size.height / 2)
                }
                .frame(height: 20)
                .allowsHitTesting(false)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: TrackWidthKey.self, value: geo.size.width)
                }
            )
            .onPreferenceChange(TrackWidthKey.self) { measuredTrackWidth = $0 }
            // Drag handling on the visible track itself (replaces the hidden
            // system slider). Snaps to the 1-unit step like the slider did.
            // minimumDistance > 0 keeps vertical Form scrolling working when
            // the touch starts on the row; a spatial tap still jumps to the
            // touched value (tap-to-set, like the old slider supported).
            .onTapGesture(coordinateSpace: .local) { location in
                guard let newBuffer = Self.buffer(fromDragAtX: location.x,
                                                  trackWidth: measuredTrackWidth,
                                                  step: 1) else { return }
                if newBuffer != buffer { buffer = newBuffer }
            }
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        guard let newBuffer = Self.buffer(fromDragAtX: value.location.x,
                                                          trackWidth: measuredTrackWidth,
                                                          step: 1) else { return }
                        if newBuffer != buffer { buffer = newBuffer }
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Alert buffer")
            .accessibilityValue("\(Int(buffer)) mph")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: buffer = min(10, buffer + 1)
                case .decrement: buffer = max(-5, buffer - 1)
                @unknown default: break
                }
            }

            HStack {
                Text("-5")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray)
                Spacer()
                Text("10")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray)
            }
        }
    }
}

/// Reports the slider track's rendered width up to BufferSliderView.
private struct TrackWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}