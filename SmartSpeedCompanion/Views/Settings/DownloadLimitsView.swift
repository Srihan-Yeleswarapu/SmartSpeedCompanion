import SwiftUI

/// "Download Limits" sheet — pick a radius (10–50 miles) around your current
/// location, see a live size + time estimate while dragging the slider, then
/// download every speed limit in that radius for offline use.
///
/// The estimate is real: `DriveViewModel.refreshLimitsEstimate` runs an
/// Overpass `out count;` query for the exact radius (falling back to a
/// density heuristic while the slider is mid-drag or offline). Confirming
/// kicks off `OfflineLimitsDownloader.download` with a progress bar and a
/// Cancel button; completed zones appear in the Offline list.
public struct DownloadLimitsView: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var radiusMiles: Double = 20
    @State private var pinZone: Bool = false
    @State private var estimateTask: Task<Void, Never>?
    /// Snapshot shown while a fresh estimate is in flight (avoids flicker).
    @State private var displayEstimate: OfflineLimitsEstimate?

    private let minMiles: Double = 10
    private let maxMiles: Double = 50

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                DesignSystem.bgDeep.ignoresSafeArea()

                VStack(spacing: 24) {
                    header
                    radiusSliderCard
                    estimateCard
                    pinCard
                    Spacer()
                    actionArea
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
            .navigationTitle("Download Limits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(DesignSystem.cyan)
                }
            }
            .preferredColorScheme(.dark)
            .onAppear {
                refreshEstimate()
            }
            .onDisappear {
                estimateTask?.cancel()
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(DesignSystem.cyan.opacity(0.14))
                    .frame(width: 56, height: 56)
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(DesignSystem.cyan)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Go offline anywhere")
                    .font(.system(size: 18, weight: .black))
                    .foregroundColor(.white)
                Text("Caches every speed limit in this radius so you still see limits with no signal.")
                    .font(.system(size: 12.5))
                    .foregroundColor(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var radiusSliderCard: some View {
        VStack(spacing: 14) {
            HStack {
                Text("RADIUS")
                    .font(DesignSystem.labelFont)
                    .foregroundColor(DesignSystem.cyan)
                Spacer()
                Text("\\(Int(radiusMiles.rounded())) mi")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                    .contentTransition(.numericText())
            }

            Slider(value: $radiusMiles, in: minMiles...maxMiles, step: 1)
                .tint(DesignSystem.cyan)
                .onChange(of: radiusMiles) { _, _ in
                    refreshEstimate()
                }

            HStack {
                Text("\\(Int(minMiles)) mi")
                    .font(.caption2.bold())
                    .foregroundColor(.white.opacity(0.4))
                Spacer()
                Text("MAX")
                    .font(.caption2.bold())
                    .foregroundColor(DesignSystem.amber)
                Text("\\(Int(maxMiles)) mi")
                    .font(.caption2.bold())
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(18)
        .background(DesignSystem.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(DesignSystem.cyan.opacity(0.25), lineWidth: 1)
        )
    }

    private var estimateCard: some View {
        let estimate = displayEstimate ?? driveViewModel.limitsEstimate
        let isReal = estimate?.isReal ?? false

        return VStack(spacing: 14) {
            HStack {
                Label("SIZE ESTIMATE", systemImage: "internaldrive")
                    .font(DesignSystem.labelFont)
                    .foregroundColor(DesignSystem.cyan)
                Spacer()
                if !isReal {
                    Text("CALCULATING…")
                        .font(.system(size: 9, weight: .black))
                        .foregroundColor(DesignSystem.amber)
                }
            }

            HStack(spacing: 0) {
                statTile(
                    icon: "internaldrive.fill",
                    value: estimate?.sizeLabel ?? "…",
                    caption: "storage",
                    tint: DesignSystem.neonGreen
                )
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1, height: 44)
                statTile(
                    icon: "clock.fill",
                    value: estimate?.timeLabel ?? "…",
                    caption: "to download",
                    tint: DesignSystem.cyan
                )
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1, height: 44)
                statTile(
                    icon: "road.lanes",
                    value: estimate.map { formatCount($0.roadCount) } ?? "…",
                    caption: "road points",
                    tint: DesignSystem.amber
                )
            }

            if driveViewModel.isDownloadingLimits {
                VStack(spacing: 8) {
                    ProgressView(value: driveViewModel.limitsDownloadProgress)
                        .tint(DesignSystem.cyan)
                    Text("Downloading… \\(Int(driveViewModel.limitsDownloadProgress * 100))%")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
        }
        .padding(18)
        .background(DesignSystem.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(DesignSystem.cyan.opacity(0.25), lineWidth: 1)
        )
    }

    private var pinCard: some View {
        Toggle(isOn: $pinZone) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Keep forever")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                Text("Pinned zones never auto-delete (default is 30-day cleanup).")
                    .font(.system(size: 11.5))
                    .foregroundColor(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(DesignSystem.neonGreen)
        .padding(18)
        .background(DesignSystem.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var actionArea: some View {
        if driveViewModel.isDownloadingLimits {
            Button(action: {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                driveViewModel.cancelLimitsDownload()
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "stop.circle.fill")
                    Text("Cancel Download")
                        .font(.system(size: 16, weight: .black))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(DesignSystem.alertRed)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        } else {
            Button(action: {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                driveViewModel.startLimitsDownload(radiusMiles: radiusMiles, pinned: pinZone)
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down.fill")
                    Text("Download Limits")
                        .font(.system(size: 16, weight: .black))
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(DesignSystem.cyan)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: DesignSystem.cyan.opacity(0.4), radius: 10, y: 4)
            }
            .disabled(driveViewModel.locationManager.latestLocation == nil)
            .opacity(driveViewModel.locationManager.latestLocation == nil ? 0.5 : 1)
        }
    }

    // MARK: - Helpers

    private func statTile(icon: String, value: String, caption: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(tint)
            Text(value)
                .font(.system(size: 16, weight: .black, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption.uppercased())
                .font(.system(size: 8, weight: .black))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
    }

    private func refreshEstimate() {
        estimateTask?.cancel()
        let radius = radiusMiles
        // Show the heuristic instantly so the UI never stalls, then let the
        // real count query replace it once it returns.
        displayEstimate = OfflineLimitsDownloader.shared.heuristicEstimate(radiusMiles: radius)
        estimateTask = Task {
            // Debounce the real Overpass count query (~500 ms after the slider
            // settles) so dragging across the range doesn't fire a network
            // request per step — Overpass throttles at ~2 req/sec and a burst
            // would trigger 429s. Cancelling the previous task makes the
            // sleep return early, so only the final slider position queries.
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await driveViewModel.refreshLimitsEstimate(radiusMiles: radius)
            guard !Task.isCancelled else { return }
            if let fresh = driveViewModel.limitsEstimate {
                displayEstimate = fresh
            }
        }
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1000 { return String(format: "%.1fk", Double(count) / 1000) }
        return "\\(count)"
    }
}
