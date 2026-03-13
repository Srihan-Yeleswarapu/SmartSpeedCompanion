// Path: Views/Drive/SpeedGaugeView.swift
import SwiftUI

public struct SpeedGaugeView: View {
    @EnvironmentObject var viewModel: DriveViewModel
    @State private var pulseScale: CGFloat = 1.0
    
    public var body: some View {
        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: 120, y: 130)
                let radius: CGFloat = 104
                let strokeWidth: CGFloat = 14
                
                // Track Layer
                var trackPath = Path()
                trackPath.addArc(center: center, radius: radius, startAngle: .degrees(135), endAngle: .degrees(45), clockwise: false)
                context.stroke(trackPath, with: .color(Color(red: 1, green: 1, blue: 1, opacity: 0.05)), style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                
                // Speed Arc
                let maxSpeed: Double = 120.0
                let speedRatio = min(max(viewModel.speed / maxSpeed, 0), 1)
                
                var speedPath = Path()
                speedPath.addArc(center: center, radius: radius, startAngle: .degrees(135), endAngle: .degrees(135 + (speedRatio * 270)), clockwise: false)
                
                let activeColor = DesignSystem.colorForStatus(viewModel.status)
                
                // Base arc
                context.stroke(speedPath, with: .color(activeColor), style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                // Glow arc
                context.stroke(speedPath, with: .color(activeColor.opacity(0.4)), style: StrokeStyle(lineWidth: strokeWidth * 2, lineCap: .round))
                
                // Limit Tick Mark
                let limitRatio = Double(viewModel.limit + viewModel.speedEngine.userBuffer) / maxSpeed
                let tickAngle = Angle(degrees: 135.0 + (limitRatio * 270.0))
                
                var tickPath = Path()
                let innerRadius = radius - (strokeWidth / 2)
                let outerRadius = radius + (strokeWidth / 2)
                
                tickPath.move(to: CGPoint(
                    x: center.x + innerRadius * cos(CGFloat(tickAngle.radians)),
                    y: center.y + innerRadius * sin(CGFloat(tickAngle.radians))
                ))
                tickPath.addLine(to: CGPoint(
                    x: center.x + outerRadius * cos(CGFloat(tickAngle.radians)),
                    y: center.y + outerRadius * sin(CGFloat(tickAngle.radians))
                ))
                context.stroke(tickPath, with: .color(DesignSystem.amber), style: StrokeStyle(lineWidth: 3, lineCap: .square))
                
                // Needle
                let needleAngle = Angle(degrees: 135.0 + (speedRatio * 270.0))
                var needlePath = Path()
                needlePath.move(to: center)
                needlePath.addLine(to: CGPoint(
                    x: center.x + 88 * cos(CGFloat(needleAngle.radians)),
                    y: center.y + 88 * sin(CGFloat(needleAngle.radians))
                ))
                context.stroke(needlePath, with: .color(.white), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                
                // Center Hub
                var hubPath = Path()
                hubPath.addArc(center: center, radius: 7, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                context.fill(hubPath, with: .color(activeColor))
            }
            .animation(.interactiveSpring(response: 0.4, dampingFraction: 0.7), value: viewModel.speed)
            .animation(.easeInOut(duration: 0.4), value: viewModel.status)
            .frame(width: 240, height: 200)
            
            // Pulsing Ring for Over Status
            if viewModel.status == .over {
                Circle()
                    .stroke(DesignSystem.alertRed, lineWidth: 4)
                    .frame(width: 208, height: 208)
                    .scaleEffect(pulseScale)
                    .opacity(2.0 - pulseScale) // Fades out as it expands
                    .offset(y: 30) // Match the gauge center offset (130-100)
            }
            
            // Center Readout
            VStack(spacing: -5) {
                Text("\(Int(viewModel.speed))")
                    .font(DesignSystem.displayFont)
                    .foregroundColor(.white)
                Text("MPH")
                    .font(DesignSystem.labelFont)
                    .foregroundColor(.gray)
            }
            .offset(y: 30)
        }
        .onChange(of: viewModel.status) { ov, nv in
            if nv == .over {
                withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                    pulseScale = 1.3
                }
            } else {
                withAnimation { pulseScale = 1.0 }
            }
        }
    }
}
