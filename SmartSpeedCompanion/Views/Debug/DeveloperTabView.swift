import SwiftUI

#if DEVELOPER_BUILD
public struct DeveloperTabView: View {
    @StateObject private var logger = DebugLogger.shared
    @State private var autoScroll = true
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
                    }
                }
                
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
                            
                            _ = await SmartSpeedLimitService.shared.updateSpeedLimit(
                                at: loc.coordinate,
                                heading: carHeading,
                                currentSpeedMph: currentSpeedMph
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
}
#endif