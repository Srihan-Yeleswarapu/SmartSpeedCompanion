import SwiftUI
import SwiftData

/// List of saved speed alert profiles. Tap to activate, swipe to delete,
/// tap the edit button to customize per-road-type buffers.
public struct AlertProfilesListView: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var showingEditor = false
    @State private var profileToEdit: SpeedAlertProfile? = nil
    @State private var showingNewProfilePrompt = false
    @State private var newProfileName = ""

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                if driveViewModel.alertProfiles.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "speedometer")
                            .font(.system(size: 40))
                            .foregroundColor(DesignSystem.bgCard)
                        Text("No alert profiles yet")
                            .font(.headline)
                            .foregroundColor(.gray)
                        Text("Create a profile to customize per-road-type speed alert buffers.")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                }

                ForEach(driveViewModel.alertProfiles) { profile in
                    Button {
                        driveViewModel.activateProfile(profile.id, context: modelContext)
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

                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.white)
                                Text("Highway: +\(profile.highwayBuffer) · Residential: +\(profile.residentialBuffer) · Default: +\(profile.defaultBuffer)")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                            }

                            Spacer()

                            // Edit button
                            Button {
                                profileToEdit = profile
                                showingEditor = true
                            } label: {
                                Image(systemName: "pencil.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(DesignSystem.cyan.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        // TestFlight 29-tester feedback: "I can't delete a
                        // speed profile." The previous swipe-to-delete was
                        // hidden behind a non-discoverable gesture AND
                        // refused to delete when the user only had one
                        // profile (the ship-default state for new users).
                        // Remove the count-gate so the swipe works on day
                        // one. DriveViewModel.deleteProfile(...) now
                        // auto-seeds a fresh Default if the wipe would
                        // otherwise leave zero profiles.
                        Button(role: .destructive) {
                            driveViewModel.deleteProfile(profile.id, context: modelContext)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .listRowBackground(DesignSystem.bgPanel)
            }
            .scrollContentBackground(.hidden)
            .background(DesignSystem.bgDeep.ignoresSafeArea())
            .navigationTitle("Alert Profiles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundColor(DesignSystem.cyan)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingNewProfilePrompt = true }) {
                        Image(systemName: "plus")
                            .foregroundColor(DesignSystem.cyan)
                    }
                }
            }
            .sheet(isPresented: $showingEditor) {
                AlertProfileEditorView(profile: profileToEdit ?? driveViewModel.alertProfiles.first)
                    .environmentObject(driveViewModel)
            }
            .alert("New Profile", isPresented: $showingNewProfilePrompt) {
                TextField("Profile name", text: $newProfileName)
                Button("Cancel", role: .cancel) {
                    newProfileName = ""
                }
                Button("Create") {
                    let trimmed = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        let newProfile = driveViewModel.createNewProfile(name: trimmed, context: modelContext)
                        profileToEdit = newProfile
                        showingEditor = true
                    }
                    newProfileName = ""
                }
            } message: {
                Text("Enter a name for your new alert profile (e.g. \"Daily Commute\").")
            }
        }
        .preferredColorScheme(.dark)
    }
}
