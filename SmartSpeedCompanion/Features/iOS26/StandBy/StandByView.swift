// iOS 26+ StandBy Mode (Enhanced)
import SwiftUI

public struct StandByView: View {
    @EnvironmentObject var viewModel: DriveViewModel
    
    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack {
                Text("\(Int(viewModel.speed))")
                    .font(.system(size: 150, weight: .black, design: .rounded))
                    .foregroundColor(DesignSystem.colorForStatus(viewModel.status))
                    .shadow(color: DesignSystem.colorForStatus(viewModel.status).opacity(0.8), radius: 20)
                
                HStack(spacing: 40) {
                    VStack {
                        Text("LIMIT").font(.caption).foregroundColor(.gray)
                        Text("\(viewModel.limit)").font(.title.bold()).foregroundColor(.white)
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
