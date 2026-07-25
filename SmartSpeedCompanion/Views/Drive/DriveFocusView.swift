import SwiftUI

/// Distraction-free full-screen view showing ONLY speed and speed limit.
/// No map, no buttons, no navigation bar. Activated from the Focus button
/// on the bottom HUD. Long-press anywhere to exit.
public struct DriveFocusView: View {
    @EnvironmentObject var driveViewModel: DriveViewModel

    @State private var showExitHint = false

    public init() {}

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 10) {
                Spacer()

                // Big speed number in the status color
                Text("\\(Int(driveViewModel.speed))")
                    .font(.system(size: 160, weight: .black, design: .rounded))
                    .foregroundColor(DesignSystem.colorForStatus(driveViewModel.status))
                    .contentTransition(.numericText())

                // Speed limit + unit on the same line
                HStack(spacing: 12) {
                    let measurementSystem = SpeedFormatting.measurementSystem()
                    let limitValue = SpeedFormatting.displayLimit(
                        forMph: driveViewModel.limit,
                        measurementSystem: measurementSystem
                    )
                    Text(limitValue == 0 ? "--" : "\\(limitValue)")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text(SpeedFormatting.unitLabelShort(measurementSystem: measurementSystem))
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                }

                // Recording indicator (reuses existing state)
                if driveViewModel.isRecording {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(DesignSystem.alertRed)
                            .frame(width: 8, height: 8)
                        Text("REC")
                            .font(.system(size: 14, weight: .black))
                            .foregroundColor(DesignSystem.alertRed)
                    }
                    .padding(.top, 8)
                }

                Spacer()

                // Exit hint — fades in after a short delay
                if showExitHint {
                    Text("Long-press anywhere to exit Focus Mode")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.3))
                        .padding(.bottom, 40)
                }
            }
        }
        .statusBarHidden()
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation(.easeInOut(duration: 0.5)) {
                    showExitHint = true
                }
            }
        }
        .onLongPressGesture(minimumDuration: 1.5) {
            driveViewModel.isDriveFocusMode = false
        }
        .animation(.easeInOut(duration: 0.3), value: driveViewModel.speed)
        .animation(.easeInOut(duration: 0.3), value: driveViewModel.status)
    }
}
