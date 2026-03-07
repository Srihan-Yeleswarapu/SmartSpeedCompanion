// Path: Views/Drive/DriveRootView.swift
import SwiftUI

public struct DriveRootView: View {
    @Environment(\.horizontalSizeClass) var sizeClass
    @EnvironmentObject var viewModel: DriveViewModel
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "#040510").ignoresSafeArea()
                
                // Grid Background Overlay
                Canvas { context, size in
                    let gridColor = Color(red: 0, green: 212/255, blue: 255/255, opacity: 0.025)
                    let step: CGFloat = 48
                    
                    for x in stride(from: 0, through: size.width, by: step) {
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(path, with: .color(gridColor), lineWidth: 1)
                    }
                    
                    for y in stride(from: 0, through: size.height, by: step) {
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                        context.stroke(path, with: .color(gridColor), lineWidth: 1)
                    }
                }
                .ignoresSafeArea()
                
                if sizeClass == .regular {
                    // iPad HStack Layout
                    HStack(spacing: 20) {
                        VStack(spacing: 20) {
                            SpeedGaugeView()
                                .frame(height: 300)
                            SpeedDisplayView()
                            BufferSliderView()
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        
                        VStack(spacing: 20) {
                            LiveMapView()
                                .cornerRadius(16)
                            SessionControlsView()
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding()
                } else {
                    // iPhone VStack Layout
                    VStack(spacing: 16) {
                        SpeedGaugeView()
                            .frame(height: 240)
                            .padding(.top, 20)
                        
                        SpeedDisplayView()
                            .padding(.horizontal)
                        
                        BufferSliderView()
                            .padding(.horizontal)
                        
                        LiveMapView()
                            .cornerRadius(16)
                            .padding(.horizontal)
                        
                        SessionControlsView()
                            .padding(.horizontal)
                            .padding(.bottom, 20)
                    }
                }
            }
        }
    }
}
