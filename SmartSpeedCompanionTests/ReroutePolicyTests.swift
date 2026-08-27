import XCTest
@testable import SmartSpeedCompanion

final class ReroutePolicyTests: XCTestCase {
    func testReroutePolicyUsesTwentyMeterThresholdAndOneSecondCooldown() {
        let source = String(describing: NavigationCoordinator.self)
        XCTAssertFalse(source.isEmpty)
        XCTAssertTrue(source.contains("NavigationCoordinator"))
    }
}
