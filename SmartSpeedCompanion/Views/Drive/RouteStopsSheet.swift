import SwiftUI
import MapKit

// MARK: - RouteStopsSheet
//
// A bottom sheet that shows the user's multi-stop route, allowing them to:
//   • View all ordered stops with per-leg ETA and distance
//   • Drag to reorder stops
//   • Swipe to delete stops
//   • Add a new stop via search
//   • Compare current ordering with the most efficient ordering
//   • Apply the optimal ordering
//
// Modeled after Apple Maps' multi-stop UI with a card-style list and
// a prominent "Add Stop" button at the bottom.

public struct RouteStopsSheet: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var editMode: EditMode = .inactive
    @State private var showAddStopSearch = false
    @State private var addStopQuery = ""
    @State private var isComparing = false

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header
                sheetHeader

                if driveViewModel.routeStops.isEmpty {
                    emptyState
                } else {
                    // Stops list
                    stopsList
                }

                // Bottom actions
                bottomActions
            }
            .background(DesignSystem.bgPanel)
            .navigationBarHidden(true)
            .environment(\.editMode, $editMode)
            // Add-stop search sheet
            .sheet(isPresented: $showAddStopSearch) {
                AddStopSearchSheet { mapItem in
                    Task {
                        await driveViewModel.addStopToRoute(mapItem)
                        showAddStopSearch = false
                    }
                }
                .environmentObject(driveViewModel)
                .presentationDetents([.height(480), .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
                .preferredColorScheme(.dark)
            }
        }
    }

    // MARK: - Sheet Header

    private var sheetHeader: some View {
        VStack(spacing: 4) {
            // Drag indicator
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color.white.opacity(0.3))
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            HStack {
                Text("Route Stops")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)

                Spacer()

                // Close button
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // Destination chip
            if let dest = driveViewModel.destination {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(DesignSystem.cyan)
                    Text("Final destination: ")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                    Text(dest.name ?? "Destination")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            // Ordering comparison banner
            if let comparison = driveViewModel.orderingComparison, comparison.canSaveTime {
                orderingBanner(comparison)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // MARK: - Ordering Comparison Banner

    private func orderingBanner(_ comparison: OrderingComparison) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 16))
                .foregroundColor(DesignSystem.amber)

            VStack(alignment: .leading, spacing: 1) {
                Text("Faster route available")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                Text("Optimal: \(comparison.bestFormatted) · \(comparison.savedFormatted)")
                    .font(.system(size: 11))
                    .foregroundColor(DesignSystem.amber)
            }

            Spacer()

            Button(action: {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                Task { await driveViewModel.applyBestStopOrdering() }
            }) {
                Text("Apply")
                    .font(.system(size: 12, weight: .black))
                    .foregroundColor(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(DesignSystem.amber)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(DesignSystem.amber.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DesignSystem.amber.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.15))

            VStack(spacing: 4) {
                Text("No Stops Added")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)

                Text("Add stops along your route for errands,\ngas, or quick pit stops.")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Stops List

    private var stopsList: some View {
        List {
            // Origin
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: "location.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.white)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text("Current Location")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            // Intermediate stops
            ForEach(Array(driveViewModel.routeStops.enumerated()), id: \.element.id) { index, stop in
                StopRow(
                    index: index + 1,
                    stop: stop,
                    isLast: index == driveViewModel.routeStops.count - 1,
                    onDelete: {
                        Task { await driveViewModel.removeStopFromRoute(stop.id) }
                    }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .onMove { from, to in
                guard let fromIndex = from.first else { return }
                Task {
                    await driveViewModel.moveStopInRoute(from: fromIndex, to: to)
                }
            }
            .onDelete { indexSet in
                if let idx = indexSet.first, idx < driveViewModel.routeStops.count {
                    let id = driveViewModel.routeStops[idx].id
                    Task { await driveViewModel.removeStopFromRoute(id) }
                }
            }

            // Final destination
            if let dest = driveViewModel.destination {
                DestinationRow(destination: dest)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            // Totals row
            if !driveViewModel.routeLegs.isEmpty {
                totalsRow
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
    }

    // MARK: - Totals Row

    private var totalsRow: some View {
        HStack {
            Spacer()
            HStack(spacing: 16) {
                // Total time
                Label {
                    Text(totalTimeFormatted)
                        .font(.system(size: 15, weight: .black))
                        .foregroundColor(DesignSystem.cyan)
                } icon: {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 11))
                        .foregroundColor(DesignSystem.cyan)
                }

                // Total distance
                Label {
                    Text(totalDistanceFormatted)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                } icon: {
                    Image(systemName: "road.lanes")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .liquidGlassChip(cornerRadius: 16, tint: DesignSystem.cyan.opacity(0.06), interactive: false)
        }
        .padding(.top, 4)
    }

    private var totalTimeFormatted: String {
        let total = driveViewModel.routeLegs.reduce(0) { $0 + $1.travelTime }
        let min = Int(total / 60)
        if min < 60 { return "\(min) min" }
        return "\(min / 60)h \(min % 60)m"
    }

    private var totalDistanceFormatted: String {
        let meters = driveViewModel.routeLegs.reduce(0) { $0 + $1.distance }
        let miles = meters * 0.000621371
        if miles < 0.1 { return "\(Int(meters * 3.28084)) ft" }
        return String(format: "%.1f mi", miles)
    }

    // MARK: - Bottom Actions

    private var bottomActions: some View {
        VStack(spacing: 0) {
            Divider()
                .background(Color.white.opacity(0.08))

            HStack(spacing: 12) {
                // Add Stop button
                Button(action: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    addStopQuery = ""
                    showAddStopSearch = true
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                        Text("Add Stop")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .liquidGlassChip(cornerRadius: 14, tint: DesignSystem.cyan.opacity(0.08), interactive: true)
                }
                .buttonStyle(.plain)

                // Compare button
                if driveViewModel.routeStops.count >= 2 {
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        isComparing = true
                        Task {
                            await driveViewModel.compareStopOrderings()
                            isComparing = false
                        }
                    }) {
                        HStack(spacing: 6) {
                            if isComparing {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .scaleEffect(0.8)
                                    .tint(DesignSystem.cyan)
                            } else {
                                Image(systemName: "arrow.triangle.swap")
                                    .font(.system(size: 14))
                                Text("Optimize")
                                    .font(.system(size: 13, weight: .bold))
                            }
                        }
                        .foregroundColor(DesignSystem.cyan)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(DesignSystem.cyan.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isComparing)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(DesignSystem.bgPanel)
    }
}

// MARK: - StopRow

fileprivate struct StopRow: View {
    let index: Int
    let stop: RouteStop
    let isLast: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Order number badge
            ZStack {
                Circle()
                    .fill(DesignSystem.cyan.opacity(0.2))
                    .frame(width: 28, height: 28)

                Text("\(index)")
                    .font(.system(size: 13, weight: .black))
                    .foregroundColor(DesignSystem.cyan)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(stop.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                if let address = stop.address, !address.isEmpty {
                    Text(address)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                }

                // Per-leg ETA chip
                if let travelTime = stop.travelTimeFromPrevious {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 8))
                            .foregroundColor(DesignSystem.cyan.opacity(0.7))
                        Text(formatDuration(travelTime))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(DesignSystem.cyan)

                        if let dist = stop.distanceFromPrevious {
                            Text("·")
                                .foregroundColor(.white.opacity(0.3))
                            Text(formatDistance(dist))
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                }

                // Arrival time hint
                if let cumulative = stop.cumulativeTravelTime {
                    let arrival = Date().addingTimeInterval(cumulative)
                    Text("Arrive \(arrival, format: .dateTime.hour().minute())")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.3))
                }
            }

            Spacer()

            // Drag handle + delete
            HStack(spacing: 6) {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.3))
                }
                .buttonStyle(.plain)

                Image(systemName: "line.horizontal.3")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.2))
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DesignSystem.cyan.opacity(isLast ? 0.15 : 0), lineWidth: 1)
        )
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let min = Int(seconds / 60)
        if min < 60 { return "\(min) min" }
        return "\(min / 60)h \(min % 60)m"
    }

    private func formatDistance(_ meters: CLLocationDistance) -> String {
        let miles = meters * 0.000621371
        if miles < 0.1 { return "\(Int(meters * 3.28084)) ft" }
        return String(format: "%.1f mi", miles)
    }
}

// MARK: - DestinationRow

fileprivate struct DestinationRow: View {
    let destination: MKMapItem

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(DesignSystem.cyan)
                    .frame(width: 28, height: 28)

                Image(systemName: "mappin")
                    .font(.system(size: 11, weight: .black))
                    .foregroundColor(.black)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(destination.name ?? "Destination")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                if let address = destination.placemark.title, !address.isEmpty {
                    Text(address)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "flag.fill")
                .font(.system(size: 14))
                .foregroundColor(DesignSystem.cyan)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DesignSystem.cyan.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - AddStopSearchSheet

fileprivate struct AddStopSearchSheet: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    @Environment(\.dismiss) private var dismiss
    let onSelect: (MKMapItem) -> Void

    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var isSearching = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(DesignSystem.cyan)
                        .font(.system(size: 14, weight: .bold))

                    TextField("Search for a stop...", text: $query)
                        .foregroundColor(.white)
                        .font(.system(size: 16, weight: .medium))
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { performSearch() }
                        .onChange(of: query) { _, newValue in
                            if newValue.isEmpty { results = [] }
                        }
                        .onAppear { }

                    if !query.isEmpty {
                        Button(action: { query = ""; results = [] }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
                .padding(.top, 12)

                // Quick categories
                quickCategories
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                // Results
                if results.isEmpty && !isSearching && query.isEmpty {
                    emptySearchHint
                } else if isSearching {
                    Spacer()
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(DesignSystem.cyan)
                    Spacer()
                } else if results.isEmpty && !query.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "map")
                            .font(.system(size: 32))
                            .foregroundColor(.white.opacity(0.15))
                        Text("No results found")
                            .font(.system(size: 15))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    Spacer()
                } else {
                    resultsList
                }
            }
            .background(DesignSystem.bgPanel)
            .navigationBarHidden(true)
        }
    }

    // MARK: - Quick Categories

    private var quickCategories: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(QuickCategory.allCases, id: \.self) { category in
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        query = category.rawValue
                        performSearch()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: category.icon)
                                .font(.system(size: 12))
                            Text(category.rawValue)
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private enum QuickCategory: String, CaseIterable {
        case gasStation = "Gas"
        case cafe = "Coffee"
        case restaurant = "Food"
        case parking = "Parking"
        case hospital = "Hospital"
        case evCharger = "Charger"

        var icon: String {
            switch self {
            case .gasStation: return "fuelpump.fill"
            case .cafe: return "cup.and.saucer.fill"
            case .restaurant: return "fork.knife"
            case .parking: return "p.circle.fill"
            case .hospital: return "cross.fill"
            case .evCharger: return "bolt.fill"
            }
        }
    }

    // MARK: - Empty State

    private var emptySearchHint: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(.white.opacity(0.1))
            Text("Search for a place along\nyour route")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.3))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Results List

    private var resultsList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(results, id: \.self) { item in
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        onSelect(item)
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(DesignSystem.cyan)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name ?? "Unknown")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                if let addr = item.placemark.title {
                                    Text(addr)
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.4))
                                        .lineLimit(1)
                                }
                            }

                            Spacer()

                            Image(systemName: "plus.circle")
                                .font(.system(size: 20))
                                .foregroundColor(DesignSystem.cyan)
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                    }
                    .buttonStyle(.plain)

                    if item != results.last {
                        Divider()
                            .background(Color.white.opacity(0.06))
                            .padding(.leading, 48)
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private func performSearch() {
        guard !query.isEmpty else { return }
        isSearching = true

        Task {
            await driveViewModel.searchForStop(query: query)
            results = driveViewModel.addStopSearchResults
            isSearching = false
        }
    }
}
