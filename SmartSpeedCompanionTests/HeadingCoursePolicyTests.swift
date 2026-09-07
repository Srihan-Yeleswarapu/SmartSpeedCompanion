import XCTest
@testable import SmartSpeedCompanion

/// Regression coverage for TestFlight 2.3.0 b640 ("ALWAYS ALWAYS ALWAYS,
/// the direction in which your moving should be facing up. Here it's
/// showing like 30 degrees above the right horizontal.").
///
/// Two defects let the heading-up map settle at a steady offset from the
/// direction of travel:
///
/// 1. **Compass revert at low speed.** The old heading pipeline fell back
///    to the device compass whenever GPS speed dropped (traffic light,
///    creep). A phone compass inside a car deviates 10–30° from the road,
///    so the map visibly rotated away from travel direction — exactly the
///    reporter's "30 degrees above the right horizontal". The policy now
///    HOLDS the last valid course; the compass only seeds before the
///    first course ever arrives.
/// 2. **Racing writers.** A second GPS-sink write clobbered the held
///    value with nil on invalid courses. The Combine pipeline is now the
///    sole writer (enforced by a source sweep, not a unit test).
@MainActor
final class HeadingCoursePolicyTests: XCTestCase {

    // MARK: - Course adoption while moving

    /// Moving above the free-driving threshold (~4.5 mph / 2 m/s): the GPS
    /// course IS the direction of travel — never the compass.
    func testMovingAdoptsCourseNotCompass() {
        let next = DriveViewModel.nextHeading(
            previous: 90, course: 95, speed: 10,
            compassTrueHeading: 60, isNavigating: false)
        XCTAssertEqual(next, 95)
    }

    /// Creeping below the free-driving threshold holds the last course —
    /// this is the exact "stopped at a light" scenario where the old code
    /// snapped to the compass and rotated the map off the road.
    func testCreepBelowThresholdHoldsLastCourse() {
        let next = DriveViewModel.nextHeading(
            previous: 95, course: 95, speed: 1.0,
            compassTrueHeading: 60, isNavigating: false)
        XCTAssertEqual(next, 95, "must hold course, not revert to the compass")
    }

    /// An invalid course (CLLocationDirection −1 sentinel) while stopped
    /// also holds — and never publishes the compass.
    func testInvalidCourseHoldsLastCourse() {
        let next = DriveViewModel.nextHeading(
            previous: 95, course: -1, speed: 0,
            compassTrueHeading: 60, isNavigating: false)
        XCTAssertEqual(next, 95)
    }

    // MARK: - Navigation re-lock from a stop

    /// While navigating, the adoption threshold drops to a creep so the
    /// map re-locks to the fresh course the instant the vehicle rolls
    /// from a red light (0.5 m/s would be an ignore in free driving).
    func testNavigatingReLocksAtCreepSpeed() {
        let next = DriveViewModel.nextHeading(
            previous: 180, course: 90, speed: 0.7,
            compassTrueHeading: 30, isNavigating: true)
        XCTAssertEqual(next, 90)
    }

    // MARK: - Compass is seed-only

    /// Before any course exists (app just opened, stationary) the compass
    /// seeds the value — long-standing behavior, unchanged.
    func testCompassSeedsBeforeFirstCourse() {
        let next = DriveViewModel.nextHeading(
            previous: nil, course: nil, speed: 0,
            compassTrueHeading: 42, isNavigating: false)
        XCTAssertEqual(next, 42)
    }

    /// Once a course is held, the compass can NEVER take over again —
    /// this is the core "30 degrees" defect.
    func testCompassCannotOverrideHeldCourse() {
        let next = DriveViewModel.nextHeading(
            previous: 271, course: -1, speed: 0,
            compassTrueHeading: 305, isNavigating: false)
        XCTAssertEqual(next, 271, "held course must survive; compass is seed-only")
    }

    /// With nothing held and no compass, an invalid course publishes nil
    /// rather than garbage.
    func testNoDataPublishesNil() {
        let next = DriveViewModel.nextHeading(
            previous: nil, course: -1, speed: 0,
            compassTrueHeading: -1, isNavigating: false)
        XCTAssertNil(next)
    }

    // MARK: - Wrap-around sanity

    /// Held course survives across the 0°/360° wrap (course 350 → hold
    /// must remain 350, not normalize through the compass or wrap to −10).
    func testHeldCourseSurvivesWrapRegion() {
        let next = DriveViewModel.nextHeading(
            previous: 350, course: 350, speed: 0.2,
            compassTrueHeading: 10, isNavigating: true)
        XCTAssertEqual(next, 350)
    }
}
