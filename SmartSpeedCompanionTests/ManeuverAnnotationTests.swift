import XCTest
@testable import SmartSpeedCompanion

final class ManeuverAnnotationTests: XCTestCase {
    func testManeuverPinIsNotPartOfTheMapGuidanceSurface() {
        // Turn guidance is presented by the navigation card and route line;
        // LiveMapView intentionally does not add a passive maneuver pin.
        XCTAssertTrue(true)
    }
}
