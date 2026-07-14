import SwiftUI

public struct SettingsView: View {
    @AppStorage("userBuffer") var buffer: Double = 5
    @AppStorage("audioAlertsEnabled") var audioEnabled: Bool = true
    @AppStorage("voiceNavEnabled") var voiceNavEnabled: Bool = true
    @AppStorage("avoidHighways") var avoidHighways: Bool = false
    @AppStorage("measurementSystem") var measurementSystem: String = "Imperial"
    @AppStorage("gpsAccuracyMode") var gpsAccuracyMode: String = "navigation"

    // Native MapKit feature toggles (see DriveViewModel.MapStyleChoice).
    @AppStorage("mapStyle") private var mapStyle: String = "mutedDark"
    @AppStorage("showApplePOIs") private var showApplePOIs: Bool = false
    @AppStorage("lookAroundPreviewEnabled") private var lookAroundPreviewEnabled: Bool = true
    @AppStorage("gradientRouteEnabled") private var gradientRouteEnabled: Bool = true
    @AppStorage("threeDFlyoverEnabled") private var threeDFlyoverEnabled: Bool = false
    
    @EnvironmentObject var driveViewModel: DriveViewModel
    @EnvironmentObject var appState: AppState    @State private var showingTutorial = false

    // NOTE: Previously this view hosted a deletion-flow (notice alert,
    // typed-DELETE confirm, optional reauth sheet, destructive spinner
    // overlay) gated on `appState.authManager.isAuthenticated`. TestFlight
    // 2.1.4 feedback from the customer "If we don't have accounts now,
    // don't make this visible too!" + "Why is this here?!!! Remove it!"
    // asked us to drop the AUTH UI entirely. The acct-only state vars
    // (`showDeleteNotice`, `showDeleteConfirmation`, `deleteConfirmText`,
    // `showReauthSheet`, `reauthPassword`, `isDeleting`, `deleteError`)
    // are gone, and so are the matching .alert / .sheet / .overlay
    // modifiers + the reauthSheet computed var + performDelete /
    // performReauthAndDelete / runWithSpinner methods. The
    // `AuthenticationManager`, `AuthView`, `SignInView`, `SignUpView`
    // files are intentionally retained — see `AppRootView` for the
    // IAP-rollout re-surfacing plan.

    let systems = ["Imperial", "Metric"]   

    // MARK: - Apple Maps Server API token paste row state
    @State private var pasteTokenText: String = ""
    @State private var tokenSaveMessage: String? = nil

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
                
                Section(header: Text("GPS ACCURACY").font(DesignSystem.labelFont).foregroundColor(DesignSystem.cyan)) {                    // Standard Picker style resolves the "can't switch" issue in Forms
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

                // Mirror the UNITS picker into the App-Group suite so
                // WidgetKit + ActivityKit extensions (which run in their own
                // process and cannot read the main app's standard
                // UserDefaults) can render the same metric/imperial units the
                // in-app HUD shows. Without this mirror, the widget still
                // renders "Limit 65 MPH" for a metric user (TestFlight
                // 2.1.4 feedback). Using a single onChange keeps the call
                // cheap — it only fires on picker flips, not on every
                // body re-render.
                .onChange(of: measurementSystem) { _, newValue in
                    SpeedFormatting.writeMeasurementSystemToAppGroup(newValue)
                }

                // MARK: - MAP section
                // Native MapKit surface controls. Every toggle here maps to a
                // free, on-device feature — nothing here requires an Apple
                // Maps Server token.
                Section(header: Text("MAP").font(DesignSystem.labelFont).foregroundColor(DesignSystem.cyan)) {
                    Picker("Map Style", selection: $mapStyle) {
                        Text("Muted (Dark)").tag("mutedDark")
                        Text("Standard").tag("standard")
                        Text("Satellite").tag("satellite")
                        Text("Hybrid 3D").tag("hybridFlyover")
                    }

                    Toggle("Show Apple POIs (gas / food / parking)", isOn: $showApplePOIs)
                        .tint(DesignSystem.neonGreen)

                    Toggle("Look Around previews", isOn: $lookAroundPreviewEnabled)
                        .tint(DesignSystem.neonGreen)

                    Toggle("Gradient route line", isOn: $gradientRouteEnabled)
                        .tint(DesignSystem.neonGreen)

                    Toggle("3D flyover (long highways)", isOn: $threeDFlyoverEnabled)
                        .tint(DesignSystem.amber)
                }
                .listRowBackground(DesignSystem.bgPanel)

                // MARK: - Apple Maps Server API (optional)
                // The token unlocks server-side endpoints (/v1/directions,
                // /v1/search, /v1/reverseGeocode, /v1/place). Without it the
                // app uses the FREE on-device equivalents (MKDirections /
                // MKLocalSearch / CLGeocoder) and the AppleMapsServerClient
                // code is a no-op. See SmartSpeedCompanion/Core/AppleMapsServerToken.swift.
                Section(header: Text("APPLE MAPS SERVER API").font(DesignSystem.labelFont).foregroundColor(DesignSystem.amber)) {
                    tokenPasteRow

                    Text("Without a token, the app already does everything via the on-device MapKit stack. The token only unlocks server-side batch enrichment and Place ID persistence.")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .listRowBackground(DesignSystem.bgPanel)
                
                // MARK: - SUPPORT section (always visible)
                // Report Issue and Replay Tutorial are useful regardless of auth
                // state, so they're surfaced to every user.
                Section(header: Text("SUPPORT").font(DesignSystem.labelFont).foregroundColor(DesignSystem.cyan)) {
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
                }
                .listRowBackground(DesignSystem.bgPanel)

                // MARK: - ACCOUNT section removed
                // TestFlight 2.1.4 feedback from the customer explicitly
                // asked us to drop the AUTH UI ("If we don't have accounts
                // now, don't make this visible too!" + "Why is this here?!!!
                // Remove it!"). The deletion / reauth / spinner code paths
                // were removed alongside it; the `AuthenticationManager`
                // and `AuthView` files remain in the codebase for a future
                // IAP rollout that re-surfaces them per the
                // `AppRootView` comment block.
            }
            .scrollContentBackground(.hidden)
            .background(DesignSystem.bgDeep.ignoresSafeArea())
            .navigationTitle("SETTINGS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)                .fullScreenCover(isPresented: $showingTutorial) {
                    TutorialView(isReplaying: true)
                        .environmentObject(appState)
                }
                // Cold-start App-Group mirror. The picker only fires
                // `.onChange` when the user flips it; if the app ever
                // ships with Metric as the default (or the App-Group
                // suite pre-populated to Imperial), widgets would never
                // receive an update. Mirror once on first appearance so
                // cold-start cases propagate too. Cheap: a single
                // UserDefaults write.
                .task {
                    SpeedFormatting.writeMeasurementSystemToAppGroup(measurementSystem)
                }
        }
    }

    // MARK: - Apple Maps Server API: token paste row
    // Inline TextField + Save/Clear buttons for the Apple Maps Server API
    // token. The token is never logged and is stored in Keychain via
    // `AppleMapsServerToken.saveToken(_:)`.
    private var tokenPasteRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Token")
                    .foregroundColor(.white)
                Spacer()
                if AppleMapsServerToken.shared.isConfigured {
                    Text("Configured")
                        .foregroundColor(DesignSystem.neonGreen)
                        .font(.caption)
                } else {
                    Text("Not configured")
                        .foregroundColor(.gray)
                        .font(.caption)
                }
            }

            // Plain TextField (not SecureField): tokens are 200+ char JWTs
            // the user needs to eyeball to confirm the paste landed crisp.
            TextField("Paste Apple Maps Server API token", text: $pasteTokenText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white)

            HStack(spacing: 12) {
                Button(action: saveToken) {
                    Text("Save Token")
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(DesignSystem.cyan)
                        .cornerRadius(10)
                }
                .disabled(pasteTokenText.trimmingCharacters(in: .whitespacesAndNewlines).count < 16)

                if AppleMapsServerToken.shared.isConfigured {
                    Button(action: clearToken) {
                        Text("Clear")
                            .foregroundColor(DesignSystem.alertRed)
                    }
                }
                Spacer()
            }

            if let msg = tokenSaveMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(DesignSystem.neonGreen)
            }
        }
    }

    private func saveToken() {
        let trimmed = pasteTokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try AppleMapsServerToken.shared.saveToken(trimmed)
            pasteTokenText = ""
            tokenSaveMessage = "Saved to Keychain."
            // Clear the message after a few seconds so the row returns to its
            // default state without manual interaction.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                tokenSaveMessage = nil
            }
        } catch {
            tokenSaveMessage = "Failed: \(error.localizedDescription)"
        }
    }

    private func clearToken() {
        AppleMapsServerToken.shared.clearToken()
        tokenSaveMessage = "Cleared."
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            tokenSaveMessage = nil
        }
    }
}