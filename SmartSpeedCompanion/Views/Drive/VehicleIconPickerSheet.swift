import SwiftUI

/// Bottom sheet with a grid of vehicle icons the user can select to replace the
/// default blue dot on the map. Follows the same styling as other sheets in the app.
public struct VehicleIconPickerSheet: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    public init() {}

    // Resolve the currently-selected icon to a concrete catalog entry so the
    // preview reflects even an out-of-catalog id (falls back to the default).
    private var selectedIcon: VehicleIcon {
        VehicleIcon.icon(for: driveViewModel.selectedVehicleIconId)
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Drag indicator
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 36, height: 5)
                    .padding(.top, 12)

                // ── Preview Header ─────────────────────────────────────
                // TestFlight 29-tester feedback: "If I change the icon,
                // it looks like straight garbage… eww." The previous
                // sheet jumped straight from the title to a grid of
                // small icons, so users never saw a *preview* of what
                // they were picking and couldn't tell how the chosen
                // symbol would render at map-scale. Show a large
                // preview circle at the top — the active icon at map
                // tile sizes, the friendly displayName underneath — so
                // every tap has an immediate, scaled-up representation
                // to compare against the grid.
                previewHeader

                // ── Icon grid ──────────────────────────────────────────
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(VehicleIcon.catalog) { icon in
                            Button(action: {
                                driveViewModel.selectedVehicleIconId = icon.id
                                dismiss()
                            }) {
                                iconCell(icon: icon)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 16)
                }
            }
            .padding(.horizontal, 20)
            .background(DesignSystem.bgDeep.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(DesignSystem.cyan)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Preview Header

    private var previewHeader: some View {
        VStack(spacing: 8) {
            // 90pt hero circle mirrors the layer the user sees on the
            // map. Tinted from the catalog's `tintColor` so the preview
            // and the rendered MKAnnotationView agree (was inconsistent
            // before — picker showed cyan for everything, the map
            // rendered the per-icon tint).
            ZStack {
                Circle()
                    .fill(DesignSystem.bgCard)
                    .frame(width: 96, height: 96)
                Circle()
                    .stroke(DesignSystem.cyan.opacity(0.4), lineWidth: 2)
                    .frame(width: 96, height: 96)
                Image(systemName: selectedIcon.systemImageName)
                    .font(.system(size: 44, weight: .bold))
                    .foregroundColor(selectedIcon.tintColor.color)
            }
            Text(selectedIcon.displayName)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
            Text("Tap an icon below to update your position on the map")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 4)
    }

    // MARK: - Grid Cell

    // Per-cell rendering. Receives the icon directly so the picker can
    // compute the selected/idle visual state without re-reading the
    // view model on every cell.
    @ViewBuilder
    private func iconCell(icon: VehicleIcon) -> some View {
        let isSelected = driveViewModel.selectedVehicleIconId == icon.id
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected
                          ? DesignSystem.cyan.opacity(0.15)
                          : DesignSystem.bgCard)
                    .frame(height: 72)

                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected
                            ? DesignSystem.cyan
                            : Color.white.opacity(0.08),
                            lineWidth: isSelected ? 2 : 1)

                Image(systemName: icon.systemImageName)
                    .font(.system(size: 28))
                    .foregroundColor(isSelected
                                     ? icon.tintColor.color
                                     : .white.opacity(0.85))

                // Checkmark badge in the top-trailing corner — visible
                // only on the active cell so the user always knows
                // which icon is current without scrolling back to the
                // preview header. Sits on top of the stroke so it
                // reads as "this is the one" rather than blending in.
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(DesignSystem.cyan)
                        .background(
                            Circle()
                                .fill(DesignSystem.bgDeep)
                                .frame(width: 14, height: 14)
                        )
                        .offset(x: 6, y: -6)
                }
            }

            Text(icon.displayName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    // MARK: - Helpers
    //
    // Color resolution now lives on `VehicleIconTint.color` (and
    // `uiColor` for UIKit consumers like LiveMapView's MKAnnotationView)
    // — the previous local `tintUIColor(_:)` helper was deleted during
    // the FB25 / FB27 cleanup so the picker and the on-map icon cannot
    // drift out of sync (code review flagged the duplication).
}
