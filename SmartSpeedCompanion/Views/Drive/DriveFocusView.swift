import SwiftUI

/// Distraction-free full-screen view showing ONLY speed and speed limit.
/// No map, no buttons, no navigation bar. Activated from the Focus button
/// on the bottom HUD. Long-press anywhere to exit.
///
/// Designed with beautiful micro-animations:
///   • Staggered spring entry — speed number bounces in, then limit fades up
///   • Ambient glow behind the speed number that pulses gently
///   • Very subtle breathing scale on the speed number
///   • Status-aware background gradient that shifts hue smoothly
///   • Glow rings that expand/contract with the pulse
///   • Smooth numeric transitions
///   • Landscape-aware layout that adapts fluidly
public struct DriveFocusView: View {
    @EnvironmentObject var driveViewModel: DriveViewModel

    // ── Entry animation progress ──────────────────────────────────
    @State private var speedEntryScale: CGFloat = 0.3
    @State private var speedEntryOpacity: Double = 0
    @State private var limitEntryOffset: CGFloat = 24
    @State private var limitEntryOpacity: Double = 0
    @State private var recEntryOpacity: Double = 0

    // ── Continuous animation states ───────────────────────────────
    @State private var glowPulse: CGFloat = 1.0
    @State private var breathingScale: CGFloat = 1.0
    @State private var glowRing1Scale: CGFloat = 1.0
    @State private var glowRing2Scale: CGFloat = 1.0

    // ── Exit animation ────────────────────────────────────────────
    @State private var isExiting = false

    // ── Exit hint ─────────────────────────────────────────────────
    @State private var showExitHint = false

    public init() {}

    private var statusColor: Color {
        DesignSystem.colorForStatus(driveViewModel.status)
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                // Status-aware ambient background
                ambientBackground

                // Content — layout adapts to orientation
                if geo.size.width > geo.size.height {
                    landscapeContent(geo: geo)
                } else {
                    portraitContent(geo: geo)
                }
            }
            .statusBarHidden()
            .opacity(isExiting ? 0 : 1)
            .scaleEffect(isExiting ? 0.85 : 1.0, anchor: .center)
        }
        .onAppear(perform: animateEntry)
        .task {
            // Let entry animation finish before starting continuous breath loops
            try? await Task.sleep(nanoseconds: 600_000_000) // 0.6s
            startBreathingAnimations()
        }
        .onLongPressGesture(minimumDuration: 1.5, perform: exitFocusMode)
    }

    // MARK: - Ambient Background

    private var ambientBackground: some View {
        ZStack {
            Color.black

            // Subtle radial glow that shifts hue with the speed status.
            // The glow is very faint — just enough to tint the void.
            RadialGradient(
                gradient: Gradient(colors: [
                    statusColor.opacity(0.10 * glowPulse),
                    statusColor.opacity(0.03 * glowPulse),
                    .clear
                ]),
                center: .center,
                startRadius: 0,
                endRadius: 380
            )
        }
        .animation(.easeInOut(duration: 0.8), value: statusColor)
    }

    // MARK: - Portrait Layout

    private func portraitContent(geo: GeometryProxy) -> some View {
        VStack(spacing: 8) {
            Spacer()

            // Speed number with concentric glow rings
            speedSection(geo: geo)

            // Speed limit + unit
            limitSection(geo: geo)
                .opacity(limitEntryOpacity)
                .offset(y: limitEntryOffset)

            // Recording indicator
            if driveViewModel.isRecording {
                recordingIndicator
                    .opacity(recEntryOpacity)
                    .padding(.top, 6)
            }

            Spacer()

            // Exit hint
            if showExitHint {
                exitHintLabel
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Landscape Layout

    private func landscapeContent(geo: GeometryProxy) -> some View {
        HStack(spacing: 20) {
            Spacer(minLength: 0)

            // Speed number — takes ~40% of the width
            speedSection(geo: geo)
                .frame(maxWidth: geo.size.width * 0.4)

            // Right column: limit + optional rec indicator
            VStack(alignment: .leading, spacing: 14) {
                Spacer()

                limitSection(geo: geo)
                    .opacity(limitEntryOpacity)
                    .offset(x: limitEntryOffset)

                if driveViewModel.isRecording {
                    recordingIndicator
                        .opacity(recEntryOpacity)
                }

                Spacer()
            }
            .frame(maxWidth: geo.size.width * 0.35)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .overlay(alignment: .bottom) {
            if showExitHint {
                exitHintLabel
                    .padding(.bottom, 24)
            }
        }
    }

    // MARK: - Speed Section

    private func speedSection(geo: GeometryProxy) -> some View {
        ZStack {
            // Outer glow ring — soft, wide stretch
            Circle()
                .stroke(statusColor.opacity(0.10 * glowPulse), lineWidth: 3)
                .frame(
                    width: ringSize(geo: geo, multiplier: 0.72),
                    height: ringSize(geo: geo, multiplier: 0.72)
                )
                .scaleEffect(glowRing1Scale)

            // Inner glow ring — tighter, slightly brighter
            Circle()
                .stroke(statusColor.opacity(0.18 * glowPulse), lineWidth: 1.5)
                .frame(
                    width: ringSize(geo: geo, multiplier: 0.58),
                    height: ringSize(geo: geo, multiplier: 0.58)
                )
                .scaleEffect(glowRing2Scale)

            // Speed number
            Text("\(Int(driveViewModel.speed))")
                .font(.system(
                    size: adaptiveSpeedSize(geo: geo),
                    weight: .black,
                    design: .rounded
                ))
                .foregroundColor(statusColor)
                .contentTransition(.numericText())
                .scaleEffect(breathingScale)
                .opacity(speedEntryOpacity)
                .scaleEffect(speedEntryScale)
                .shadow(
                    color: statusColor.opacity(0.25 * glowPulse),
                    radius: 30,
                    y: 0
                )
        }
    }

    // MARK: - Limit Section

    private func limitSection(geo: GeometryProxy) -> some View {
        HStack(spacing: 10) {
            let measurementSystem = SpeedFormatting.measurementSystem()
            let limitValue = SpeedFormatting.displayLimit(
                forMph: driveViewModel.limit,
                measurementSystem: measurementSystem
            )
            Text(limitValue == 0 ? "--" : "\(limitValue)")
                .font(.system(
                    size: geo.size.width > geo.size.height ? 52 : 46,
                    weight: .bold,
                    design: .rounded
                ))
                .foregroundColor(.white)
                .contentTransition(.numericText())

            Text(SpeedFormatting.unitLabelShort(measurementSystem: measurementSystem))
                .font(.system(
                    size: geo.size.width > geo.size.height ? 26 : 22,
                    weight: .bold
                ))
                .foregroundColor(.white.opacity(0.35))
        }
    }

    // MARK: - Recording Indicator

    private var recordingIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(DesignSystem.alertRed)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(DesignSystem.alertRed.opacity(0.4), lineWidth: 2)
                        .scaleEffect(1.4)
                )
            Text("REC")
                .font(.system(size: 14, weight: .black))
                .foregroundColor(DesignSystem.alertRed)
        }
    }

    // MARK: - Exit Hint

    private var exitHintLabel: some View {
        Text("Long-press anywhere to exit Focus Mode")
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white.opacity(0.3))
            .padding(.bottom, 40)
            .transition(.opacity)
    }

    // MARK: - Adaptive Sizing

    private func ringSize(geo: GeometryProxy, multiplier: CGFloat) -> CGFloat {
        let base = min(geo.size.width, geo.size.height)
        return base * multiplier
    }

    private func adaptiveSpeedSize(geo: GeometryProxy) -> CGFloat {
        if geo.size.width > geo.size.height {
            // Landscape: width-based, slightly smaller
            return min(geo.size.width * 0.28, 130)
        } else {
            // Portrait: height-based
            return min(geo.size.height * 0.24, 158)
        }
    }

    // MARK: - Animations

    private func animateEntry() {
        // Phase 1: Speed number springs in (0.0s)
        withAnimation(.spring(
            response: 0.55,
            dampingFraction: 0.65,
            blendDuration: 0.4
        )) {
            speedEntryScale = 1.0
            speedEntryOpacity = 1.0
        }

        // Phase 2: Limit fades + slides up (0.2s delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.easeOut(duration: 0.35)) {
                limitEntryOffset = 0
                limitEntryOpacity = 1.0
            }
        }

        // Phase 3: Recording indicator (0.35s delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(.easeOut(duration: 0.3)) {
                recEntryOpacity = 1.0
            }
        }

        // Phase 4: Exit hint after a few seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation(.easeInOut(duration: 0.5)) {
                showExitHint = true
            }
        }
    }

    private func startBreathingAnimations() {
        // Outer glow ring pulse — slow, gentle
        withAnimation(
            .easeInOut(duration: 2.4).repeatForever(autoreverses: true)
        ) {
            glowRing1Scale = 1.04
        }

        // Inner glow ring pulse — counter-phase for depth
        withAnimation(
            .easeInOut(duration: 2.4).repeatForever(autoreverses: true)
        ) {
            glowRing2Scale = 0.97
        }

        // Overall glow intensity
        withAnimation(
            .easeInOut(duration: 1.8).repeatForever(autoreverses: true)
        ) {
            glowPulse = 0.65
        }

        // Speed number breathing — very subtle (1.5% scale change)
        withAnimation(
            .easeInOut(duration: 3.2).repeatForever(autoreverses: true)
        ) {
            breathingScale = 1.015
        }
    }

    private func exitFocusMode() {
        // Smooth exit animation before dismissing
        // Duration tuned so the spring settles before the fullScreenCover dismisses
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            isExiting = true
        }

        // Wait for the spring animation to settle before triggering dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            driveViewModel.isDriveFocusMode = false
        }
    }
}
