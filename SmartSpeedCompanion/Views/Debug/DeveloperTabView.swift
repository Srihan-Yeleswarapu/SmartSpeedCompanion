import SwiftUI

#if DEBUG || DEVELOPER_BUILD
public struct DeveloperTabView: View {
    @StateObject private var logger = DebugLogger.shared
    @State private var autoScroll = true

    // MARK: - Geoapify API key state (DEBUG-only, opt-in network geocoder)
    @State private var geoapifyKeyDraft: String = ""
    @State private var geoapifyKeySavedAt: Date? = nil

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // DRIVER SIMULATOR REGION
                DeveloperSimulatorView(locationManager: AppDelegate.sharedDriveViewModel.locationManager)
                    .padding()
                    .background(DesignSystem.bgDeep)

                // GEOAPIFY API KEY row. Lets the developer paste their free-
                // tier key without leaving the app; persisted in Keychain via
                // `GeoapifyCredentialStore.saveApiKey(...)`. Silently disabled
                // for builds where no key is set — network fallback cost is
                // then zero and `RoadGeocoder` stays on the CLGeocoder chain.
                geoapifyKeyRow
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .background(DesignSystem.bgDeep)

                Divider()
                    .overlay(DesignSystem.cyan.opacity(0.1))

                ScrollViewReader { proxy in
                    List(logger.logs) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.formattedTimestamp)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(DesignSystem.cyan)
                                
                                Spacer()
                            }
                            
                            Text(entry.message)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        .padding(.vertical, 4)
                        .id(entry.id)
                    }
                    .listStyle(.plain)
                    .onChange(of: logger.logs.count) { _, _ in
                        if autoScroll, let last = logger.logs.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
                
                Divider()
                
                HStack {
                    Toggle("Auto-scroll", isOn: $autoScroll)
                        .font(.caption)
                    
                    Spacer()
                    
                    Text("\(logger.logs.count) entries")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                .padding()
                .background(DesignSystem.bgDeep)
            }
            .navigationTitle("DEVELOPER LOGS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 20) {
                        Button(action: {
                            let allLogs = logger.logs.map { "[\($0.formattedTimestamp)] \($0.message)" }.joined(separator: "\n")
                            UIPasteboard.general.string = allLogs
                            // Subtly log the action
                            DebugLogger.shared.log("COPIED: All logs copied to clipboard.")
                        }) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(DesignSystem.cyan)
                        }
                        
                        Button("Clear") {
                            logger.clear()
                        }
                        .foregroundColor(DesignSystem.alertRed)
                    }                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        Task { @MainActor in
                            let vm = AppDelegate.sharedDriveViewModel
                            guard let loc = vm.locationManager.latestLocation else {
                                DebugLogger.shared.log("Manual Fetch: No current location")
                                return
                            }

                            DebugLogger.shared.log("Manual Fetch: Triggered at \(loc.coordinate.latitude), \(loc.coordinate.longitude)")

                            let isMetric = UserDefaults.standard.string(forKey: "measurementSystem") == "Metric"
                            let conversionFactor = isMetric ? 3.6 : 2.23694
                            let currentSpeed = max(0, loc.speed * conversionFactor)
                            let currentSpeedMph = isMetric ? currentSpeed * 0.621371 : currentSpeed
                            let carHeading = loc.course >= 0 ? loc.course : nil
                            let ident = await RoadGeocoder.shared.resolveRoadContext(at: loc.coordinate)

                            _ = await SmartSpeedLimitService.shared.updateSpeedLimit(
                                at: loc.coordinate,
                                heading: carHeading,
                                currentSpeedMph: currentSpeedMph,
                                roadName: ident?.roadName
                            )
                        }
                    }) {
                        Image(systemName: "play.circle.fill")
                    }
                }
            }
            .background(DesignSystem.bgDeep.ignoresSafeArea())
        }
    }

    // MARK: - Geoapify API key row
    // Standalone computed view so the body stays readable. The TextField is
    // plain (not Secure) so the developer can verify a clean paste of their
    // key; keys are not high-secrecy for free-tier Geoapify.
    private var geoapifyKeyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Geoapify API key (network fallback for RoadGeocoder)")
                    .font(.caption)
                    .foregroundColor(.gray)
                Spacer()
                if GeoapifyCredentialStore.shared.hasApiKey() {
                    Text("Configured")
                        .foregroundColor(DesignSystem.neonGreen)
                        .font(.caption2)
                } else {
                    Text("Not configured")
                        .foregroundColor(.gray)
                        .font(.caption2)
                }
            }
            HStack {
                TextField("Paste key from myprojects.geoapify.com", text: $geoapifyKeyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white)
                Button("Save") {
                    GeoapifyCredentialStore.shared.saveApiKey(geoapifyKeyDraft)
                    geoapifyKeyDraft = ""
                    geoapifyKeySavedAt = Date()
                    DebugLogger.shared.log("Geoapify key saved (length=\(GeoapifyCredentialStore.shared.loadApiKey()?.count ?? 0))")
                }
                .disabled(geoapifyKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).count < 16)
                if GeoapifyCredentialStore.shared.hasApiKey() {
                    Button("Clear") {
                        GeoapifyCredentialStore.shared.clearApiKey()
                        DebugLogger.shared.log("Geoapify key cleared")
                    }
                    .foregroundColor(DesignSystem.alertRed)
                }
            }
        }
    }
}
#endif