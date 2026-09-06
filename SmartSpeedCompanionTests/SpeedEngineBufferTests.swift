import XCTest
@testable import SmartSpeedCompanion

/// Regression coverage for TestFlight 2.3.0 b640 ("I moved the buffer from
/// +3 to +5 in the middle of the drive and it didn't update during the
/// drive"): SpeedEngine previously held `userBuffer` / `measurementSystem`
/// in `@AppStorage` properties. That wrapper only auto-refreshes inside
/// SwiftUI Views; in a plain class it snapshots at init and never observes
/// later Settings writes, so the alert threshold stayed at the launch-time
/// buffer for the whole session. Both properties are now live UserDefaults
/// reads — these tests pin that contract.
@MainActor
final class SpeedEngineBufferTests: XCTestCase {
    private var savedBuffer: Any?
    private var savedSystem: String?

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        savedBuffer = defaults.object(forKey: "userBuffer")
        savedSystem = defaults.string(forKey: "measurementSystem")
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        if let savedBuffer {
            defaults.set(savedBuffer, forKey: "userBuffer")
        } else {
            defaults.removeObject(forKey: "userBuffer")
        }
        if let savedSystem {
            defaults.set(savedSystem, forKey: "measurementSystem")
        } else {
            defaults.removeObject(forKey: "measurementSystem")
        }
        super.tearDown()
    }

    /// The reporter's exact scenario: engine initialized with buffer +3,
    /// then the user moves the slider to +5 while driving. The next
    /// status evaluation must use the new buffer (49.5 mph in a 45 zone:
    /// .over with +3, only .warning with +5).
    func testBufferChangeMidDriveChangesAlertThreshold() {
        // Pin Imperial so the mph threshold math below is deterministic
        // regardless of the test host's stored preference.
        UserDefaults.standard.set("Imperial", forKey: "measurementSystem")
        UserDefaults.standard.set(3, forKey: "userBuffer")
        let engine = SpeedEngine(locationManager: LocationManager())
        XCTAssertEqual(engine.userBuffer, 3)

        engine.speed = 49.5
        engine.applyResolvedLimit(45)
        XCTAssertEqual(engine.status, .over)

        // Mid-drive Settings change — must be honored on the next tick
        // without re-initializing the engine.
        UserDefaults.standard.set(5, forKey: "userBuffer")
        XCTAssertEqual(engine.userBuffer, 5)
        engine.applyResolvedLimit(45)
        XCTAssertEqual(engine.status, .warning)
    }

    /// SettingsView's slider writes a Double; VehicleProfile.apply writes an
    /// Int. Both stored representations must read back as the same buffer.
    func testBufferReadsBothIntAndDoubleStoredValues() {
        let engine = SpeedEngine(locationManager: LocationManager())

        UserDefaults.standard.set(5.0, forKey: "userBuffer")
        XCTAssertEqual(engine.userBuffer, 5)

        UserDefaults.standard.set(Int(-2), forKey: "userBuffer")
        XCTAssertEqual(engine.userBuffer, -2)

        // Sub-mph stored values (possible via sync from another device)
        // round to the nearest mph.
        UserDefaults.standard.set(4.6, forKey: "userBuffer")
        XCTAssertEqual(engine.userBuffer, 5)
    }

    /// Unset key falls back to the same default the previous @AppStorage
    /// declaration had (5).
    func testBufferDefaultsToFiveWhenUnset() {
        UserDefaults.standard.removeObject(forKey: "userBuffer")
        let engine = SpeedEngine(locationManager: LocationManager())
        XCTAssertEqual(engine.userBuffer, 5)
    }

    /// The measurement system must also be observed live: AlertEngine and
    /// the threshold math both branch on it, and a stale snapshot would
    /// leave a Metric user's alerts converted with Imperial constants.
    func testMeasurementSystemChangeIsObservedLive() {
        UserDefaults.standard.set("Imperial", forKey: "measurementSystem")
        let engine = SpeedEngine(locationManager: LocationManager())
        XCTAssertEqual(engine.measurementSystem, "Imperial")

        UserDefaults.standard.set("Metric", forKey: "measurementSystem")
        XCTAssertEqual(engine.measurementSystem, "Metric")
    }
}
