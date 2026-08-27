import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

final class SpeedLimitResolutionTests: XCTestCase {
    func testOrdinaryAcceptedGPSFixIsEligibleForSpeedLimitResolution() {
        let location = makeLocation(horizontalAccuracy: 42)

        XCTAssertTrue(SpeedEngine.isEligibleForSpeedLimitResolution(location))
    }

    func testInvalidAndBoundaryGPSFixesAreRejected() {
        XCTAssertFalse(SpeedEngine.isEligibleForSpeedLimitResolution(makeLocation(horizontalAccuracy: 0)))
        XCTAssertFalse(SpeedEngine.isEligibleForSpeedLimitResolution(makeLocation(horizontalAccuracy: -1)))
        XCTAssertFalse(SpeedEngine.isEligibleForSpeedLimitResolution(makeLocation(horizontalAccuracy: 100)))
        XCTAssertFalse(SpeedEngine.isEligibleForSpeedLimitResolution(makeLocation(horizontalAccuracy: 140)))
    }

    func testHEREParserSelectsOriginSpanAndConvertsExplicitMetersPerSecond() {
        let section: [String: Any] = [
            "spans": [
                [
                    "offset": 35.0,
                    "maxSpeed": ["value": 20.0, "unit": "mph"]
                ],
                [
                    "offset": 0.0,
                    "maxSpeed": ["value": 13.4112, "unit": "m/s"]
                ]
            ]
        ]

        let speedMph = HERERestSpeedLimitProvider().speedLimitMilesPerHour(in: section)

        XCTAssertNotNil(speedMph)
        XCTAssertEqual(speedMph ?? 0, 30.0, accuracy: 0.1)
    }

    func testHEREParserSupportsLegacySpeedLimitShape() {
        let section: [String: Any] = [
            "speedLimit": [
                "speed": 13.4112,
                "unit": "m/s"
            ]
        ]

        let speedMph = HERERestSpeedLimitProvider().speedLimitMilesPerHour(in: section)

        XCTAssertEqual(speedMph ?? 0, 30.0, accuracy: 0.1)
    }

    func testHapticPolicyRejectsUnknownLimit() {
        XCTAssertFalse(AlertEngine.shouldStartSpeedingPulse(
            speed: 50,
            limit: 0,
            buffer: 5,
            measurementSystem: "Imperial",
            isLimitResolved: false
        ))
    }

    func testHapticPolicyRejectsSpeedWithinConfiguredBuffer() {
        XCTAssertFalse(AlertEngine.shouldStartSpeedingPulse(
            speed: 54,
            limit: 50,
            buffer: 5,
            measurementSystem: "Imperial",
            isLimitResolved: true
        ))
    }

    func testHapticPolicyAllowsOnlyActualOverLimitSpeed() {
        XCTAssertTrue(AlertEngine.shouldStartSpeedingPulse(
            speed: 56,
            limit: 50,
            buffer: 5,
            measurementSystem: "Imperial",
            isLimitResolved: true
        ))
    }

    private func makeLocation(horizontalAccuracy: CLLocationAccuracy) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 33.3, longitude: -111.8),
            altitude: 0,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: 5,
            course: 90,
            speed: 13,
            timestamp: Date()
        )
    }
}
