import SwiftUI
import MapKit

/// Make MKCoordinateRegion Equatable so SwiftUI's `.onChange(of:)` works.
extension MKCoordinateRegion: @retroactive Equatable {
    public static func == (lhs: MKCoordinateRegion, rhs: MKCoordinateRegion) -> Bool {
        lhs.center.latitude == rhs.center.latitude &&
        lhs.center.longitude == rhs.center.longitude &&
        lhs.span.latitudeDelta == rhs.span.latitudeDelta &&
        lhs.span.longitudeDelta == rhs.span.longitudeDelta
    }
}

// MARK: - OfflineMapRegionPickerView
//
// Full‑screen interactive map picker for selecting an offline map region.
//
// The user pans and zooms freely; a fixed rectangular overlay indicates
// the area that will be saved.  The visible MKCoordinateRegion is clamped
// to a maximum of 5 km × 5 km so the user cannot download an unreasonably
// large area.  A size estimate (in MB) is computed from the visible span
// and shown alongside a name field + Save button.
//
public struct OfflineMapRegionPickerView: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    @Environment(\.dismiss) private var dismiss

    // ── Picker state ───────────────────────────────────────────────
    @State private var regionName: String = ""
    /// The latest visible region reported by the map.  Updated on every
    /// significant span/centre change via the MKMapView delegate.
    @State private var visibleRegion: MKCoordinateRegion = {
        // Default to Phoenix, AZ (the app's primary service area)
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 33.4484, longitude: -112.0740),
            latitudinalMeters: 2000,
            longitudinalMeters: 2000
        )
    }()
    @State private var estimatedSizeMB: Double = 0
    @State private var areaText: String = ""
    @State private var isOverLimit: Bool = false

    // ── Constants ──────────────────────────────────────────────────
    /// Maximum bounding‑box area: 5 km × 5 km (25 km²).
    private let maxLatMeters: CLLocationDistance = 5000
    private let maxLonMeters: CLLocationDistance = 5000

    // ── Body ───────────────────────────────────────────────────────
    public var body: some View {
        NavigationStack {
            ZStack {
                // 1. Interactive map
                RegionPickerMapView(visibleRegion: $visibleRegion,
                                    maxLatMeters: maxLatMeters,
                                    maxLonMeters: maxLonMeters)
                    .ignoresSafeArea()

                // 2. Semi‑transparent overlay with a clear cut‑out in the
                //    centre, showing the user exactly which area is selected.
                //    The centre rectangle size is proportional to the span.
                SelectionOverlay(isOverLimit: isOverLimit)
            }
            .background(DesignSystem.bgDeep.ignoresSafeArea())
            .navigationTitle("Select Map Area")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(DesignSystem.cyan)
                }
            }
            // Bottom panel pinned to the safe‑area bottom
            .safeAreaInset(edge: .bottom) {
                bottomPanel
            }
            .preferredColorScheme(.dark)
            .onChange(of: visibleRegion) { _, _ in
                recalculateEstimate()
            }
            .onAppear {
                // Seed initial estimate
                recenterToUser()
            }
        }
    }

    // MARK: - Bottom Panel

    @ViewBuilder
    private var bottomPanel: some View {
        VStack(spacing: 12) {
            // ── Name field ────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Text("REGION NAME")
                    .font(.system(size: 11, weight: .black))
                    .foregroundColor(DesignSystem.cyan)
                    .padding(.horizontal, 4)

                TextField("e.g. \"Phoenix Downtown\"", text: $regionName)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(DesignSystem.bgCard)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(DesignSystem.cyan.opacity(0.3), lineWidth: 1)
                    )
                    .submitLabel(.done)
                    .onSubmit(saveRegion)
            }

            // ── Stats row ─────────────────────────────────────────────
            HStack(spacing: 16) {
                statBadge(icon: "arrow.up.arrow.down.square",
                          value: areaText,
                          tint: isOverLimit ? DesignSystem.alertRed : DesignSystem.neonGreen)
                statBadge(icon: "square.and.arrow.down",
                          value: estimatedSizeMB < 0.01 ? "<0.01 MB" : String(format: "%.2f MB", estimatedSizeMB),
                          tint: DesignSystem.cyan)
            }

            // ── Limit warning ─────────────────────────────────────────
            if isOverLimit {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(DesignSystem.alertRed)
                        .font(.system(size: 13))
                    Text("Max area is 5 km × 5 km. Zoom in to fit the limit.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DesignSystem.alertRed)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(DesignSystem.alertRed.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            // ── Save button ───────────────────────────────────────────
            Button(action: saveRegion) {
                Text("Save Offline Region")
                    .font(.system(size: 17, weight: .black))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        (regionName.trimmingCharacters(in: .whitespaces).isEmpty || isOverLimit)
                            ? DesignSystem.cyan.opacity(0.4)
                            : DesignSystem.cyan
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(regionName.trimmingCharacters(in: .whitespaces).isEmpty || isOverLimit)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background {
            DesignSystem.bgPanel
                .opacity(0.96)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    // MARK: - Helpers

    /// Small pill‑style badge for area / size stats.
    private func statBadge(icon: String, value: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(tint)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Recomputes area and download estimate from the current visible region.
    private func recalculateEstimate() {
        let centerLat = visibleRegion.center.latitude
        let latDelta = visibleRegion.span.latitudeDelta
        let lonDelta = visibleRegion.span.longitudeDelta

        // Convert degrees → metres (approximate)
        let latMeters = abs(latDelta) * 111_000.0
        let lonMeters = abs(lonDelta) * 111_000.0 * cos(centerLat * .pi / 180.0)

        let areaSqKm = (latMeters * lonMeters) / 1_000_000.0

        // Clamp check
        isOverLimit = latMeters > maxLatMeters || lonMeters > maxLonMeters

        // Format area
        if areaSqKm < 1.0 {
            areaText = String(format: "%.0f m²", latMeters * lonMeters)
        } else {
            areaText = String(format: "%.2f km²", areaSqKm)
        }

        // Rough tile‑based download estimate:
        // At zoom ~14 each tile covers ~0.01° × 0.01° and is ~40 KB.
        let tileCount = ceil(latDelta / 0.01) * ceil(lonDelta / 0.01)
        estimatedSizeMB = max(0.01, tileCount * 0.04)
        // Cap at a sane maximum so the UI never shows absurd numbers
        // even if the user briefly exceeds the limit before snapping.
        if estimatedSizeMB > 500 { estimatedSizeMB = 500 }
    }

    /// Recentres the map to the user's current GPS location (or Phoenix default).
    private func recenterToUser() {
        guard let loc = driveViewModel.locationManager.latestLocation else { return }
        visibleRegion = MKCoordinateRegion(
            center: loc.coordinate,
            latitudinalMeters: 2000,
            longitudinalMeters: 2000
        )
    }

    /// Saves the current picker state as an offline region.
    private func saveRegion() {
        let trimmed = regionName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isOverLimit else { return }
        driveViewModel.saveOfflineRegion(named: trimmed, region: visibleRegion, estimatedSizeMB: estimatedSizeMB)
        dismiss()
    }
}

// MARK: - SelectionOverlay
//
/// A full‑screen overlay that dims the surrounding map area and draws a
/// clear rectangle (with an animated border) indicating the selected region.
private struct SelectionOverlay: View {
    let isOverLimit: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width * 0.75
            let h = geo.size.height * 0.45

            ZStack {
                // Outer dimming (tappable to dismiss keyboard)
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { dismissKeyboard() }

                // Clear cut‑out
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: w, height: h)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(isOverLimit ? DesignSystem.alertRed : DesignSystem.cyan,
                                    lineWidth: 2.5)
                    )
                    // Corner brackets for a precision‑tool feel
                    .overlay(alignment: .topLeading) {
                        CornerBracket(length: 24)
                            .stroke(DesignSystem.cyan, lineWidth: 2)
                            .offset(x: -6, y: -6)
                    }
                    .overlay(alignment: .topTrailing) {
                        CornerBracket(length: 24)
                            .rotation(.degrees(90))
                            .stroke(DesignSystem.cyan, lineWidth: 2)
                            .offset(x: 6, y: -6)
                    }
                    .overlay(alignment: .bottomLeading) {
                        CornerBracket(length: 24)
                            .rotation(.degrees(-90))
                            .stroke(DesignSystem.cyan, lineWidth: 2)
                            .offset(x: -6, y: 6)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        CornerBracket(length: 24)
                            .rotation(.degrees(180))
                            .stroke(DesignSystem.cyan, lineWidth: 2)
                            .offset(x: 6, y: 6)
                    }
                    // Subtle glow behind the selection
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(DesignSystem.cyan.opacity(0.06))
                    )
            }
        }
    }

    /// L‑shaped bracket for corner decoration.
    private struct CornerBracket: Shape {
        let length: CGFloat

        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: length))
            p.addLine(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: length, y: 0))
            return p
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }
}

// MARK: - RegionPickerMapView (UIViewRepresentable)

/// Wraps MKMapView to act as an interactive pan‑/zoom‑based region picker.
///
/// The visible region is bound to `$visibleRegion` and is clamped so
/// the user cannot zoom out beyond `maxLatMeters` × `maxLonMeters`.
private struct RegionPickerMapView: UIViewRepresentable {
    @Binding var visibleRegion: MKCoordinateRegion
    let maxLatMeters: CLLocationDistance
    let maxLonMeters: CLLocationDistance

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.setRegion(visibleRegion, animated: false)
        map.showsUserLocation = true
        map.mapType = .standard

        // Disable pitch / 3D for a clean top‑down picker experience.
        map.isPitchEnabled = false
        map.isRotateEnabled = true

        // Remove Apple POI clutter so the overlay is clearly visible.
        if #available(iOS 16.0, *) {
            let config = MKStandardMapConfiguration()
            config.pointOfInterestFilter = .excludingAll
            config.showsTraffic = false
            map.preferredConfiguration = config
        }

        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // Critical: refresh the coordinator's parent reference so delegate
        // callbacks write to the current @Binding, not a stale struct copy.
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: RegionPickerMapView
        /// Gate to ignore region‑change events we triggered ourselves.
        private var isUpdatingFromCode = false

        init(parent: RegionPickerMapView) {
            self.parent = parent
        }

        func mapView(_ map: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard !isUpdatingFromCode else { return }

            var region = map.region

            // ── Clamp span to max allowed ─────────────────────────
            let centerLat = region.center.latitude
            let maxLatDelta = parent.maxLatMeters / 111_000.0
            let maxLonDelta = parent.maxLonMeters / (111_000.0 * cos(centerLat * .pi / 180.0))

            if region.span.latitudeDelta > maxLatDelta {
                region.span.latitudeDelta = maxLatDelta
            }
            if region.span.longitudeDelta > maxLonDelta {
                region.span.longitudeDelta = maxLonDelta
            }

            // If clamping was needed, re‑apply the clamped region
            // without triggering another full cycle.
            if region.span.latitudeDelta != map.region.span.latitudeDelta ||
               region.span.longitudeDelta != map.region.span.longitudeDelta
            {
                isUpdatingFromCode = true
                map.setRegion(region, animated: true)
                // Fire one final callback after the clamp animation
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.isUpdatingFromCode = false
                    self?.parent.visibleRegion = map.region
                }
            }

            parent.visibleRegion = region
        }

        /// Suppress callout / annotation selection while in picker mode.
        func mapView(_ map: MKMapView, didSelect view: MKAnnotationView) {
            map.deselectAnnotation(view.annotation, animated: false)
        }
    }
}
