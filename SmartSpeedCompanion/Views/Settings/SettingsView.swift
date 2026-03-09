import SwiftUI

public struct SettingsView: View {
    @AppStorage("userBuffer") var buffer: Double = 5
    @AppStorage("audioAlertsEnabled") var audioEnabled: Bool = true
    @AppStorage("hapticsEnabled") var hapticsEnabled: Bool = true
    @AppStorage("voiceNavEnabled") var voiceNavEnabled: Bool = true
    @AppStorage("speedUnit") var speedUnit: String = "mph"
    
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
                    
                    Picker("Speed Unit", selection: $speedUnit) {
                        ForEach(units, id: \.self) {
                            Text($0)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }
                .listRowBackground(DesignSystem.bgPanel)
                
                Section(header: Text("DATA SOURCE").font(DesignSystem.labelFont).foregroundColor(DesignSystem.cyan)) {
                    HStack {
                        Text("Current Limit Provider")
                            .foregroundColor(.white)
                        Spacer()
                        Text(driveViewModel.limitSource.rawValue)
                            .foregroundColor(DesignSystem.amber)
                            .font(.caption.bold())
                    }
                }
                .listRowBackground(DesignSystem.bgPanel)
                
                Section(header: Text("HISTORY").font(DesignSystem.labelFont).foregroundColor(DesignSystem.cyan)) {
                    ForEach(driveViewModel.sessionRecorder.sessions) { session in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(session.startTime.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white)
                                Text("\(String(format: "%.1f", driveViewModel.sessionRecorder.calculateDistance(for: session))) miles")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            Text("\(Int(session.percentWithinLimit * 100))%")
                                .font(DesignSystem.displayFont)
                                .scaleEffect(0.3)
                                .frame(width: 30)
                                .foregroundColor(session.percentWithinLimit > 0.9 ? DesignSystem.neonGreen : DesignSystem.amber)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listRowBackground(DesignSystem.bgPanel)
                
                Section {
                    Button(role: .destructive) {
                        driveViewModel.sessionRecorder.clearAllSessions()
                    } label: {
                        HStack {
                            Spacer()
                            Text("CLEAR ALL SESSIONS")
                                .font(DesignSystem.labelFont.bold())
                                .foregroundColor(DesignSystem.alertRed)
                            Spacer()
                        }
                    }
                }
                .listRowBackground(DesignSystem.bgPanel)
            }
            .scrollContentBackground(.hidden)
            .background(DesignSystem.bgDeep.ignoresSafeArea())
            .navigationTitle("SETTINGS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}
