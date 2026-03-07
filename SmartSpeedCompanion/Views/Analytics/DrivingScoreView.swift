// Path: Views/Analytics/DrivingScoreView.swift
import SwiftUI

public struct DrivingScoreView: View {
    let score: Int
    @State private var animatedScore: Double = 0
    
    var ringColor: Color {
        if score >= 80 { return DesignSystem.neonGreen }
        if score >= 60 { return DesignSystem.amber }
        return DesignSystem.alertRed
    }
    
    var label: String {
        if score >= 80 { return "EXCELLENT" }
        if score >= 60 { return "FAIR" }
        return "NEEDS WORK"
    }
    
    public var body: some View {
        VStack {
            Text("DRIVING SCORE")
                .font(.headline)
                .foregroundColor(.white)
            
            ZStack {
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let radius: CGFloat = 44
                    
                    // Track
                    var trackPath = Path()
                    trackPath.addArc(center: center, radius: radius, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
                    context.stroke(trackPath, with: .color(DesignSystem.bgCard), style: StrokeStyle(lineWidth: 16))
                    
                    // Fill arc
                    let fillAngle = Angle(degrees: (animatedScore / 100.0) * 360.0)
                    var fillPath = Path()
                    fillPath.addArc(center: center, radius: radius, startAngle: .degrees(-90), endAngle: .degrees(-90 + fillAngle.degrees), clockwise: false)
                    
                    context.stroke(fillPath, with: .color(ringColor), style: StrokeStyle(lineWidth: 16, lineCap: .round))
                }
                .shadow(color: ringColor.opacity(0.6), radius: 8)
                
                VStack(spacing: -2) {
                    Text("\(Int(animatedScore))")
                        .font(DesignSystem.displayFont)
                        .scaleEffect(0.5)
                        .frame(height: 30) // Scaled Orbitron
                        .foregroundColor(.white)
                    
                    Text(label)
                        .font(.caption2.bold())
                        .foregroundColor(ringColor)
                }
            }
        }
        .padding()
        .background(DesignSystem.bgPanel)
        .cornerRadius(16)
        .onAppear {
            withAnimation(.spring(response: 1.0, dampingFraction: 0.8)) {
                // Initial trigger
                animatedScore = Double(score)
            }
        }
        .onChange(of: score) { _, newScore in
            withAnimation(.spring(response: 1.0, dampingFraction: 0.8)) {
                animatedScore = Double(newScore)
            }
        }
    }
}
