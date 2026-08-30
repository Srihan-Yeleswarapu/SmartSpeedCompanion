import XCTest
import MapKit
@testable import SmartSpeedCompanion

final class CameraTrackingTests: XCTestCase {
    func testRecordingOnlyDriveUsesNorthUpFollowMode() {
        XCTAssertEqual(LiveMapView.trackingMode(isNavigating: false), .follow)
    }

    func testNavigationUsesHeadingFollowMode() {
        XCTAssertEqual(LiveMapView.trackingMode(isNavigating: true), .followWithHeading)
    }

    func testRecordingModeDoesNotUseHeadingFollowMode() {
        XCTAssertNotEqual(LiveMapView.trackingMode(isNavigating: false), .followWithHeading)
    }

    func testNavigationCameraZoomsMoreAggressivelyNearTurns() {
        let far = CameraContext(
            speed: 27, speedLimit: 35, isNavigating: true, isRecording: true,
            distanceToNextTurn: 900, instruction: "Turn left",
            maneuverImageName: "arrow.turn.up.left", destinationDistance: 2000,
            hasRoute: true, userPitchOverride: .auto
        )
        let near = CameraContext(
            speed: 27, speedLimit: 35, isNavigating: true, isRecording: true,
            distanceToNextTurn: 80, instruction: "Turn left",
            maneuverImageName: "arrow.turn.up.left", destinationDistance: 2000,
            hasRoute: true, userPitchOverride: .auto
        )

        let farTarget = CameraDecisionEngine.computeTarget(from: far)
        let nearTarget = CameraDecisionEngine.computeTarget(from: near)
        XCTAssertLessThan(nearTarget.altitude, farTarget.altitude)
    }
}

/// Regression coverage for the map strobe fix: the camera animator must not
/// write `mapView.camera` on every display-link frame. The write governor
/// caps MapKit assignments to ~5/sec and only when the integrated state
/// actually moved, so MapKit's own tracking/heading animation runs
/// undisturbed between writes.
final class CameraWriteGovernorTests: XCTestCase {
    func testAllowsFirstWriteImmediatelyWhenMoved() {
        let governor = CameraWriteGovernor()
        XCTAssertTrue(governor.shouldWrite(timeSinceLastWrite: nil, altitudeDelta: 10, pitchDelta: 0))
    }

    func testDeniesWriteWithinMinimumInterval() {
        let governor = CameraWriteGovernor(minimumWriteInterval: 0.2)
        XCTAssertFalse(governor.shouldWrite(timeSinceLastWrite: 0.1, altitudeDelta: 10, pitchDelta: 0))
    }

    func testAllowsWriteAfterMinimumInterval() {
        let governor = CameraWriteGovernor(minimumWriteInterval: 0.2)
        XCTAssertTrue(governor.shouldWrite(timeSinceLastWrite: 0.21, altitudeDelta: 10, pitchDelta: 0))
    }

    func testDeniesWriteWhenSettled() {
        let governor = CameraWriteGovernor()
        // Below the epsilon gates — no write even after the interval elapsed.
        XCTAssertFalse(governor.shouldWrite(timeSinceLastWrite: 1.0, altitudeDelta: 1.0, pitchDelta: 0))
        XCTAssertFalse(governor.shouldWrite(timeSinceLastWrite: 1.0, altitudeDelta: 0, pitchDelta: 0.1))
    }

    func testPitchMotionGatesWrite() {
        let governor = CameraWriteGovernor()
        XCTAssertTrue(governor.shouldWrite(timeSinceLastWrite: nil, altitudeDelta: 0, pitchDelta: 0.5))
        XCTAssertFalse(governor.shouldWrite(timeSinceLastWrite: nil, altitudeDelta: 0, pitchDelta: 0.1))
    }

    func testPerWriteZoomStepIsRateBounded() {
        // With the 200 ms write interval, a single write must never move the
        // camera by more than rateCap * interval, so the 5 writes/sec read as
        // a smooth glide instead of discrete zoom jumps.
        let next = CameraKinematics.approach(
            current: 320, target: 2800, dt: 0.2,
            tightenTau: 1.2, releaseTau: 1.8,
            rateCapPerSecond: 85, snapEpsilon: 0.75
        )
        XCTAssertLessThanOrEqual(abs(next - 320), 85 * 0.2 + 0.01)
    }
}
