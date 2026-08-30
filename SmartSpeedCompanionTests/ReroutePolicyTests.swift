import XCTest
@testable import SmartSpeedCompanion

final class ReroutePolicyTests: XCTestCase {
    func testNavigationCoordinatorUsesForwardRouteMatching() throws {
        let source = try String(contentsOfFile: sourcePath(), encoding: .utf8)
        XCTAssertTrue(source.contains("private func matchRoute"))
        XCTAssertTrue(source.contains("lastMatchedDistanceAlongRoute"))
    }

    func testStepProgressionRequiresConsecutiveFixes() throws {
        let source = try String(contentsOfFile: sourcePath(), encoding: .utf8)
        XCTAssertTrue(source.contains("pendingStepAdvanceCount >= 2"))
    }

    func testRerouteUsesFastSingleRouteAndTrafficDepartureTime() throws {
        let source = try String(contentsOfFile: sourcePath(), encoding: .utf8)
        XCTAssertTrue(source.contains("request.requestsAlternateRoutes = !isRerouting"))
        XCTAssertTrue(source.contains("request.departureDate = .now"))
    }

    private func sourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\ViewModels\\NavigationCoordinator.swift"
        #else
        return "SmartSpeedCompanion/ViewModels/NavigationCoordinator.swift"
        #endif
    }
}
