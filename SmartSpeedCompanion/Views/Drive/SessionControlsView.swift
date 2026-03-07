// Path: Views/Drive/SessionControlsView.swift
import SwiftUI

public struct SessionControlsView: View {
    @EnvironmentObject var viewModel: DriveViewModel
    @State private var pulseOpacity = 1.0
    
    public var body: some View {
        VStack(spacing: 12) {
            // Live Status Header while recording
            if viewModel.isRecording, let session = viewModel.sessionRecorder.currentSession {
                HStack {
                    Circle()
                        .fill(DesignSystem.neonGreen)
                        .frame(width: 8, height: 8)
                        .opacity(pulseOpacity)
                    
                    Text("RECORDING")
                        .font(DesignSystem.labelFont)
                        .foregroundColor(.gray)
                    
                    Spacer()
                    
                    TimelineView(.periodic(from: session.startTime, by: 1.0)) { context in
                        let elapsed = context.date.timeIntervalSince(session.startTime)
                        let timeString = formatTime(elapsed)
                        Text(timeString)
                            .font(.system(.body, design: .monospaced).bold())
                            .foregroundColor(.white)
                    }
                    
                    Text("\(session.readings.count) pts")
                        .font(.caption.bold())
                        .foregroundColor(DesignSystem.bgDeep)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(DesignSystem.neonGreen)
                        .cornerRadius(4)
                }
                .padding(.horizontal, 8)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        pulseOpacity = 0.2
                    }
                }
            }
            
            // Primary Action Button
            Button(action: {
                let generator = UIImpactFeedbackGenerator(style: .heavy)
                generator.impactOccurred()
                if viewModel.isRecording {
                    viewModel.endSession()
                } else {
                    viewModel.startSession()
                }
            }) {
                HStack {
                    Image(systemName: viewModel.isRecording ? "stop.fill" : "play.fill")
                    Text(viewModel.isRecording ? "END SESSION" : "START SESSION")
                        .font(DesignSystem.displayFont)
                        .scaleEffect(0.4) // Scaled Orbitron
                        .frame(height: 24)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(viewModel.isRecording ? DesignSystem.alertRed.opacity(0.15) : DesignSystem.neonGreen.opacity(0.15))
                .foregroundColor(viewModel.isRecording ? DesignSystem.alertRed : DesignSystem.neonGreen)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(viewModel.isRecording ? DesignSystem.alertRed : DesignSystem.neonGreen, lineWidth: 2))
                .cornerRadius(16)
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding()
        .background(DesignSystem.bgPanel)
        .cornerRadius(16)
    }
    
    private func formatTime(_ interval: TimeInterval) -> String {
        let i = Int(interval)
        let h = i / 3600
        let m = (i % 3600) / 60
        let s = i % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

// Interactive scale button style
struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
