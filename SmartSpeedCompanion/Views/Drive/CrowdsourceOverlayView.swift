// CrowdsourceOverlayView.swift
// Floating overlay asking user to report the speed limit on their current road.
// Appears 10 seconds after entering an unknown road segment.
// Semi-transparent so the driver can still see the map underneath.

import SwiftUI

public struct CrowdsourceOverlayView: View {
    @EnvironmentObject var vm: DriveViewModel
    
    // Define `service` as a computed property referencing the DriveViewModel
    private var service: DriveViewModel {
        return vm
    }
    
    @State private var showingSuggestSlider = false
    @State private var suggestedSpeed: Double = 35
    
    // Auto-dismiss logic
    @State private var timeRemaining = 30
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public init() {}
    
    public var body: some View {
        VStack(spacing: 20) {
            
            // Header
            VStack(spacing: 4) {
                if service.isReconfirmation {
                    Text("🔄 Still \(service.existingLimitForReconfirm) mph here?")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                    Text("Last confirmed 30+ days ago")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "#8888AA"))
                } else {
                    Text("🚦 What's the speed limit here?")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                    Text("Help other drivers on this road")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "#8888AA"))
                }
            }
            .multilineTextAlignment(.center)
            
            // Speed Option Buttons or Slider
            if showingSuggestSlider {
                suggestSliderView
            } else {
                if service.isReconfirmation {
                    reconfirmationButtons
                } else {
                    speedOptionsRow
                }
            }
            
            // Always present controls below options
            VStack(spacing: 12) {
                if !showingSuggestSlider && !service.isReconfirmation {
                    Button(action: {
                        withAnimation { showingSuggestSlider = true }
                    }) {
                        Label("Suggest a different speed", systemImage: "plus.circle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color(hex: "#00D4FF"))
                    }
                }
                
                Button(action: {
                    service.submitIgnore()
                }) {
                    Text("Ignore — focus on road (\(timeRemaining)s)")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "#8888AA"))
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 340)
        .background(
            Color(hex: "#0F1022").opacity(0.93)
                .background(Material.ultraThinMaterial)
        )
        .cornerRadius(20)
        .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 10)
        .offset(y: -60) // Positioned slightly above center
        .onReceive(timer) { _ in
            if timeRemaining > 0 {
                timeRemaining -= 1
            } else {
                service.submitIgnore()
            }
        }
    }
    
    // MARK: - Subviews
    
    private var speedOptionsRow: some View {
        HStack(spacing: 10) {
            ForEach(service.promptOptions, id: \.self) { speed in
                SpeedOptionButton(speed: speed) {
                    withAnimation { service.submitVote(speed: speed) }
                }
            }
        }
    }
    
    private var reconfirmationButtons: some View {
        HStack(spacing: 16) {
            Button(action: {
                withAnimation { service.submitVote(speed: service.existingLimitForReconfirm) }
            }) {
                VStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 24, weight: .bold))
                    Text("Yes, still \(service.existingLimitForReconfirm) mph")
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.green)
                .cornerRadius(12)
            }
            
            Button(action: {
                withAnimation { 
                    service.isReconfirmation = false
                    showingSuggestSlider = true 
                }
            }) {
                VStack(spacing: 4) {
                    Image(systemName: "xmark")
                        .font(.system(size: 24, weight: .bold))
                    Text("No, it changed")
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color(hex: "#1A1B2E"))
                .cornerRadius(12)
            }
        }
    }
    
    private var suggestSliderView: some View {
        VStack(spacing: 20) {
            Text("\(Int(suggestedSpeed))")
                .font(.system(size: 48, weight: .black, design: .rounded))
                .foregroundColor(.white)
            
            Slider(value: $suggestedSpeed, in: 5...85, step: 5)
                .tint(Color(hex: "#00D4FF"))
            
            HStack {
                Button(action: {
                    withAnimation { showingSuggestSlider = false }
                }) {
                    Text("Back")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color(hex: "#8888AA"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(hex: "#1A1B2E"))
                        .cornerRadius(10)
                }
                
                Button(action: {
                    withAnimation { service.submitCustomSpeed(speed: Int(suggestedSpeed)) }
                }) {
                    Text("Submit")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(hex: "#00D4FF"))
                        .cornerRadius(10)
                }
            }
        }
    }
}

fileprivate struct SpeedOptionButton: View {
    let speed: Int
    let action: () -> Void
    
    @State private var isPressed = false
    
    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.2)) {
                isPressed = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation { isPressed = false }
                action()
            }
        }) {
            VStack(spacing: 2) {
                Text("\(speed)")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                Text("mph")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#8888AA"))
            }
            .frame(width: 72, height: 52)
            .background(isPressed ? Color(hex: "#00D4FF") : Color(hex: "#1A1B2E"))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(hex: "#00D4FF"), lineWidth: 1.5)
            )
            .cornerRadius(12)
            .scaleEffect(isPressed ? 0.92 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
    }
}