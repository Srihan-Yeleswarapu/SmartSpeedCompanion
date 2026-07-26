import SwiftUI
import SwiftData

/// Form for editing a speed buffer profile's per-road-type buffer thresholds.
/// Same styling as SettingsView sections.
public struct AlertProfileEditorView: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State var profile: SpeedAlertProfile?

    @State private var name: String = ""
    @State private var highwayBuffer: Double = 5
    @State private var residentialBuffer: Double = 3
    @State private var schoolZoneBuffer: Double = 0
    @State private var workZoneBuffer: Double = 0
    @State private var arterialBuffer: Double = 5
    @State private var defaultBuffer: Double = 5

    public init(profile: SpeedAlertProfile?) {
        _profile = State(initialValue: profile)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("PROFILE NAME").font(DesignSystem.labelFont).foregroundColor(DesignSystem.cyan)) {
                    TextField("Profile Name", text: $name)
                        .foregroundColor(.white)
                }
                .listRowBackground(DesignSystem.bgPanel)

                Section(header: Text("SPEED BUFFERS (mph +)").font(DesignSystem.labelFont).foregroundColor(DesignSystem.cyan)) {
                    bufferRow(label: "Highway", value: $highwayBuffer, range: -5...10)
                    bufferRow(label: "Arterial / Main Road", value: $arterialBuffer, range: -5...10)
                    bufferRow(label: "Residential", value: $residentialBuffer, range: -5...10)
                    bufferRow(label: "School Zone", value: $schoolZoneBuffer, range: -5...10)
                    bufferRow(label: "Work Zone", value: $workZoneBuffer, range: -5...10)
                    bufferRow(label: "Default (Unknown Road)", value: $defaultBuffer, range: -5...10)
                }

                Section {
                    Button(action: resetToDefaults) {
                        HStack {
                            Spacer()
                            Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                    .foregroundColor(DesignSystem.amber)
                }

                Section {
                    Text("The buffer is the amount above the speed limit before an alert triggers. A positive value gives you headroom; negative tightens enforcement.")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden)
            .background(DesignSystem.bgDeep.ignoresSafeArea())
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(DesignSystem.cyan)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { saveProfile() }
                        .foregroundColor(DesignSystem.cyan)
                        .fontWeight(.bold)
                }
            }
            .onAppear {
                guard let p = profile else { return }
                name = p.name
                highwayBuffer = Double(p.highwayBuffer)
                residentialBuffer = Double(p.residentialBuffer)
                schoolZoneBuffer = Double(p.schoolZoneBuffer)
                workZoneBuffer = Double(p.workZoneBuffer)
                arterialBuffer = Double(p.arterialBuffer)
                defaultBuffer = Double(p.defaultBuffer)
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func bufferRow(label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .foregroundColor(.white)
                    .font(.subheadline)
                Spacer()
                let sign = value.wrappedValue > 0 ? "+" : ""
                Text("\(sign)\(Int(value.wrappedValue))")
                    .foregroundColor(DesignSystem.amber)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
            }
            Slider(value: value, in: range, step: 1)
                .tint(DesignSystem.cyan)
        }
    }

    private func resetToDefaults() {
        highwayBuffer = 5
        residentialBuffer = 3
        schoolZoneBuffer = 0
        workZoneBuffer = 0
        arterialBuffer = 5
        defaultBuffer = 5
    }

    private func saveProfile() {
        guard let p = profile else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        p.name = trimmed
        p.highwayBuffer = Int(highwayBuffer)
        p.residentialBuffer = Int(residentialBuffer)
        p.schoolZoneBuffer = Int(schoolZoneBuffer)
        p.workZoneBuffer = Int(workZoneBuffer)
        p.arterialBuffer = Int(arterialBuffer)
        p.defaultBuffer = Int(defaultBuffer)

        try? modelContext.save()
        if let idx = driveViewModel.alertProfiles.firstIndex(where: { $0.id == p.id }) {
            driveViewModel.alertProfiles[idx] = p
        }
        dismiss()
    }
}
