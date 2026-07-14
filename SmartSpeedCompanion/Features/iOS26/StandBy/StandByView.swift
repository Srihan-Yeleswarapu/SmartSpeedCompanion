// iOS 26+ StandBy Mode (Enhanced)
import SwiftUI

public struct StandByView: View {
    @EnvironmentObject var viewModel: DriveViewModel

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack {
                // Speed readout — `viewModel.speed` is already in the active
                // display unit (SpeedEngine converts mph→km/h before
                // publishing), so we only swap the trailing label here.
                Text("\(Int(viewModel.speed))")
                    .font(.system(size: 150, weight: .black, design: .rounded))
                    .foregroundColor(DesignSystem.colorForStatus(viewModel.status))
                    .shadow(color: DesignSystem.colorForStatus(viewModel.status).opacity(0.8), radius: 20)
                    .overlay(alignment: .bottom) {
                        // Short unit label under the speed for context.
                        Text(SpeedFormatting.unitLabelShort(
                                measurementSystem: SpeedFormatting.measurementSystem()))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundColor(.gray)
                            .offset(y: 28)
                    }

                HStack(spacing: 40) {
                    VStack(spacing: 4) {
                        Text("LIMIT").font(.caption).foregroundColor(.gray)
                        // LIMIT value honors Settings → UNITS (TestFlight 2.1.4
                        // "When I put metric, why does speed limit show MPH
                        // still? Make sure when in metric it shows metric.").
                        let limitDisplay = SpeedFormatting.limitDisplay(
                            forMph: viewModel.limit,
                            measurementSystem: SpeedFormatting.measurementSystem()
                        )
                        Text("\(limitDisplay.value) \(limitDisplay.unit)")
                            .font(.title.bold())
                            .foregroundColor(.white)
                    }

                    Button {
                        viewModel.isRecording ? viewModel.endSession() : viewModel.startSession()
                    } label: {
                        Image(systemName: viewModel.isRecording ? "stop.circle.fill" : "play.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(viewModel.isRecording ? DesignSystem.alertRed : DesignSystem.neonGreen)
                    }
                }
            }
        }
    }
}