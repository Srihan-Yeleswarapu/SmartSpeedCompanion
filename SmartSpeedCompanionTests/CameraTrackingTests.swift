import XCTest
import MapKit
@testable import SmartSpeedCompanion

final class CameraTrackingTests: XCTestCase {
    func testCameraSettlingWindowIsLongerThanWriteGovernorCadence() {
        let governor = CameraWriteGovernor(minimumWriteInterval: 0.2)
        XCTAssertTrue(governor.shouldWrite(timeSinceLastWrite: 0.35, altitudeDelta: 10, pitchDelta: 0))
        XCTAssertFalse(governor.shouldWrite(timeSinceLastWrite: 0.2, altitudeDelta: 10, pitchDelta: 0))
    }
    func testRecordingOnlyDriveUsesNorthUpFollowMode() {
        XCTAssertEqual(LiveMapView.trackingMode(isNavigating: false), .follow)
    }

    func testNavigationDoesNotUseCompassHeadingFollow() {
        // Regression coverage for TestFlight 2.3.0 b640 ("Heading is pointing
        // up but the map isn't"): every camera write for the altitude/pitch
        // glide dislodges MapKit's `.followWithHeading` compass tracker, so
        // the map fell back to north-up while the heading beam kept pointing
        // up. Navigation must use plain `.follow`; the CameraAnimator owns
        // rotation via `CameraContext.vehicleCourse` instead.
        XCTAssertNotEqual(LiveMapView.trackingMode(isNavigating: true), .followWithHeading)
        XCTAssertEqual(LiveMapView.trackingMode(isNavigating: true), .follow)
        XCTAssertEqual(LiveMapView.trackingMode(isNavigating: false), .follow)
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

    // ── Heading (CarPlay course orientation) gating ─────────────────────────
    func testHeadingMotionGatesWrite() {
        let governor = CameraWriteGovernor()
        XCTAssertTrue(governor.shouldWrite(timeSinceLastWrite: nil, altitudeDelta: 0, pitchDelta: 0, headingDelta: 2))
        XCTAssertFalse(governor.shouldWrite(timeSinceLastWrite: nil, altitudeDelta: 0, pitchDelta: 0, headingDelta: 0.5))
    }

    func testHeadingWriteIsRateLimited() {
        let governor = CameraWriteGovernor()
        XCTAssertFalse(governor.shouldWrite(timeSinceLastWrite: 0.1, altitudeDelta: 0, pitchDelta: 0, headingDelta: 5))
        XCTAssertTrue(governor.shouldWrite(timeSinceLastWrite: 0.21, altitudeDelta: 0, pitchDelta: 0, headingDelta: 5))
    }
}

/// Covers the CarPlay heading fix: the map must rotate toward the vehicle's
/// GPS course (so travel points up) along the shortest way around the compass,
/// without ever turning the wrong way at the 0/360 boundary.
final class CameraHeadingTests: XCTestCase {
    func testAngularDistanceTakesShortestPathAcrossWrap() {
        XCTAssertEqual(CameraMath.angularDistance(350 - 10), -20, accuracy: 0.0001)
        XCTAssertEqual(CameraMath.angularDistance(10 - 350), 20, accuracy: 0.0001)
        XCTAssertEqual(CameraMath.angularDistance(10 - 0), 10, accuracy: 0.0001)
    }

    func testNormalizedHeadingWrapsInto0To360() {
        XCTAssertEqual(CameraMath.normalizedHeading(370), 10, accuracy: 0.0001)
        XCTAssertEqual(CameraMath.normalizedHeading(-10), 350, accuracy: 0.0001)
        XCTAssertEqual(CameraMath.normalizedHeading(0), 0, accuracy: 0.0001)
    }

    func testRotatingApproachRespectsRateCap() {
        XCTAssertEqual(CameraMath.rotatingApproach(current: 0, target: 90, maxDelta: 30), 30, accuracy: 0.0001)
        XCTAssertEqual(CameraMath.rotatingApproach(current: 0, target: 90, maxDelta: 60), 60, accuracy: 0.0001)
    }

    func testRotatingApproachTakesShortestWayAcrossWrap() {
        // 0 → 350 is only -10 degrees the short way; must rotate clockwise
        // (down to 350), not spool all the way around to +350 the long way.
        XCTAssertEqual(CameraMath.rotatingApproach(current: 0, target: 350, maxDelta: 30), 350, accuracy: 0.0001)
        // 350 → 10 is +20 the short way (past 0), not +360.
        XCTAssertEqual(CameraMath.rotatingApproach(current: 350, target: 10, maxDelta: 30), 10, accuracy: 0.0001)
    }
}

/// Covers the iPhone navigation rotation fix (TestFlight 2.3.0 b640): the
/// camera context carries the vehicle course during guidance and omits it
/// everywhere else, so the animator rotates the map only when it genuinely
/// owns heading.
final class CameraContextCourseTests: XCTestCase {
    private func makeContext(vehicleCourse: Double?) -> CameraContext {
        CameraContext(
            speed: 27, speedLimit: 35, isNavigating: true, isRecording: true,
            distanceToNextTurn: 900, instruction: "Merge onto SR-101 Loop N",
            maneuverImageName: "arrow.merge", destinationDistance: 3400,
            hasRoute: true, userPitchOverride: .auto, vehicleCourse: vehicleCourse
        )
    }

    func testVehicleCourseDefaultsToNilOutsideNavigation() {
        let context = CameraContext(
            speed: 27, speedLimit: 35, isNavigating: false, isRecording: true,
            distanceToNextTurn: 0, instruction: "", maneuverImageName: "",
            destinationDistance: 0, hasRoute: false, userPitchOverride: .auto
        )
        XCTAssertNil(context.vehicleCourse)
    }

    func testNavigationContextPreservesVehicleCourse() {
        XCTAssertEqual(makeContext(vehicleCourse: 271).vehicleCourse, 271)
    }

    func testNilVehicleCourseLeavesHeadingToMapKit() {
        XCTAssertNil(makeContext(vehicleCourse: nil).vehicleCourse)
    }
}
