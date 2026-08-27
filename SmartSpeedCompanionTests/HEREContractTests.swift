import XCTest
@testable import SmartSpeedCompanion

final class HEREContractTests: XCTestCase {
    func testNumericMaxSpeedSpanUsesHEREMetersPerSecondWireUnit() {
        let section: [String: Any] = [
            "spans": [["offset": 0, "maxSpeed": 13.888889]]
        ]
        XCTAssertEqual(
            HERERestSpeedLimitProvider().speedLimitMilesPerHour(in: section) ?? 0,
            31.068,
            accuracy: 0.01
        )
    }

    func testRoutingParserAcceptsScalarStringMaxSpeed() {
        let section: [String: Any] = [
            "spans": [["offset": 0, "maxSpeed": "13.4112"]]
        ]
        XCTAssertEqual(
            HERERestSpeedLimitProvider().speedLimitMilesPerHour(in: section) ?? 0,
            30.0,
            accuracy: 0.1
        )
    }

    func testExplicitMphMetadataRemainsMph() {
        let section: [String: Any] = [
            "spans": [["offset": 0, "maxSpeed": ["value": 35.0, "unit": "mph"]]]
        ]
        XCTAssertEqual(
            HERERestSpeedLimitProvider().speedLimitMilesPerHour(in: section) ?? 0,
            35.0,
            accuracy: 0.01
        )
    }
}
