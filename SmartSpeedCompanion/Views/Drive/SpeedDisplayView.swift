// Path: Views/Drive/SpeedDisplayView.swift
import SwiftUI

public struct SpeedDisplayView: View {
    @EnvironmentObject var viewModel: DriveViewModel
    @State private var flashOpacity: Double = 1.0
    
    public var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                // Status Badge
                Text(viewModel.status.rawValue.uppercased())
                    .font(.headline.bold())
                    .foregroundColor(DesignSystem.colorForStatus(viewModel.status))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(DesignSystem.colorForStatus(viewModel.status).opacity(0.15))
                    .overlay(
                        Capsule().stroke(DesignSystem.colorForStatus(viewModel.status), lineWidth: 1.5)
                    )
                    .clipShape(Capsule())
                    .opacity(viewModel.status == .over ? flashOpacity : 1.0)
                
                Spacer()
                
                // Speed Limit Chip
                HStack(spacing: 4) {
                    Text("LIMIT")
                        .font(DesignSystem.labelFont)
                        .foregroundColor(.gray)
                    Text("\(viewModel.limit)")
                        .font(.title3.bold())
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.2), lineWidth: 1))
                
                // Buffer Chip
                HStack(spacing: 4) {
                    Text("BUFFER")
                        .font(DesignSystem.labelFont)
                        .foregroundColor(.gray)
                    Text("+\(SpeedLimitBrain.shared.userBuffer)")
                        .font(.title3.bold())
                        .foregroundColor(DesignSystem.amber)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.2), lineWidth: 1))
            }
            
            // Consecutive Overspeed Alert Box
            if viewModel.status == .over {
                HStack(spacing: 12) {
                    Text("\(viewModel.alertEngine.consecutiveSeconds)")
                        .font(DesignSystem.displayFont)
                        .scaleEffect(0.5) // Hack to size Orbitron easily
                        .frame(width: 40)
                        .foregroundColor(DesignSystem.alertRed)
                        .shadow(color: DesignSystem.alertRed, radius: 5)
                    
                    VStack(alignment: .leading) {
                        Text("SECONDS OVER LIMIT")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                        if viewModel.alertEngine.audioAlertActive {
                            Text("⚠ AUDIO ALERT ACTIVE")
                                .font(.caption2.bold())
                                .foregroundColor(DesignSystem.amber)
                        }
                    }
                    Spacer()
                }
                .padding()
                .background(DesignSystem.alertRed.opacity(0.15))
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(DesignSystem.alertRed, lineWidth: 1.5))
            }
        }
        .animation(.easeInOut(duration: 0.4), value: viewModel.status)
        .onChange(of: viewModel.status) { _, newStatus in
            if newStatus == .over {
                withAnimation(.easeInOut(duration: 0.75).repeatForever()) {
                    flashOpacity = 0.25
                }
            } else {
                withAnimation { flashOpacity = 1.0 }
            }
        }
    }
}
