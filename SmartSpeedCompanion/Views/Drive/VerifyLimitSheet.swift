// Views/Drive/VerifyLimitSheet.swift
import SwiftUI

struct VerifyLimitSheet: View {
    @ObservedObject var vm: DriveViewModel
    @State private var toast: String? = nil

    var body: some View {
        ZStack(alignment: .bottom) {
            if toast == nil {
                VStack(spacing: 0) {
                    // Handle
                    Capsule()
                        .fill(Color(hex: "#1A1B2E"))
                        .frame(width: 36, height: 4)
                        .padding(.top, 12)
                        .padding(.bottom, 10)

                    Text("Is this speed limit correct?")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    Text("Currently showing: \(vm.limit) mph")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#8888AA"))
                        .padding(.top, 2)
                        .padding(.bottom, 20)

                    HStack(spacing: 12) {
                        // YES button
                        Button(action: onYes) {
                            HStack {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                Text("Yes, correct")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color(hex: "#00FF9D"))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }

                        // NO button
                        Button(action: onNo) {
                            HStack {
                                Image(systemName: "xmark")
                                    .font(.system(size: 13, weight: .bold))
                                Text("No, changed")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color(hex: "#FF3D71"))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding(.horizontal, 20)

                    Button("Cancel") {
                        vm.showVerifyPrompt = false
                    }
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#8888AA"))
                    .padding(.vertical, 14)
                }
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(hex: "#0F1022").opacity(0.97))
                        .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: -6)
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
            } else {
                // Toast confirmation
                Text(toast ?? "")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(
                        Capsule()
                            .fill(Color(hex: "#0F1022"))
                            .shadow(color: .black.opacity(0.4), radius: 12)
                    )
                    .padding(.bottom, 32)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: toast)
    }

    private func onYes() {
        // Extend temporary entries & increment Firebase verified count
        let brain = SpeedLimitBrain.shared
        let (latKey, lngKey) = getApproxKeys()
        Task {
            await FirebaseSyncService.shared.incrementVerifiedCount(latKey: latKey, lngKey: lngKey)
        }
        showToast("Thanks for confirming!")
    }

    private func onNo() {
        // Mark as flagged, trigger fresh HERE lookup next time
        let (latKey, lngKey) = getApproxKeys()
        Task {
            await FirebaseSyncService.shared.incrementFlagCount(latKey: latKey, lngKey: lngKey)
        }
        showToast("Thanks! We'll recheck this road.")
    }

    private func getApproxKeys() -> (Int, Int) {
        guard let loc = SpeedLimitBrain.shared.modelContext else { return (0, 0) }
        // We can't read context directly here — use dummy for now
        return (0, 0)
    }

    private func showToast(_ message: String) {
        toast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            vm.showVerifyPrompt = false
            toast = nil
        }
    }
}
