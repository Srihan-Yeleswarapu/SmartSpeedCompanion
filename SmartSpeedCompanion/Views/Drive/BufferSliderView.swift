// Path: Views/Drive/BufferSliderView.swift
import SwiftUI

public struct BufferSliderView: View {
    @EnvironmentObject var viewModel: DriveViewModel
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ALLOWANCE BUFFER")
                    .font(DesignSystem.labelFont)
                    .foregroundColor(.gray)
                
                Spacer()
                
                let formatter = MeasurementFormatter()
                formatter.unitOptions = .providedUnit
                formatter.numberFormatter.maximumFractionDigits = 0
                let measurement = Measurement(value: Double(viewModel.speedEngine.userBuffer), unit: UnitSpeed.milesPerHour)
                
                Text("+\(formatter.string(from: measurement))")
                    .font(.subheadline.bold())
                    .foregroundColor(DesignSystem.amber)
            }
            
            // Custom Track overlay using GeometryReader inside ZStack
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(DesignSystem.bgCard)
                        .frame(height: 12)
                    
                    let fillWidth = proxy.size.width * (CGFloat(viewModel.speedEngine.userBuffer) / 15.0)
                    
                    RoundedRectangle(cornerRadius: 6)
                        .fill(DesignSystem.amber)
                        .frame(width: fillWidth, height: 12)
                }
                // Interactive Slider overlays the visual track natively
                .overlay(
                    Slider(
                        value: Binding(
                            get: { Double(viewModel.speedEngine.userBuffer) },
                            set: { newValue in
                                if Int(newValue) != viewModel.speedEngine.userBuffer {
                                    let generator = UISelectionFeedbackGenerator()
                                    generator.selectionChanged()
                                }
                                viewModel.speedEngine.userBuffer = Int(newValue)
                            }
                        ),
                        in: 0...15,
                        step: 1
                    )
                    .accentColor(.clear) // Hides default track
                    .opacity(0.1) // Keep thumb interactive but invisible to let custom drawn layers show
                )
                
                // Custom drawn Thumb
                let thumbX = proxy.size.width * (CGFloat(viewModel.speedEngine.userBuffer) / 15.0)
                Circle()
                    .fill(DesignSystem.amber)
                    .frame(width: 18, height: 18)
                    .shadow(color: DesignSystem.amber.opacity(0.6), radius: 6)
                    .position(x: min(max(thumbX, 9), proxy.size.width - 9), y: proxy.size.height / 2)
                    // Thumb does NOT intercept taps; the invisible slider on top handles logic
                    .allowsHitTesting(false) 
            }
            .frame(height: 30) // Slider Hitbox
        }
        .padding()
        .background(DesignSystem.bgPanel)
        .cornerRadius(12)
    }
}
