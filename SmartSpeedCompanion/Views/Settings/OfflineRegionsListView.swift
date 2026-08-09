import SwiftUI

/// List of saved offline map regions. Tap to navigate to, swipe to delete.
///
/// Speed-limit downloads are intentionally not shown here: the former OSM
/// downloader was retired when HERE became the authoritative driving source.
public struct OfflineRegionsListView: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        NavigationStack {
            List {
                emptyState
                offlineMapRegions
            }
            .scrollContentBackground(.hidden)
            .background(DesignSystem.bgDeep.ignoresSafeArea())
            .navigationTitle("Offline Maps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(DesignSystem.cyan)
                }
            }
            .onAppear {
                driveViewModel.loadOfflineRegions()
                driveViewModel.loadLimitsZones()
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var emptyState: some View {
        if driveViewModel.savedOfflineRegions.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 40))
                    .foregroundColor(DesignSystem.bgCard)
                Text("No saved offline data")
                    .font(.headline)
                    .foregroundColor(.gray)
                Text("Saved offline map regions will appear here.")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var offlineMapRegions: some View {
        if !driveViewModel.savedOfflineRegions.isEmpty {
            Section(header: Text("MAP REGIONS")
                .font(DesignSystem.labelFont)
                .foregroundColor(DesignSystem.cyan)) {
                ForEach(Array(driveViewModel.savedOfflineRegions.enumerated()), id: \.element.id) { index, region in
                    OfflineMapRegionRow(
                        region: region,
                        onDelete: { driveViewModel.removeOfflineRegion(at: index) }
                    )
                }
                .listRowBackground(DesignSystem.bgPanel)
            }
        }
    }
}

private struct OfflineMapRegionRow: View {
    let region: OfflineRegion
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "map.fill")
                .font(.system(size: 18))
                .foregroundColor(DesignSystem.cyan)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(region.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                detailText
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(DesignSystem.neonGreen)
                .font(.system(size: 14))
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var detailText: some View {
        if let size = region.estimatedSizeMB,
           let spanH = region.latSpan,
           let spanW = region.lonSpan {
            let kmW = spanW * 111_000.0 * cos(region.lat * .pi / 180.0) / 1000.0
            let kmH = spanH * 111_000.0 / 1000.0
            Text(String(format: "%.1f × %.1f km  •  %.2f MB  •  %@",
                        kmH, kmW, size,
                        region.timestamp.formatted(date: .abbreviated, time: .shortened)))
                .font(.caption2)
                .foregroundColor(.gray)
        } else {
            Text("Saved \(region.timestamp.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundColor(.gray)
        }
    }
}
