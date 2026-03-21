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
                        let urlStr = "mailto:\(email)?subject=SpeedSense%20Issue%20Report"
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
                }
                .listRowBackground(DesignSystem.bgPanel)
            }
            .scrollContentBackground(.hidden)
            .background(DesignSystem.bgDeep.ignoresSafeArea())
            .navigationTitle("SETTINGS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .fullScreenCover(isPresented: $showingTutorial) {
                TutorialView(isReplaying: true)
                    .environmentObject(appState)
            }
        }
    }
}