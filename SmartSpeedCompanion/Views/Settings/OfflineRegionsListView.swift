import SwiftUI

/// List of saved offline map regions. Tap to navigate to, swipe to delete.
public struct OfflineRegionsListView: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showSaveSheet = false
    @State private var regionName = ""

    private var saveSheetContent: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 36, height: 5)
                    .padding(.top, 12)

                VStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 32))
                        .foregroundColor(DesignSystem.cyan)
                    Text("Save Offline Region")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                }

                Text("Saves the area around your current location for offline speed limit browsing.")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 6) {
                    Text("REGION NAME")
                        .font(.system(size: 11, weight: .black))
                        .foregroundColor(DesignSystem.cyan)
                        .padding(.horizontal, 4)

                    TextField("e.g. \"Downtown\"", text: $regionName)
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

                Button(action: saveRegion) {
                    Text("Save")
                        .font(.system(size: 17, weight: .black))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(regionName.trimmingCharacters(in: .whitespaces).isEmpty
                            ? DesignSystem.cyan.opacity(0.4)
                            : DesignSystem.cyan)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(regionName.trimmingCharacters(in: .whitespaces).isEmpty)

                Spacer()
            }
            .padding(.horizontal, 24)
            .background(DesignSystem.bgDeep.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        regionName = ""
                        showSaveSheet = false
                    }
                    .foregroundColor(DesignSystem.cyan)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.height(380)])
    }

    private func saveRegion() {
        let trimmed = regionName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let coord: (lat: Double, lon: Double)
        if let loc = driveViewModel.locationManager.latestLocation {
            coord = (loc.coordinate.latitude, loc.coordinate.longitude)
        } else {
            // Fallback: use a default coordinate (e.g. Phoenix, AZ)
            coord = (33.4484, -112.0740)
        }

        driveViewModel.saveOfflineRegion(named: trimmed, centerLat: coord.lat, centerLon: coord.lon)
        regionName = ""
        showSaveSheet = false
    }

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
                        Text("Tap the + button to save your current location as an offline region.")
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
                            Text("Saved \(region.timestamp.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundColor(.gray)
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
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showSaveSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundColor(DesignSystem.cyan)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(DesignSystem.cyan)
                }
            }
            .onAppear {
                driveViewModel.loadOfflineRegions()
            }
        }
        .sheet(isPresented: $showSaveSheet) {
            saveSheetContent
        }
        .preferredColorScheme(.dark)
    }
}
