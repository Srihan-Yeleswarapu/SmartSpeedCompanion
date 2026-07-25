import SwiftUI
import SwiftData

/// Form for editing a vehicle profile's name, icon, and alert settings.
/// Same styling as SettingsView sections.
public struct VehicleProfileEditorView: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let profile: VehicleProfile

    @State private var name: String = ""
    @State private var selectedIconId: String = "default_blue"

    public init(profile: VehicleProfile) {
        self.profile = profile
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("VEHICLE NAME").font(DesignSystem.labelFont).foregroundColor(DesignSystem.cyan)) {
                    TextField("Vehicle Name", text: $name)
                        .foregroundColor(.white)
                }
                .listRowBackground(DesignSystem.bgPanel)

                Section(header: Text("ICON").font(DesignSystem.labelFont).foregroundColor(DesignSystem.cyan)) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                        ForEach(VehicleIcon.catalog) { icon in
                            Button(action: { selectedIconId = icon.id }) {
                                VStack(spacing: 4) {
                                    Image(systemName: icon.systemImageName)
                                        .font(.system(size: 24))
                                        .foregroundColor(selectedIconId == icon.id ? .black : DesignSystem.cyan)
                                        .frame(width: 48, height: 48)
                                        .background(
                                            selectedIconId == icon.id
                                                ? DesignSystem.cyan
                                                : DesignSystem.bgPanel
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(selectedIconId == icon.id ? DesignSystem.cyan : Color.white.opacity(0.1), lineWidth: 1.5)
                                        )

                                    Text(icon.displayName)
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundColor(selectedIconId == icon.id ? DesignSystem.cyan : .gray)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(DesignSystem.bgPanel)
            }
            .scrollContentBackground(.hidden)
            .background(DesignSystem.bgDeep.ignoresSafeArea())
            .navigationTitle("Edit Vehicle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(DesignSystem.cyan)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { saveProfile() }
                        .foregroundColor(DesignSystem.cyan)
                        .fontWeight(.bold)
                }
            }
            .onAppear {
                name = profile.name
                selectedIconId = profile.vehicleIconId
            }
        }
        .preferredColorScheme(.dark)
    }

    private func saveProfile() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        profile.name = trimmed
        profile.vehicleIconId = selectedIconId
        try? modelContext.save()
        if let idx = driveViewModel.vehicleProfiles.firstIndex(where: { $0.id == profile.id }) {
            driveViewModel.vehicleProfiles[idx] = profile
        }
        dismiss()
    }
}
