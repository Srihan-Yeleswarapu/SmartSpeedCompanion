import SwiftUI
import SwiftData

/// Picker/list of vehicle profiles. Tap to switch, swipe to delete (minimum 1).
/// Up to 5 profiles.
public struct VehicleProfilePickerView: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var showingNewProfileAlert = false
    @State private var newProfileName = ""

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                if driveViewModel.vehicleProfiles.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "car.2.fill")
                            .font(.system(size: 40))
                            .foregroundColor(DesignSystem.bgCard)
                        Text("No vehicle profiles yet")
                            .font(.headline)
                            .foregroundColor(.gray)
                        Text("Create a profile for each vehicle to keep separate settings and stats.")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                }

                ForEach(driveViewModel.vehicleProfiles) { profile in
                    Button {
                        driveViewModel.activateVehicleProfile(profile.id, context: modelContext)
                        dismiss()
                    } label: {
                        HStack(spacing: 14) {
                            // Active indicator
                            if profile.isActive {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(DesignSystem.cyan)
                                    .font(.system(size: 20))
                            } else {
                                Image(systemName: "circle")
                                    .foregroundColor(.white.opacity(0.3))
                                    .font(.system(size: 20))
                            }

                            // Vehicle icon
                            let icon = VehicleIcon.icon(for: profile.vehicleIconId)
                            Image(systemName: icon.systemImageName)
                                .font(.system(size: 16))
                                .foregroundColor(DesignSystem.cyan)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.white)
                                let milesStr = String(format: "%.0f", profile.totalDistanceMiles)
                                Text("\(profile.totalTrips) trips · \(milesStr) mi")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }

                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        if driveViewModel.vehicleProfiles.count > 1 {
                            Button(role: .destructive) {
                                driveViewModel.deleteVehicleProfile(profile.id, context: modelContext)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listRowBackground(DesignSystem.bgPanel)
            }
            .scrollContentBackground(.hidden)
            .background(DesignSystem.bgDeep.ignoresSafeArea())
            .navigationTitle("Vehicle Profiles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundColor(DesignSystem.cyan)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingNewProfileAlert = true }) {
                        Image(systemName: "plus")
                            .foregroundColor(DesignSystem.cyan)
                    }
                    .disabled(driveViewModel.vehicleProfiles.count >= 5)
                }
            }
            .alert("New Vehicle", isPresented: $showingNewProfileAlert) {
                TextField("Vehicle name", text: $newProfileName)
                Button("Cancel", role: .cancel) { newProfileName = "" }
                Button("Create") {
                    let trimmed = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        driveViewModel.createVehicleProfile(name: trimmed, context: modelContext)
                    }
                    newProfileName = ""
                }
            } message: {
                Text("Enter a name for this vehicle (e.g. \"Work Truck\", \"Family SUV\"). Up to 5 profiles.")
            }
        }
        .preferredColorScheme(.dark)
    }
}
