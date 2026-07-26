import SwiftUI

public struct SettingsView: View {
    @AppStorage("userBuffer") var buffer: Double = 5
    @AppStorage("audioAlertsEnabled") var audioEnabled: Bool = true
    // Haptic alert preferences live alongside audio so the two toggles stay
    // visually coupled when the user opens Settings → ALERTS. The style is
    // persisted as a HapticStyle raw string and translated to the enum
    // (see HapticAlertManager.swift) at read time.
    @AppStorage("hapticAlertsEnabled") var hapticEnabled: Bool = true
    @AppStorage("hapticAlertStyle") private var hapticStyle: String = "strong"
    @AppStorage("hapticCustomPattern") private var hapticCustomPatternData: Data = Data()
    @AppStorage("voiceNavEnabled") var voiceNavEnabled: Bool = true
    @AppStorage("avoidHighways") var avoidHighways: Bool = false
    @AppStorage("measurementSystem") var measurementSystem: String = "Imperial"
    @AppStorage("gpsAccuracyMode") var gpsAccuracyMode: String = "navigation"

    // ── Fuel Estimator Settings ─────────────────────────────────
    @AppStorage("vehicleFuelEfficiency") var vehicleFuelEfficiency: Double = 25.0
    @AppStorage("vehicleFuelUnit") var vehicleFuelUnit: String = "MPG"
    @AppStorage("localFuelPrice") var localFuelPrice: Double = 3.50

    // NOTE: above fuel @AppStorage values were previously used by the
    // VEHICLE Settings section (FB26) and the FuelCostCard in the
    // analytics dashboard. Both surfaces were removed per direct
    // TestFlight feedback. The keys remain as write-only UserDefaults
    // values for future ad-gated/IAP mileage-estimator work (see
    // Core/FuelEstimator.swift banner) — they are read by no current
    // View so clearing them on launch would only surprise the user.

    // Native MapKit surface toggles — no server-side dependencies.
    @AppStorage("mapStyle") private var mapStyle: String = "mutedDark"
    @AppStorage("showApplePOIs") private var showApplePOIs: Bool = false
    @AppStorage("gradientRouteEnabled") private var gradientRouteEnabled: Bool = true
    // NB: the "3D flyover (long highways)" toggle was retired in 2.2.x — the
    // flyover camera is now baked into LiveMapView as default behavior so it
    // only ever fires when the user is on a long, straight highway stretch at
    // speed with no turn coming up (the conditions where flyover looks good).

    @EnvironmentObject var driveViewModel: DriveViewModel
    @EnvironmentObject var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @State private var showingTutorial = false
    // TestFlight 2.1.4 feedback from
    // srihan.yeleswarapu@gmail.com: "And put a how to button. Then put
    // detailed instructions on how to toggle an app to use cellular,
    // and basically like how to debug it to get cellular data to fetch
    // data." Toggled by the new NETWORK & DATA row below.
    @State private var showingNetworkHelp = false
    @State private var showingHapticRecorder = false
    @State private var showingAlertProfiles = false

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

    // (TestFlight 2.2.0+ feedback: "remove the Apple Maps Server API
    // token paste section from Settings." The state vars +
    // tokenPasteRow row + saveToken/clearToken helpers were deleted
    // alongside the section. `Core/AppleMapsServerClient.swift` and
    // `Core/AppleMapsServerToken.swift` remain on disk but are not
    // invoked at runtime — kept for a future rollout, see those
    // files' top-of-file banners before any reuse.)

    public init() {}
    
    public var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("ALERTS").font(DesignSystem.labelFont).foregroundColor(DesignSystem.cyan)) {
                    // Speed Buffer Profiles row — first item in ALERTS
                    Button(action: { showingAlertProfiles = true }) {
                        HStack(spacing: 10) {
                            Image(systemName: "slider.horizontal.3")
                                .foregroundColor(DesignSystem.cyan)
                                .frame(width: 20)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Speed Buffer Profiles")
                                    .foregroundColor(.white)
                                let activeName = driveViewModel.alertProfiles.first(where: { $0.isActive })?.name ?? "Default"
                                Text("Active: \(activeName)")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.white.opacity(0.4))
                                .font(.caption.weight(.semibold))
                        }
                    }

                    Toggle("Audio Alerts", isOn: $audioEnabled)
                        .tint(DesignSystem.neonGreen)

                    // TestFlight v2.2.0 (b365) — srihan.yeleswarapu@gmail.com:
                    // "Maybe right below audio alerts toggle, put haptic alerts
                    // selection bar. U should be able to select what type of
                    // vibration haptic you want when your speeding. You should
                    // also be able to record your own haptic..."
                    Toggle("Haptic Alerts", isOn: $hapticEnabled)
                        .tint(DesignSystem.neonGreen)

                    // Only show the haptic catalog when (a) the master toggle is
                    // on AND (b) the device actually has a taptic engine.
                    // iPads ship without Core Haptics hardware; on those the
                    // Haptic Alerts toggle still appears so the user can
                    // pre-stage their setting for a future iPhone, but the
                    // catalog stays hidden.
                    if hapticEnabled && HapticAlertManager.shared.deviceSupportsHaptics {
                        // Spec: changing the picker should play the chosen
                        // style so the user can audition it without waiting
                        // for a speeding alert (TestFlight v2.2.0 b366
                        // feedback). `previewCurrentStyle()` is gated to
                        // stay silent on `.off`, throttle to ≥400 ms, and
                        // bypass the master `isEnabled` toggle (Settings
                        // preview is always-on regardless of muted alerts).
                        Picker("Haptic Style", selection: Binding<HapticStyle>(
                            get: { HapticStyle(rawValue: hapticStyle) ?? .strong },
                            set: { hapticStyle = $0.rawValue }
                        )) {
                            ForEach(HapticStyle.allCases, id: \.self) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        .tint(DesignSystem.cyan)
                        // Hook the underlying @AppStorage-backed String
                        // (rather than the bind's `.set:`) because SwiftUI's
                        // `Picker` re-evaluates the bind on every render and
                        // would otherwise fire preview patterns unrelated to
                        // the user's tap. `onChange` of the storage key
                        // only fires on real selection events.
                        .onChange(of: hapticStyle) { _, _ in
                            HapticAlertManager.shared.previewCurrentStyle()
                        }

                        if HapticStyle(rawValue: hapticStyle) == .custom {
                            Button(action: { showingHapticRecorder = true }) {
                                HStack(spacing: 10) {
                                    Image(systemName: "hand.tap.fill")
                                    Text("Record Custom Haptic…")
                                }
                                .foregroundColor(DesignSystem.cyan)
                            }
                        }
                    }
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
                // Native MapKit surface controls — no server-side dependencies.
                Section(header: Text("MAP").font(DesignSystem.labelFont).foregroundColor(DesignSystem.cyan)) {
                    Picker("Map Style", selection: $mapStyle) {
                        Text("Muted (Dark)").tag("mutedDark")
                        Text("Standard").tag("standard")
                        Text("Satellite").tag("satellite")
                        Text("Hybrid 3D").tag("hybridFlyover")
                    }

                    Toggle("Show Apple POIs (gas / food / parking)", isOn: $showApplePOIs)
                        .tint(DesignSystem.neonGreen)

                    // TestFlight 2.2.0 (FB10): "Look Around previews"
                    // toggle removed per user request.

                    Toggle("Gradient route line", isOn: $gradientRouteEnabled)
                        .tint(DesignSystem.neonGreen)

                    // "3D flyover (long highways)" toggle removed in 2.2.x —
                    // flyover camera is now baked-in default behavior
                    // (see LiveMapView.updateSmartAltitude).
                }
                .listRowBackground(DesignSystem.bgPanel)

                // MARK: - VEHICLE / fuel-efficiency section removed
                // TestFlight FB26: "You put fuel efficiency and fuel price
                // options here. Can you remove this feature? I don't like
                // this." Removed per direct user request. The
                // `vehicleFuelEfficiency` / `vehicleFuelUnit` /
                // `localFuelPrice` @AppStorage values are intentionally
                // RETAINED so existing consumers (e.g. the historical
                // analytics `FuelCostCard` which has now also been removed
                // from `AnalyticsDashboardView`) compile silently; future
                // mileage estimator work can read them from UserDefaults
                // without forcing a schema migration. The companion
                // `Core/FuelEstimator.swift` is kept on disk for the same
                // reason — see its banner before any reuse.
                //
                // (Historical context: `Core/FuelEstimator.swift` and the
                //  VEHICLE section were originally added so the analytics
                //  dashboard could estimate per-trip fuel cost/CO2.
                //  Direct user request removes both surfaces; the
                //  underlying math is preserved in case we re-surface the
                //  feature under the ad-gated-or-IAP model.)
                
                // MARK: - NETWORK & DATA section (always visible)
                // Driving the speed-limit pipeline requires EITHER live
                // network (ArcGIS HPMS + OSM Overpass) OR local coverage
                // in the Arizona SQLite. Help the user unblock cellular
                // so live providers can come back online when they do
                // return to service.
                // (TestFlight 2.1.4: "put a how to button… detailed
                //  instructions on how to toggle an app to use cellular".)
                Section(header: Text("NETWORK & DATA").font(DesignSystem.labelFont).foregroundColor(DesignSystem.cyan)) {
                    Button(action: {
                        showingNetworkHelp = true
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                                .foregroundColor(DesignSystem.cyan)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Can't load live speed limits?")
                                    .foregroundColor(.white)
                                Text("How to enable Cellular Data for Speedio")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.white.opacity(0.4))
                                .font(.caption.weight(.semibold))
                        }
                    }
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
                // Cellular data troubleshooting sheet. Distinct from the
                // full-screen Tutorial because the user wants a quick
                // reference they can read while sitting next to the
                // iPhone Settings app. Opens a system Settings deep-link
                // from a button so they don't have to navigate manually.
                .sheet(isPresented: $showingNetworkHelp) {
                    NetworkHelpSheet()
                }
                .sheet(isPresented: $showingAlertProfiles) {
                    AlertProfilesListView()
                        .environmentObject(driveViewModel)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                        .presentationCornerRadius(24)
                        .preferredColorScheme(.dark)
                }
                // Full-screen tap-to-record modal for the “Custom” haptic.
                // Implemented in HapticRecordingView.swift.
                .fullScreenCover(isPresented: $showingHapticRecorder) {
                    HapticRecordingView()
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
                .onAppear {
                    driveViewModel.loadAlertProfiles(context: modelContext)
                }
        }
    }

}

// MARK: - Network Help Sheet
//
// TestFlight 2.1.4 feedback: "Also if the user has no wifi, show an
// alert saying please turn on WiFi or cellular data. And put a how
// to button. Then put detailed instructions on how to toggle an app
// to use cellular, and basically like how to debug it to get cellular
// data to fetch data."
//
// Sheet (not alert) because users want to compare the instructions
// against the actual iPhone Settings screens they're looking at —
// an alert is too small / dismisses too easily. Includes a deep link
// to the system Settings app so the user can tap once and land on
// the relevant page.
fileprivate struct NetworkHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header

                    enableStepsSection
                    debugTipsSection
                    settingsDeepLinkButton
                }
                .padding(20)
            }
            .background(DesignSystem.bgDeep.ignoresSafeArea())
            .navigationTitle("Network Troubleshooting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(DesignSystem.cyan)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(DesignSystem.amber)
                Text("Live speed limits need a network path")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
            }
            Text("Speedio grabs fresh speed-limit data from Apple/ArcGIS and OpenStreetMap. If Wi-Fi and Cellular Data are both off — or if Speedio's per-app toggle is off — the app will fall back to a small local Arizona database and you may see stale or missing limits.")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var enableStepsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("HOW TO ENABLE CELLULAR DATA FOR SPEEDIO",
                  systemImage: "1.circle.fill")
                .font(.system(size: 12, weight: .black))
                .foregroundColor(DesignSystem.cyan)
            stepRow(num: "1", text: "Open the **iPhone Settings** app.")
            stepRow(num: "2", text: "Tap **Cellular** (called *Mobile Data* on UK/AU devices).")
            stepRow(num: "3", text: "Make sure **Cellular Data** at the top is **ON** (green).")
            stepRow(num: "4", text: "Scroll down to the **Speedio** entry and toggle it **ON**.")
            stepRow(num: "5", text: "If you only use Wi-Fi, scroll to **Wi-Fi** instead and ensure Speedio is allowed.")
        }
    }

    private var debugTipsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("DEBUGGING TIPS",
                  systemImage: "stethoscope")
                .font(.system(size: 12, weight: .black))
                .foregroundColor(DesignSystem.cyan)
            tipRow(text: "Turn **Airplane Mode** OFF (orange crescent icon in Control Center).")
            tipRow(text: "Disable **Low Power Mode** — it throttles background fetches and may delay live results.")
            tipRow(text: "If you use a **VPN** or firewall app, allowlist Speedio so requests aren't blocked.")
            tipRow(text: "Try opening **maps.apple.com** in Safari to confirm your cellular data path works end-to-end.")
            tipRow(text: "If you still see a red **OFFLINE** banner in the app but Safari works, please report an issue from the SUPPORT section.")
        }
    }

    private var settingsDeepLinkButton: some View {
        Button(action: openIPhoneSettings) {
            HStack(spacing: 10) {
                Image(systemName: "gear")
                    .font(.system(size: 15, weight: .bold))
                Text("Open iPhone Settings")
                    .font(.system(size: 15, weight: .bold))
            }
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(DesignSystem.cyan)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: DesignSystem.cyan.opacity(0.4), radius: 8, y: 3)
        }
        .padding(.top, 6)
    }

    private func stepRow(num: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(num)
                .font(.system(size: 14, weight: .black, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(DesignSystem.cyan)
                .clipShape(Circle())
            // Use LocalizedStringKey so the `**bold**` markers in our
            // step text get parsed by SwiftUI's Markdown renderer. The
            // previous `Text(.init(text))` dispatched to the plain-String
            // init, which renders asterisks verbatim — visible as literal
            // stars in the live TestFlight build (code-review of e70991c
            // flagged this).
            Text(LocalizedStringKey(text))
                .font(.system(size: 14))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func tipRow(text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(DesignSystem.neonGreen)
                .font(.system(size: 14, weight: .bold))
            // Markdown turn–on via LocalizedStringKey (same reasoning as
            // stepRow above).
            Text(LocalizedStringKey(text))
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func openIPhoneSettings() {
        // UIApplication.openSettingsURLString is the Apple-blessed way to
        // jump from our app's Settings screen straight into the system
        // Settings app. iOS handles the route: Cellular / Wi-Fi / General
        // are all top-level pages the user can navigate from.
        if let url = URL(string: UIApplication.openSettingsURLString),
           UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }
}