import SwiftUI
import MapKit

/// Bottom sheet that appears when the user wants to name a location on the map.
/// Shows the address, a text field for entering a custom name, a Save button,
/// and an option to delete an existing name.
public struct NameLocationSheet: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var nameText: String = ""
    @FocusState private var isFocused: Bool
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Drag indicator
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 36, height: 5)
                    .padding(.top, 12)
                
                // Header
                VStack(spacing: 4) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(DesignSystem.cyan)
                    
                    Text("Name This Location")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                }
                
                // Address
                if let address = driveViewModel.namingAddress {
                    HStack(spacing: 8) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 12))
                            .foregroundColor(DesignSystem.cyan.opacity(0.7))
                        Text(address)
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignSystem.bgPanel)
                    .cornerRadius(12)
                }
                
                // Text field
                VStack(alignment: .leading, spacing: 6) {
                    Text("CUSTOM NAME")
                        .font(.system(size: 11, weight: .black))
                        .foregroundColor(DesignSystem.cyan)
                        .padding(.horizontal, 4)
                    
                    TextField("e.g. \"Mom's House\"", text: $nameText)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.white)
                        .focused($isFocused)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(DesignSystem.bgCard)
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(DesignSystem.cyan.opacity(0.3), lineWidth: 1)
                        )
                        .submitLabel(.done)
                        .onSubmit(saveAndDismiss)
                }
                
                // Save button
                Button(action: saveAndDismiss) {
                    Text("Save")
                        .font(.system(size: 17, weight: .black))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(nameText.trimmingCharacters(in: .whitespaces).isEmpty
                            ? DesignSystem.cyan.opacity(0.4)
                            : DesignSystem.cyan)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(nameText.trimmingCharacters(in: .whitespaces).isEmpty)
                
                // Delete button (only when editing an existing location)
                if driveViewModel.editingNamedLocation != nil {
                    Button(role: .destructive) {
                        if let existing = driveViewModel.editingNamedLocation {
                            driveViewModel.deleteNamedLocation(existing.id, context: modelContext)
                        }
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 14))
                            Text("Remove Name")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundColor(DesignSystem.alertRed)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(DesignSystem.alertRed.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(DesignSystem.alertRed.opacity(0.3), lineWidth: 1)
                        )
                    }
                }
                
                Spacer()
            }
            .padding(.horizontal, 24)
            .background(DesignSystem.bgDeep.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(DesignSystem.cyan)
                }
            }
            .onAppear {
                // Pre-fill if editing
                if let existing = driveViewModel.editingNamedLocation {
                    nameText = existing.name
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isFocused = true
                }
            }
        }
        .preferredColorScheme(.dark)
    }
    
    private func saveAndDismiss() {
        let trimmed = nameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let coord = driveViewModel.namingCoordinate else { return }
        
        if let existing = driveViewModel.editingNamedLocation {
            // Update existing
            existing.name = trimmed
            try? modelContext.save()
            if let idx = driveViewModel.namedLocations.firstIndex(where: { $0.id == existing.id }) {
                driveViewModel.namedLocations[idx] = existing
            }
        } else {
            // Create new — pass the already-resolved address to avoid a redundant geocode
            driveViewModel.saveNamedLocation(name: trimmed, coordinate: coord, context: modelContext, address: driveViewModel.namingAddress)
        }
        dismiss()
    }
}
