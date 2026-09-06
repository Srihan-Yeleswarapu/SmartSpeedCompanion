import XCTest
@testable import SmartSpeedCompanion

/// Regression coverage for TestFlight 2.3.0 b640 ("The 'I Know (15s)' button
/// needs fixing. I click it and it's not doing anything. It's hiding the
/// prompt but shows it back within 3 seconds."). The CarPlay banner
/// (`CarPlayNavigationRootTemplate.handleAlerts`) re-presented the overspeed
/// alert on every ~1 Hz speed tick because it never checked
/// `alertEngine.isSnoozed` — only the snooze *button* did. The banner now
/// gates presentation on this exact contract; these tests pin the snooze
/// window semantics it relies on.
@MainActor
final class AlertEngineSnoozeTests: XCTestCase {

    /// While snoozed, `isSnoozed` is true for the full window and flips back
    /// to false when it expires — the flag `handleAlerts` checks each tick.
    func testSnoozeWindowSuppressesThenExpires() throws {
        let engine = AlertEngine(speedEngine: SpeedEngine(locationManager: LocationManager()))
        engine.snoozeFor(0.3)
        XCTAssertTrue(engine.isSnoozed, "snooze must be active immediately after 'I Know (15s)'")
        XCTAssertGreaterThan(engine.snoozeRemainingSeconds, 0)

        // Advance past the window.
        let expired = expectation(description: "snooze expired")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { expired.fulfill() }
        wait(for: [expired], timeout: 3)

        XCTAssertFalse(engine.isSnoozed, "alerts must resume once the window passes")
        XCTAssertEqual(engine.snoozeRemainingSeconds, 0)
    }

    /// Tapping "I Know (15s)" again while already snoozed restarts the window
    /// from *now* (not from the previous end), so repeated taps never leave a
    /// shorter effective silence than a fresh 15 s.
    func testSnoozeWhileSnoozedExtendsFromNow() {
        let engine = AlertEngine(speedEngine: SpeedEngine(locationManager: LocationManager()))
        engine.snoozeFor(0.3)
        engine.snoozeFor(15)
        XCTAssertGreaterThanOrEqual(engine.snoozeRemainingSeconds, 14,
                                    "second tap must extend the window from now")
    }

    /// Cancel ends the suppression immediately.
    func testCancelSnoozeAllowsImmediateAlerting() {
        let engine = AlertEngine(speedEngine: SpeedEngine(locationManager: LocationManager()))
        engine.snoozeFor(15)
        XCTAssertTrue(engine.isSnoozed)
        engine.cancelSnooze()
        XCTAssertFalse(engine.isSnoozed)
        XCTAssertEqual(engine.snoozeRemainingSeconds, 0)
    }
}
