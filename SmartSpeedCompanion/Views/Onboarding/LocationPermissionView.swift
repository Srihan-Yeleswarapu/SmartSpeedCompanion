import SwiftUI

/// Shown immediately after the tutorial (when the user taps Skip or Get Started).
/// Explains *why* the app needs location access, then triggers the system
/// permission dialog when the user taps the Continue button.
public struct LocationPermissionView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var driveViewModel: DriveViewModel

    @State private var phase: PermissionPhase = .explain
    @State private var pulseGlow = false

    private let locationManager = driveViewModel.locationManager

    public init() {}

    public var body: some View {
        ZStack {
            DesignSystem.bgDeep.ignoresSafeArea()

            // ── Animated background glow ──────────────────────
            RadialGradient(
                gradient: Gradient(colors: [
                    DesignSystem.cyan.opacity(pulseGlow ? 0.12 : 0.04),
                    .clear
                ]),
                center: .center,
                startRadius: 0,
                endRadius: 300
            )
            .ignoresSafeArea()
            .animation(
                .easeInOut(duration: 2.5).repeatForever(autoreverses: true),
                value: pulseGlow
            )

            VStack(spacing: 0) {
                Spacer()

                // ── Icon ──────────────────────────────────────
                ZStack {
                    Circle()
                        .fill(DesignSystem.cyan.opacity(0.1))
                        .frame(width: 120, height: 120)

                    Image(systemName: "location.fill")
                        .font(.system(size: 48))
                        .foregroundColor(DesignSystem.cyan)
                }
                .padding(.bottom, 32)

                // ── Title ─────────────────────────────────────
                Text("Location Access")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.bottom, 12)

                // ── Explanation ───────────────────────────────
                VStack(alignment: .leading, spacing: 16) {
                    bulletRow(
                        icon: "speedometer",
                        text: "Show your real-time speed as you drive"
                    )
                    bulletRow(
                        icon: "signpost.right.fill",
                        text: "Display the speed limit of the road you are on"
                    )
                    bulletRow(
                        icon: "map.fill",
                        text: "Pin your location on the map for navigation"
                    )
                    bulletRow(
                        icon: "exclamationmark.triangle.fill",
                        text: "Alert you when you are exceeding the speed limit"
                    )
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)

                // ── Privacy reassurance ───────────────────────
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Text("Your location data stays on your device and is never shared.")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 36)

                Spacer()

                // ── Continue button ───────────────────────────
                Button(action: requestPermission) {
                    HStack(spacing: 10) {
                        Image(systemName: "location.fill")
                            .font(.headline)
                        Text("Allow While Using the App")
                            .font(.headline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                DesignSystem.cyan,
                                DesignSystem.cyan.opacity(0.7)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .foregroundColor(.white)
                    .cornerRadius(16)
                    .shadow(color: DesignSystem.cyan.opacity(0.4), radius: 12, x: 0, y: 4)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 12)

                // ── Maybe later link ──────────────────────────
                Button(action: skipPermission) {
                    Text("Not now, I'll do this later")
                        .font(.subheadline)
                        .foregroundColor(.gray.opacity(0.7))
                        .underline()
                }
                .padding(.bottom, 40)

                // ── Disclaimer ───────────────────────────────
                Text("Do not interact with Speedio while driving.\nAlways prioritize road safety.")
                    .font(.caption2)
                    .foregroundColor(.gray.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 20)
            }
        }
        .onAppear {
            pulseGlow = true

            // If permission was already granted on a previous launch,
            // skip straight to the main app.
            if locationManager.authorizationStatus == .authorizedWhenInUse
                || locationManager.authorizationStatus == .authorizedAlways {
                proceedToApp()
            }
        }
        .onChange(of: locationManager.authorizationStatus) { _, newStatus in
            // After the user responds to the system dialog, proceed.
            if newStatus == .authorizedWhenInUse || newStatus == .authorizedAlways {
                proceedToApp()
            } else if newStatus == .denied || newStatus == .restricted {
                // The user declined — still let them into the app;
                // they can enable location later from Settings.
                proceedToApp()
            }
        }
    }

    // MARK: - Helpers

    private func bulletRow(icon: String, text: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(DesignSystem.cyan)
                .frame(width: 28)

            Text(text)
                .font(.body)
                .foregroundColor(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    private func requestPermission() {
        locationManager.requestWhenInUseAuthorization()
    }

    private func skipPermission() {
        proceedToApp()
    }

    private func proceedToApp() {
        withAnimation(.easeOut(duration: 0.3)) {
            appState.hasSeenLocationPermission = true
        }
    }

    private enum PermissionPhase {
        case explain
    }
}
