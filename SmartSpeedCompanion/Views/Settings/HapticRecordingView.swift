// HapticRecordingView.swift
//
// Full-screen modal opened from Settings → ALERTS → "Record Custom Haptic..."
// Captures tap timestamps (relative to the recording start) + tap intensity
// into a [HapticTapEvent] list. The user can Preview before saving so they
// don't have to commit blindly.
//
// TestFlight v2.2.0 (b365) feedback:
//   "You should also be able to record your own haptic by clicking on the
//    screen and translating that into a haptic sequence."
//
// Why a `.fullScreenCover` + invisible tap area (instead of tapping an HStack
// of buttons): SwiftUI Buttons intercept the gesture and break the rapid
// multi-tap cadence. A bare `Color.clear.contentShape(Rectangle())` with a
// `.gesture(DragGesture(minimumDistance: 0))` registers every touch without
// frame-rate stalls.

import SwiftUI

public struct HapticRecordingView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var recordingStart: Date? = nil
    @State private var taps: [HapticTapEvent] = []
    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer? = nil
    @State private var pulseScale: CGFloat = 1.0

    private let maxDuration: TimeInterval = 5.0

    public init() {}

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 12)
                instructions
                Spacer(minLength: 8)
                tapArea
                Spacer(minLength: 12)
                bottomBar
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .statusBarHidden()
        .onAppear { startCapture() }
        .onDisappear { stopTimer() }
    }

    // MARK: - Sections

    private var topBar: some View {
        HStack {
            Button("Cancel") {
                stopTimer()
                dismiss()
            }
            .foregroundColor(DesignSystem.cyan)
            Spacer()
            Text("Record Haptic")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            Button("Save") { saveTapped() }
                .foregroundColor(taps.isEmpty ? .gray.opacity(0.5) : DesignSystem.neonGreen)
                .disabled(taps.isEmpty)
        }
    }

    private var instructions: some View {
        VStack(spacing: 6) {
            Text("Tap the area below in any rhythm you want")
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.85))
            Text(String(format: "%.1fs / %.1fs", elapsed, maxDuration))
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundColor(elapsed >= maxDuration
                                 ? DesignSystem.alertRed
                                 : DesignSystem.amber)
            Text("\(taps.count) tap\(taps.count == 1 ? "" : "s") captured")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.6))
        }
        .padding(.top, 8)
    }

    private var tapArea: some View {
        RoundedRectangle(cornerRadius: 28)
            .fill(DesignSystem.bgDeep.opacity(0.85))
            .overlay(
                Circle()
                    .fill(DesignSystem.cyan.opacity(0.18))
                    .frame(width: 220, height: 220)
                    .scaleEffect(pulseScale)
                    .animation(.easeOut(duration: 0.22), value: pulseScale)
            )
            .overlay(
                VStack(spacing: 8) {
                    Image(systemName: "hand.tap.fill")
                        .font(.system(size: 36))
                        .foregroundColor(DesignSystem.cyan.opacity(0.7))
                    Text("TAP HERE")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundColor(DesignSystem.cyan.opacity(0.7))
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 28))
            // `.onTapGesture` alone is sufficient: it fires exactly once
            // per press at touch-up. The earlier code also attached a
            // `DragGesture(minimumDistance: 0).onChanged { recordTap() }`,
            // but `onChanged` fires on every touch-move sample during a
            // single press, producing 2–5 duplicate `HapticTapEvent`
            // entries at the same `timeOffset` and a jittery visual pulse.
            .onTapGesture { recordTap() }
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Button(action: previewTapped) {
                Label("Preview", systemImage: "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(taps.isEmpty ? .gray : DesignSystem.amber)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(taps.isEmpty ? Color.gray : DesignSystem.amber,
                                    lineWidth: 2)
                    )
            }
            .disabled(taps.isEmpty)

            Button(action: clearTapped) {
                Label("Clear", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(taps.isEmpty ? .gray : DesignSystem.alertRed)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(taps.isEmpty ? Color.gray : DesignSystem.alertRed,
                                    lineWidth: 2)
                    )
            }
            .disabled(taps.isEmpty)
        }
        .padding(.bottom, 8)
    }

    // MARK: - Capture state

    private func startCapture() {
        guard recordingStart == nil else { return }
        recordingStart = Date()
        elapsed = 0
        taps = []
        // Timer fires on the main RunLoop (Timer.scheduledTimer → current
        // thread's RunLoop), and `tick()` is a `@MainActor`-isolated method
        // we can call directly — no `Task { @MainActor in … }` indirection
        // needed.
        // NOTE: SwiftUI views are value-type structs in Swift, so
        // `[weak self]` would be a compile error (`'weak' may only be
        // applied to class…`). The view stays alive while on-screen and
        // `.onDisappear` invalidates the timer; just call `tick()` here.
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            tick()
        }
    }

    private func tick() {
        guard let start = recordingStart else { return }
        elapsed = Date().timeIntervalSince(start)
        if elapsed >= maxDuration {
            stopTimer()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func recordTap() {
        guard let start = recordingStart else { return }
        guard elapsed < maxDuration else { return }
        let offset = Date().timeIntervalSince(start)
        // Touch-pressure is available when UITouch.force is hooked through a
        // UIViewRepresentable bridge; tapping gestures alone don't expose it,
        // so we pin intensity to 0.85 (slightly firmer than the .soft default)
        // for every recorded tap. Users who care about pressure can extend
        // later with a UIViewRepresentable.
        let intensity: Double = 0.85
        taps.append(HapticTapEvent(timeOffset: offset, intensity: intensity))
        // Visual feedback pulse.
        pulseScale = 1.35
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            pulseScale = 1.0
        }
    }

    private func previewTapped() {
        HapticAlertManager.shared.previewCandidate(taps)
    }

    private func clearTapped() {
        taps = []
        pulseScale = 1.0
        elapsed = 0
        recordingStart = Date()
        startCapture()
    }

    private func saveTapped() {
        stopTimer()
        HapticAlertManager.shared.saveCustomPattern(taps)
        dismiss()
    }
}
