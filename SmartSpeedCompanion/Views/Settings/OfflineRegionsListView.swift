import SwiftUI

/// List of saved offline map regions. Tap to navigate to, swipe to delete.
///
/// ─── Gating ─────────────────────────────────────────────────────────
/// The interactive map picker (`OfflineMapRegionPickerView`) is fully
/// implemented but NOT wired into the UI yet.  To activate it, add:
///
/// ```swift
/// .fullScreenCover(isPresented: $showingMapPicker) {
///     OfflineMapRegionPickerView()
///         .environmentObject(driveViewModel)
/// }
/// ```
///
/// …and wire the `showingMapPicker` trigger to a button (e.g. a "+"
/// toolbar item).  For now the list shows saved regions and allows
/// deletion only.
public struct OfflineRegionsListView: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        NavigationStack {
            List {
                if driveViewModel.savedOfflineRegions.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 40))
                            .foregroundColor(DesignSystem.bgCard)
                        Text("No saved offline regions")
                            .font(.headline)
                            .foregroundColor(.gray)
                        Text("Saved offline regions will appear here.")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                }

                ForEach(Array(driveViewModel.savedOfflineRegions.enumerated()), id: \.element.id) { index, region in
                    HStack(spacing: 14) {
                        Image(systemName: "map.fill")
                            .font(.system(size: 18))
                            .foregroundColor(DesignSystem.cyan)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(region.label)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.white)

                            // Show bounding‑box info when available (map‑picker regions),
                            // fall back to the legacy centre‑point label.
                            if let size = region.estimatedSizeMB, let spanH = region.latSpan, let spanW = region.lonSpan {
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

                        Spacer()

                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(DesignSystem.neonGreen)
                            .font(.system(size: 14))
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            driveViewModel.removeOfflineRegion(at: index)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .listRowBackground(DesignSystem.bgPanel)
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
            }
        }
        .preferredColorScheme(.dark)
    }
}
