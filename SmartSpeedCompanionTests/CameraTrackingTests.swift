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
