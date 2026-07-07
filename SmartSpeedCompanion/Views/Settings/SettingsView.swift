import SwiftUI

public struct SettingsView: View {
    @AppStorage("userBuffer") var buffer: Double = 5
    @AppStorage("audioAlertsEnabled") var audioEnabled: Bool = true
    @AppStorage("voiceNavEnabled") var voiceNavEnabled: Bool = true
    @AppStorage("avoidHighways") var avoidHighways: Bool = false
    @AppStorage("measurementSystem") var measurementSystem: String = "Imperial"
    @AppStorage("gpsAccuracyMode") var gpsAccuracyMode: String = "navigation"
    
    @EnvironmentObject var driveViewModel: DriveViewModel
    @EnvironmentObject var appState: AppState
    
    @State private var showingTutorial = false

    // MARK: - Delete Account Flow State
    // Three-step confirmation gated by these flag booleans: (1) notice alert,
    // (2) typed-DELETE confirmation alert, (3) optional reauth sheet that surfaces
    // only when Firebase rejects `currentUser.delete()` with `requiresRecentLogin`.
    @State private var showDeleteNotice: Bool = false
    @State private var showDeleteConfirmation: Bool = false
    @State private var deleteConfirmText: String = ""
    @State private var showReauthSheet: Bool = false
    @State private var reauthPassword: String = ""
    @State private var isDeleting: Bool = false
    @State private var deleteError: String? = nil

    let systems = ["Imperial", "Metric"]
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("ALERTS").font(DesignSystem.labelFont).foregroundColor(DesignSystem.cyan)) {
                    VStack(alignment: .leading) {
                        let unitLabel = measurementSystem == "Imperial" ? "mph" : "km/h"
                        Text("Speed Buffer: +\(Int(buffer)) \(unitLabel)")
                            .foregroundColor(.white)
                        Slider(value: $buffer, in: 0...15, step: 1)
                            .tint(DesignSystem.amber)
                    }
                    
                    Toggle("Audio Alerts", isOn: $audioEnabled)
                        .tint(DesignSystem.neonGreen)
                }
                .listRowBackground(DesignSystem.bgPanel)
                
                Section(header: Text("NAVIGATION").font(DesignSystem.labelFont).foregroundColor(DesignSystem.cyan)) {
                    Toggle("Voice Navigation", isOn: $voiceNavEnabled)
                        .tint(DesignSystem.neonGreen)
                    
                    Toggle("Avoid Highways", isOn: $avoidHighways)
                        .tint(DesignSystem.neonGreen)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("UNITS")
                            .font(.caption2)
                            .foregroundColor(.gray)
                        Picker("Units", selection: $measurementSystem) {
                            ForEach(systems, id: \.self) { Text($0) }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(DesignSystem.bgPanel)
                
                Section(header: Text("GPS ACCURACY").font(DesignSystem.labelFont).foregroundColor(DesignSystem.cyan)) {
                    // Standard Picker style resolves the "can't switch" issue in Forms
                    Picker("Accuracy Mode", selection: $gpsAccuracyMode) {
                        Text("Navigation (High)").tag("navigation")
                        Text("Balanced (Battery Saver)").tag("balanced")
                    }
                    .onChange(of: gpsAccuracyMode) { oldValue, newValue in
                        driveViewModel.locationManager.applyAccuracyMode()
                    }
                    
                    Text(gpsAccuracyMode == "navigation" ? 
                         "Uses the highest GPS accuracy. Best for speed limit detection." : 
                         "Reduced GPS accuracy (~5-10m). Significantly reduces battery drain.")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .listRowBackground(DesignSystem.bgPanel)
                
                Section(header: Text("ACCOUNT").font(DesignSystem.labelFont).foregroundColor(DesignSystem.cyan)) {
                    Button(action: {
                        let email = "speedsenseapp@gmail.com"
                        let urlStr = "mailto:\(email)?subject=Speedio%20Issue%20Report"
                        if let url = URL(string: urlStr) {
                             UIApplication.shared.open(url)
                        }
                    }) {
                        Text("Report Issue")
                            .foregroundColor(.white)
                    }
                    
                    Button(action: {
                        showingTutorial = true
                    }) {
                        Text("Replay Tutorial")
                            .foregroundColor(.white)
                    }
                    
                    Button(action: {
                        appState.authManager.signOut()
                    }) {
                        Text("Sign Out")
                            .foregroundColor(DesignSystem.alertRed)
                    }

                    // MARK: Delete Account — Apple App Store Guideline 5.1.1(v).
                    // The two-stage confirmation is intentionally hard to trigger
                    // by accident: first an alert listing what gets erased, then a
                    // second alert requiring the user to literally type "DELETE".
                    Button(action: {
                        deleteConfirmText = ""
                        reauthPassword = ""
                        showDeleteNotice = true
                    }) {
                        Text("Delete Account")
                            .foregroundColor(DesignSystem.alertRed)
                    }
                    .disabled(isDeleting)
                }
                .listRowBackground(DesignSystem.bgPanel)
            }
            .scrollContentBackground(.hidden)
            .background(DesignSystem.bgDeep.ignoresSafeArea())
            .navigationTitle("SETTINGS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            // Animate the spinner overlay's appearance with `isDeleting` so
            // the `.transition(.opacity)` modifier on the overlay has something
            // to interpolate against. Without this the overlay pops in/out.
            .animation(.easeInOut(duration: 0.2), value: isDeleting)
            .fullScreenCover(isPresented: $showingTutorial) {
                TutorialView(isReplaying: true)
                    .environmentObject(appState)
            }
            .disabled(isDeleting)
            // MARK: Delete-account alerts
            // Step 1: the "are you sure?" notice. Advances to a typed-DELETE dialog
            // only if the user explicitly taps the destructive role button.
            .alert("Delete your Speedio account?", isPresented: $showDeleteNotice) {
                Button("Continue\u{2026}", role: .destructive) {
                    showDeleteConfirmation = true
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This permanently deletes your account, all cloud data, all recorded drives (cloud and on-device), and your settings. This cannot be undone.")
            }
            // Step 2: typed-DELETE confirmation. The button is enabled on every tap;
            // we only fire `performDelete()` when the trimmed text matches "DELETE"
            // exactly, so a typo just dismisses the alert cleanly.
            .alert("Type DELETE to confirm", isPresented: $showDeleteConfirmation) {
                TextField("Type DELETE here", text: $deleteConfirmText)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled(true)
                Button("Delete Account", role: .destructive) {
                    // Normalize: trim whitespace and uppercase so users can paste
                    // "delete" or "Delete" or " DELETE " without a brick wall.
                    let normalized = deleteConfirmText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .uppercased()
                    if normalized == "DELETE" {
                        Task { await performDelete() }
                    }
                    deleteConfirmText = ""
                }
                Button("Cancel", role: .cancel) {
                    deleteConfirmText = ""
                }
            } message: {
                Text("This is permanent. Type DELETE in capital letters to confirm.")
            }
            // Reauth sheet — only surfaces if `deleteAccount()` throws
            // `AuthError.requiresRecentLogin`. Apple Guideline 5.1.1(v) requires
            // this flow to live entirely inside the app (no mailto bounce).
            .sheet(isPresented: $showReauthSheet) {
                reauthSheet
                    .presentationDetents([.medium])
            }
            // Final-stage completion/error surface. `deleteError` is a String?,
            // so we use a binding adapter to map it onto Alert's isPresented
            // parameter (clearing it on dismiss).
            .alert(
                "Account deletion",
                isPresented: Binding(
                    get: { deleteError != nil },
                    set: { if !$0 { deleteError = nil } }
                ),
                actions: {
                    Button("OK", role: .cancel) { deleteError = nil }
                },
                message: {
                    Text(deleteError ?? "")
                }
            )
            // Spinner overlay while the deletion/reauth round-trip is in flight.
            .overlay {
                if isDeleting {
                    ZStack {
                        Color.black.opacity(0.4).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                                .scaleEffect(1.4)
                            Text("Deleting account\u{2026}")
                                .font(.callout)
                                .foregroundColor(.white)
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    // MARK: - Reauth Sheet
    // Standalone view so the .sheet modifier above stays readable. Shows the
    // user's email pre-filled (read-only), a SecureField for the password,
    // and a destructive finalize button. The email is taken from the published
    // `currentUserEmail` so we don't risk stale state.
    private var reauthSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Text("For security, please sign in again to confirm account deletion.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Section("Confirm Sign In") {
                    HStack {
                        Text("Email")
                            .foregroundColor(.gray)
                        Spacer()
                        Text(appState.authManager.currentUserEmail ?? "\u{2014}")
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    SecureField("Password", text: $reauthPassword)
                }
                Section {
                    Button(action: {
                        Task { await performReauthAndDelete() }
                    }) {
                        HStack {
                            if isDeleting {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(.white)
                            } else {
                                Text("Delete my account")
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 4)
                            }
                        }
                    }
                    .listRowBackground(DesignSystem.alertRed)
                    .disabled(reauthPassword.isEmpty || isDeleting
                              || (appState.authManager.currentUserEmail ?? "").isEmpty)
                }
            }
            .navigationTitle("Confirm Deletion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showReauthSheet = false
                        reauthPassword = ""
                    }
                }
            }
        }
    }

    // MARK: - Actions

    /// Primary deletion action launched from the typed-DELETE alert.
    /// If Firebase throws `requiresRecentLogin`, we keep the UI mounted and
    /// present the reauth sheet instead of bubbling the error up as a generic
    /// message \u2014 Apple Guideline 5.1.1(v) requires the user to be able to
    /// complete the deletion entirely in-app.
    private func performDelete() async {
        await runWithSpinner {
            do {
                try await appState.authManager.deleteAccount()
            } catch AuthError.requiresRecentLogin {
                showReauthSheet = true
            } catch {
                deleteError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    /// Reauth + delete path used from the reauth sheet after the user
    /// re-enters their password.
    private func performReauthAndDelete() async {
        let email = appState.authManager.currentUserEmail ?? ""
        let password = reauthPassword
        await runWithSpinner {
            do {
                try await appState.authManager.reauthenticateAndDeleteAccount(
                    email: email,
                    password: password
                )
                showReauthSheet = false
                reauthPassword = ""
            } catch {
                deleteError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                // Keep the reauth sheet open on failure (wrong password,
                // network blip) so the user can retry without bouncing out.
                // The success path above already closes the sheet.
                showReauthSheet = true
            }
        }
    }

    /// Wraps a deletion-task in the `isDeleting` flag so the spinner overlay
    /// and `.disabled(isDeleting)` modifier on the form both reflect state.
    @MainActor
    private func runWithSpinner(_ work: @escaping () async -> Void) async {
        isDeleting = true
        defer { isDeleting = false }
        await work()
    }
}