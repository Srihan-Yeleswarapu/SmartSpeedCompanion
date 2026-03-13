import SwiftUI

public struct SettingsView: View {
    @AppStorage("userBuffer") var buffer: Double = 5
    @AppStorage("audioAlertsEnabled") var audioEnabled: Bool = true
    @AppStorage("hapticsEnabled") var hapticsEnabled: Bool = true
    @AppStorage("voiceNavEnabled") var voiceNavEnabled: Bool = true
    @AppStorage("speedUnit") var speedUnit: String = "mph"
    @AppStorage("avoidHighways") var avoidHighways: Bool = false
    
    @EnvironmentObject var driveViewModel: DriveViewModel
    
    let units = ["mph", "km/h"]
    
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
                    
                    Picker("Speed Unit", selection: $speedUnit) {
                        ForEach(units, id: \.self) {
                            Text($0)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
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
            }
            .scrollContentBackground(.hidden)
            .background(DesignSystem.bgDeep.ignoresSafeArea())
            .navigationTitle("SETTINGS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}
