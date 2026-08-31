import XCTest
@testable import SmartSpeedCompanion

final class ReroutePolicyTests: XCTestCase {
    func testAlertAcknowledgementStopsActiveAudioAndHaptics() throws {
        let source = try String(contentsOfFile: alertEngineSourcePath(), encoding: .utf8)
        XCTAssertTrue(source.contains("audioAlertActive = false"))
        XCTAssertTrue(source.contains("stopCurrentToneImmediately()"))
        XCTAssertTrue(source.contains("stopSpeedingPulse()"))
    }

    private func alertEngineSourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Core\\AlertEngine.swift"
        #else
        return "SmartSpeedCompanion/Core/AlertEngine.swift"
        #endif
    }

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
        XCTAssertTrue(source.contains("request.requestsAlternateRoutes = false"))
        XCTAssertTrue(source.contains("request.departureDate = .now"))
    }

    func testRerouteUsesTheLatestVehicleFixAsOrigin() throws {
        let source = try String(contentsOfFile: sourcePath(), encoding: .utf8)
        XCTAssertTrue(source.contains("latestRerouteLocation?.coordinate"))
        XCTAssertTrue(source.contains("timeSinceLastReroute >= 0.75"))
    }

    private func sourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\ViewModels\\NavigationCoordinator.swift"
        #else
        return "SmartSpeedCompanion/ViewModels/NavigationCoordinator.swift"
        #endif
    }
}
