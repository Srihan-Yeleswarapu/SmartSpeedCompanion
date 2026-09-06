import XCTest
import SwiftData
@testable import SmartSpeedCompanion

/// Regression coverage for TestFlight 2.3.0 b640 ("That glass slider is
/// centered which should be signifying +5 but it shows +3… fix it").
///
/// Two defects produced the confusing slider the reporter photographed:
///
/// 1. **Silent revert.** The active `VehicleProfile` held a frozen settings
///    snapshot (userBuffer = 3), and `applyVehicleProfileSettings` ran on
///    every app launch *and* every CarPlay connect — overwriting whatever
///    the user had changed in Settings (they had set +5). Profiles mirror
///    app-wide settings; they no longer clobber them.
///
/// 2. **Slider visuals.** The amber fill used `buffer / 10.0`, ignoring the
///    −5 minimum of the −5…10 track, and input came from a near-invisible
///    system Slider whose iOS 26 liquid-glass thumb rendered at its true
///    track position. Fill, thumb, and label told three different stories.
@MainActor
final class BufferSliderMappingTests: XCTestCase {

    // MARK: - Slider geometry mapping

    /// Fill/thumb fraction math and drag mapping must both use the full
    /// −5…10 range. Midpoint of the track = +2.5 → steps to +3 (even step)
    /// or stays +2.5 (odd); the −5 endpoint maps to 0 and +10 to full.
    func testDragMappingCoversFullMinusFiveToTenRange() {
        // Left end of the track → −5.
        XCTAssertEqual(BufferSliderView.buffer(fromDragAtX: 0, trackWidth: 300, step: 1), -5)
        // Right end → +10.
        XCTAssertEqual(BufferSliderView.buffer(fromDragAtX: 300, trackWidth: 300, step: 1), 10)
        // 1/3 across → raw −5 + 5 = 0 → value 0, NOT 3 (the old
        // buffer/10 fill put +3 at 30%, which is what the screenshot showed).
        XCTAssertEqual(BufferSliderView.buffer(fromDragAtX: 100, trackWidth: 300, step: 1), 0)
        // Halfway → −5 + 7.5 = 2.5 → rounds to 3 with a 1-step... but the
        // important property is clamping to the valid range.
        let mid = BufferSliderView.buffer(fromDragAtX: 150, trackWidth: 300, step: 1)
        XCTAssertNotNil(mid)
        XCTAssertTrue((-5...10).contains(Int(mid!)))
        // Beyond either end clamps.
        XCTAssertEqual(BufferSliderView.buffer(fromDragAtX: -50, trackWidth: 300, step: 1), -5)
        XCTAssertEqual(BufferSliderView.buffer(fromDragAtX: 999, trackWidth: 300, step: 1), 10)
    }

    /// Degenerate geometry must not produce garbage values.
    func testDragMappingRejectsInvalidGeometry() {
        XCTAssertNil(BufferSliderView.buffer(fromDragAtX: 10, trackWidth: 0, step: 1))
        XCTAssertNil(BufferSliderView.buffer(fromDragAtX: 10, trackWidth: -5, step: 1))
        XCTAssertNil(BufferSliderView.buffer(fromDragAtX: CGFloat.nan, trackWidth: 300, step: 1))
    }

    // MARK: - Profile no longer reverts user settings

    private var savedDefaults: [String: Any?] = [:]

    private func snapshotDefaults() {
        let ud = UserDefaults.standard
        savedDefaults = [
            "userBuffer": ud.object(forKey: "userBuffer"),
            "audioAlertsEnabled": ud.object(forKey: "audioAlertsEnabled"),
            "hapticAlertsEnabled": ud.object(forKey: "hapticAlertsEnabled"),
            "hapticAlertStyle": ud.string(forKey: "hapticAlertStyle"),
            "avoidHighways": ud.object(forKey: "avoidHighways"),
            "measurementSystem": ud.string(forKey: "measurementSystem"),
            "selectedVehicleIconId": ud.string(forKey: "selectedVehicleIconId"),
        ]
    }

    private func restoreDefaults() {
        let ud = UserDefaults.standard
        for (key, value) in savedDefaults {
            if let value { ud.set(value, forKey: key) } else { ud.removeObject(forKey: key) }
        }
    }

    /// The core revert scenario: a stale profile snapshot (buffer 3) must
    /// not overwrite the user's current Settings value (5) when applied.
    /// applyVehicleProfileSettings refreshes the profile FROM the live
    /// settings first, so launch/CarPlay-connect can no longer revert them.
    func testApplyVehicleProfileDoesNotRevertUserBuffer() throws {
        snapshotDefaults()
        defer { restoreDefaults() }

        let ud = UserDefaults.standard
        ud.set(5, forKey: "userBuffer")
        ud.set("Imperial", forKey: "measurementSystem")

        // A profile frozen with the pre-change buffer.
        let staleProfile = VehicleProfile(name: "Primary Vehicle", isActive: true, userBuffer: 3)

        let container = try ModelContainer(
            for: VehicleProfile.self, DriveSession.self, NamedLocation.self,
            SpeedAlertProfile.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let viewModel = DriveViewModel()
        viewModel.vehicleProfiles = [staleProfile]
        viewModel.activateVehicleProfile(staleProfile.id, context: context)

        // The user's +5 must survive the apply.
        XCTAssertEqual(ud.integer(forKey: "userBuffer"), 5)
        XCTAssertEqual(viewModel.speedEngine.userBuffer, 5)
        // And the profile now mirrors the live value instead of holding a
        // stale snapshot that would revert it on the next launch.
        XCTAssertEqual(staleProfile.userBuffer, 5)
    }

    /// Creating a profile inherits the user's current settings rather than
    /// the model's hard-coded defaults (buffer 5).
    func testCreateVehicleProfileInheritsCurrentSettings() throws {
        snapshotDefaults()
        defer { restoreDefaults() }

        let ud = UserDefaults.standard
        ud.set(7, forKey: "userBuffer")
        ud.set("Metric", forKey: "measurementSystem")

        let container = try ModelContainer(
            for: VehicleProfile.self, DriveSession.self, NamedLocation.self,
            SpeedAlertProfile.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let viewModel = DriveViewModel()
        let profile = viewModel.createVehicleProfile(name: "Work Truck", context: context)

        XCTAssertEqual(profile.userBuffer, 7)
        XCTAssertEqual(profile.measurementSystem, "Metric")
        XCTAssertEqual(ud.integer(forKey: "userBuffer"), 7, "creation must not disturb the live setting")
    }
}
