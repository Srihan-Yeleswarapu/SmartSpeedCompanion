import XCTest
@testable import SmartSpeedCompanion

final class RoadTypeClassifierTests: XCTestCase {

    func testHighwayByRoadNamePrefix() {
        XCTAssertEqual(RoadTypeClassifier.roadType(speedLimitMph: 30, roadName: "I-10"), "highway")
        XCTAssertEqual(RoadTypeClassifier.roadType(speedLimitMph: 30, roadName: "Interstate 5"), "highway")
        XCTAssertEqual(RoadTypeClassifier.roadType(speedLimitMph: 30, roadName: "US 60"), "highway")
        XCTAssertEqual(RoadTypeClassifier.roadType(speedLimitMph: 30, roadName: "State Route 85"), "highway")
        XCTAssertEqual(RoadTypeClassifier.roadType(speedLimitMph: 30, roadName: "Arizona HWY 202"), "highway")
        XCTAssertEqual(RoadTypeClassifier.roadType(speedLimitMph: 30, roadName: "AZ-202 Freeway"), "highway")
    }

    func testHighwayBySpeedLimitWhenRoadNameUnknown() {
        XCTAssertEqual(RoadTypeClassifier.roadType(speedLimitMph: 65, roadName: nil), "highway")
        XCTAssertEqual(RoadTypeClassifier.roadType(speedLimitMph: 60, roadName: ""), "highway")
    }

    func testSchoolZoneByRoadName() {
        XCTAssertEqual(RoadTypeClassifier.roadType(speedLimitMph: 35, roadName: "School Zone Rd"), "schoolZone")
        XCTAssertEqual(RoadTypeClassifier.roadType(speedLimitMph: 35, roadName: "Washington Elementary School"), "schoolZone")
    }

    func testResidentialByLowLimit() {
        XCTAssertEqual(RoadTypeClassifier.roadType(speedLimitMph: 15, roadName: nil), "residential")
        XCTAssertEqual(RoadTypeClassifier.roadType(speedLimitMph: 20, roadName: ""), "residential")
    }

    func testArterialMidRange() {
        XCTAssertEqual(RoadTypeClassifier.roadType(speedLimitMph: 45, roadName: nil), "arterial")
        XCTAssertEqual(RoadTypeClassifier.roadType(speedLimitMph: 35, roadName: nil), "arterial")
    }

    func testResidentialLowerMidRange() {
        XCTAssertEqual(RoadTypeClassifier.roadType(speedLimitMph: 25, roadName: nil), "residential")
    }

    func testUnknownReturnsNil() {
        XCTAssertNil(RoadTypeClassifier.roadType(speedLimitMph: nil, roadName: nil))
        XCTAssertNil(RoadTypeClassifier.roadType(speedLimitMph: nil, roadName: ""))
    }

    func testClassifierIsCaseInsensitive() {
        XCTAssertEqual(RoadTypeClassifier.roadType(speedLimitMph: 30, roadName: "i-10"), "highway")
        XCTAssertEqual(RoadTypeClassifier.roadType(speedLimitMph: 30, roadName: "school zone rd"), "schoolZone")
    }
}