import SwiftUI

public struct SettingsView: View {
    @AppStorage("userBuffer") var buffer: Double = 5
    @AppStorage("audioAlertsEnabled") var audioEnabled: Bool = true
    @AppStorage("hapticsEnabled") var hapticsEnabled: Bool = true
    @AppStorage("voiceNavEnabled") var voiceNavEnabled: Bool = true
    @AppStorage("speedUnit") var speedUnit: String = "mph"
    @AppStorage("avoidHighways") var avoidHighways: Bool = false
    @AppStorage("measurementSystem") var measurementSystem: String = "Imperial"
    @AppStorage("gpsAccuracyMode") var gpsAccuracyMode: String = "navigation"
    
    @EnvironmentObject var driveViewModel: DriveViewModel
    @EnvironmentObject var appState: AppState
    
    @State private var showingTutorial = false
    
    let units = ["mph", "km/h"]
    let systems = ["Imperial", "Metric"]
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("ALERTS").font(DesignSystem.labelFont).foregroundColor(DesignSystem.cyan)) {
                    VStack(alignment: .leading) {
                        Text("Speed Buffer: +\(Int(buffer)) \(speedUnit)")
                            .foregroundColor(.white)
                        Slider(value: $buffer, in: 0...15, step: 1)
                            .tint(DesignSystem.amber)
                    }
                    
                    Toggle("Audio Alerts", isOn: $audioEnabled)
                        .tint(DesignSystem.neonGreen)
                    
                    Toggle("Haptic Feedback", isOn: $hapticsEnabled)
                        .tint(DesignSystem.neonGreen)
                }
                .listRowBackground(DesignSystem.bgPanel)
                
                Section(header: Text("NAVIGATION").font(DesignSystem.labelFont).foregroundColor(DesignSystem.cyan)) {
                    Toggle("Voice Navigation", isOn: $voiceNavEnabled)
                        .tint(DesignSystem.neonGreen)
                    
                    Toggle("Avoid Highways", isOn: $avoidHighways)
                        .tint(DesignSystem.neonGreen)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("SPEED UNIT")
                            .font(.caption2)
                            .foregroundColor(.gray)
                        Picker("Speed Unit", selection: $speedUnit) {
                            ForEach(units, id: \.self) { Text($0) }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                    }
                    .padding(.vertical, 4)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("DISTANCE SYSTEM")
                            .font(.caption2)
                            .foregroundColor(.gray)
                        Picker("System", selection: $measurementSystem) {
                            ForEach(systems, id: \.self) { Text($0) }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(DesignSystem.bgPanel)
                
                Section(header:
                    VStack(alignment: .leading, spacing: 2) {
                        Text("GPS ACCURACY").font(DesignSystem.labelFont).foregroundColor(DesignSystem.cyan)
                    }
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("GPS Accuracy", selection: $gpsAccuracyMode) {
                            Text("Navigation (High Accuracy)").tag("navigation")
                            Text("Balanced (Battery Saver)").tag("balanced")
                        }
                        .pickerStyle(InlinePickerStyle())
                        .onChange(of: gpsAccuracyMode) { _ in
                            driveViewModel.locationManager.applyAccuracyMode()
                        }
                        
                        Group {
                            if gpsAccuracyMode == "navigation" {
                                Text("Uses the highest GPS accuracy. Best for speed limit detection but uses more battery and may cause device warmth.")
                            } else {
                                Text("Slightly reduced GPS accuracy (~5-10m). Significantly reduces battery drain and device heat. Recommended if your phone runs hot.")
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.gray)
                    }
                }
                .listRowBackground(DesignSystem.bgPanel)
                
                Section(header: Text("DATA").font(DesignSystem.labelFont).foregroundColor(DesignSystem.cyan)) {
                    HStack {
                        Text("Speed Limits")
                            .foregroundColor(.white)
                        Spacer()
                        Text(driveViewModel.speedLimitSource)
                            .foregroundColor(DesignSystem.amber)
                            .font(.caption)
                    }
                }
                .listRowBackground(DesignSystem.bgPanel)
                
                Section(header: Text("HISTORY").font(DesignSystem.labelFont).foregroundColor(DesignSystem.cyan)) {
                    Text("Session history list goes here")
                        .foregroundColor(.gray)
                }
                .listRowBackground(DesignSystem.bgPanel)
                
                Section {
                    Button(role: .destructive) {
                        // Clear sessions logic
                    } label: {
                        HStack {
                            Spacer()
                            Text("CLEAR ALL SESSIONS")
                                .font(DesignSystem.labelFont.bold())
                            Spacer()
                        }
                    }
                }
                .listRowBackground(DesignSystem.alertRed.opacity(0.15))
                
                Section(header: Text("ACCOUNT").font(DesignSystem.labelFont).foregroundColor(DesignSystem.cyan)) {
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