import SwiftUI

/// Bottom sheet with a grid of vehicle icons the user can select to replace the
/// default blue dot on the map. Follows the same styling as other sheets in the app.
public struct VehicleIconPickerSheet: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    @Environment(\.dismiss) private var dismiss
    
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Drag indicator
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 36, height: 5)
                    .padding(.top, 12)
                
                // Header
                VStack(spacing: 4) {
                    Image(systemName: "car.side.fill")
                        .font(.system(size: 28))
                        .foregroundColor(DesignSystem.cyan)
                    
                    Text("Vehicle Icon")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                    
                    Text("Pick an icon for your position on the map")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.5))
                }
                
                // Icon grid
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(VehicleIcon.catalog) { icon in
                            Button(action: {
                                driveViewModel.selectedVehicleIconId = icon.id
                                dismiss()
                            }) {
                                VStack(spacing: 8) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 14)
                                            .fill(driveViewModel.selectedVehicleIconId == icon.id
                                                ? DesignSystem.cyan.opacity(0.15)
                                                : DesignSystem.bgCard)
                                            .frame(height: 72)
                                        
                                        RoundedRectangle(cornerRadius: 14)
                                            .stroke(driveViewModel.selectedVehicleIconId == icon.id
                                                ? DesignSystem.cyan
                                                : Color.white.opacity(0.08),
                                                lineWidth: driveViewModel.selectedVehicleIconId == icon.id ? 2 : 1)
                                        
                                        Image(systemName: icon.systemImageName)
                                            .font(.system(size: 28))
                                            .foregroundColor(driveViewModel.selectedVehicleIconId == icon.id
                                                ? DesignSystem.cyan
                                                : .white.opacity(0.8))
                                    }
                                    
                                    Text(icon.displayName)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.7))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 4)
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
}
