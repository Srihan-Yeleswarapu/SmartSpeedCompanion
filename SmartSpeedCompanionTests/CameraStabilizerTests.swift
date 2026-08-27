import XCTest
@testable import SmartSpeedCompanion

// ═══════════════════════════════════════════════════════════════════════════════
// Regression tests for Camera System v2 ("steady-cam").
//
// Each test pins one of the mechanisms that eliminates the historic zoom-in /
// zoom-out jitter:
//
//   1. Hysteresis + dwell in CruiseGovernor (GPS noise can never flap levels)
//   2. Continuous maneuver envelope (no discrete multiplier jumps)
//   3. Post-maneuver hold + gradual release (no zoom-out whiplash)
//   4. Bounded, asymmetric kinematics (no snap steps)
//   5. Deterministic decision-engine output (pure function)
// ═══════════════════════════════════════════════════════════════════════════════

final class CameraStabilizerTests: XCTestCase {

    // ── Helpers ────────────────────────────────────────────────────────────

    private let levels = CameraTuning.fallback.cruiseLevels
    private let timing = CameraTuning.fallback.timing

    private func context(
        speed: Double,
        dtt: CLLocationDistance = 5000,
        instruction: String = "Continue straight",
        destination: CLLocationDistance = 50_000,
        navigating: Bool = true,
        pitchOverride: DriveViewModel.MapPitchMode = .auto
    ) -> CameraContext {
        CameraContext(
            speed: speed,
            speedLimit: 40,
            isNavigating: navigating,
            isRecording: true,
            distanceToNextTurn: dtt,
            instruction: instruction,
            maneuverImageName: "arrow.turn.up.left",
            destinationDistance: destination,
            hasRoute: true,
            userPitchOverride: pitchOverride
        )
    }

    private var t0: Date { Date(timeIntervalSince1970: 1_000_000) }

    // ── 1. CruiseGovernor ──────────────────────────────────────────────────

    /// Alternating GPS noise around a level boundary must NEVER commit a level
    /// change — the dwell timer resets on every candidate flip.
    func testGovernorIgnoresBoundaryNoise() {
        var gov = CruiseGovernor(levels: levels, dwellSeconds: timing.dwellSeconds, initialSpeedMph: 54)
        var now = t0
        for step in 0..<60 {
            let noisy = step.isMultiple(of: 2) ? 53.0 : 57.0 // flaps across the 55 mph edge
            now.addTimeInterval(0.4)
            let level = gov.update(speedMph: noisy, now: now, allowPark: true)
            XCTAssertEqual(level, 5, "Noise flapped the level at step \(step)")
        }
    }

    /// A sustained genuine speed increase commits after the dwell window.
    func testGovernorCommitsAfterDwell() {
        var gov = CruiseGovernor(levels: levels, dwellSeconds: timing.dwellSeconds, initialSpeedMph: 54)
        var now = t0
        _ = gov.update(speedMph: 57, now: now, allowPark: false)
        now.addTimeInterval(2.0)
        XCTAssertEqual(gov.update(speedMph: 57, now: now, allowPark: false), 5, "Must not commit before dwell elapses")
        now.addTimeInterval(1.0)
        XCTAssertEqual(gov.update(speedMph: 57, now: now, allowPark: false), 6, "Must commit after dwell elapses")
    }

    /// Dropping into the hysteresis band does NOT downshift; only falling below
    /// the current level's hold threshold can. (Free-drive mode — navigation
    /// blocks down-shifts entirely, see the red-light test.)
    func testGovernorDownshiftHysteresis() {
        var gov = CruiseGovernor(levels: levels, dwellSeconds: timing.dwellSeconds, initialSpeedMph: 57)
        var now = t0
        // Level for 57 mph is index 6 (>55, <=65). Drop to 48 — above hold(51)? No:
        // hold[6] = 51, and 48 < 51 would allow a drop to quantize(48)=5... use 52 instead.
        for _ in 0..<20 {
            now.addTimeInterval(0.5)
            _ = gov.update(speedMph: 52, now: now, allowPark: true)
        }
        XCTAssertEqual(gov.currentIndex, 6, "52 >= hold 51 → must stay in level 6 despite sustained sub-entry speed")

        // Now genuinely below the hold threshold → commits downward after
        // dwell. quantize(45) = level 4 (45 <= 45); a genuine two-band drop is
        // allowed to skip the intermediate level.
        for _ in 0..<8 {
            now.addTimeInterval(0.5)
            _ = gov.update(speedMph: 45, now: now, allowPark: true)
        }
        XCTAssertEqual(gov.currentIndex, 4, "Sustained 45 mph (< hold 51) must downshift toward level 4")
    }

    /// During active guidance a red light must not move the cruise level AT
    /// ALL — road geometry owns framing there. Free-drive may relax to 0.
    func testGovernorNeverParksDuringNavigation() {
        var navGov = CruiseGovernor(levels: levels, dwellSeconds: timing.dwellSeconds, initialSpeedMph: 30)
        var now = t0
        for _ in 0..<30 {
            now.addTimeInterval(0.5)
            let level = navGov.update(speedMph: 0, now: now, allowPark: false)
            XCTAssertEqual(level, 3, "Navigation cruise level drifted while stopped at a light")
        }

        var freeGov = CruiseGovernor(levels: levels, dwellSeconds: timing.dwellSeconds, initialSpeedMph: 30)
        now = t0
        var finalLevel = 3
        for _ in 0..<30 {
            now.addTimeInterval(0.5)
            finalLevel = freeGov.update(speedMph: 0, now: now, allowPark: true)
        }
        XCTAssertEqual(finalLevel, 0, "Free-drive should relax to the parked level once stopped")
    }

    /// Multi-band jumps (highway → city exit) divide the dwell so real drops
    /// stay responsive.
    func testMultiBandJumpCommitsFasterThanSingleBand() {
        var gov = CruiseGovernor(levels: levels, dwellSeconds: 3.0, initialSpeedMph: 70)
        var now = t0
        // quantize(70) = 7 (sentinel top level), quantize(20) = 2 → 5-band jump
        // → dwell divided by 3 (capped) = 1.0 s.
        _ = gov.update(speedMph: 20, now: now, allowPark: true)
        now.addTimeInterval(1.1)
        XCTAssertEqual(gov.update(speedMph: 20, now: now, allowPark: true), 2,
                       "A 4-band jump must commit faster than a single-band dwell")
    }

    /// A continuous deceleration walking down the table must retain its dwell
    /// clock across same-direction candidate advances and commit DIRECTLY to
    /// the final band — not pay full dwell at every band edge (highway exits).
    func testSustainedDescentCommitsDirectlyToFinalBand() {
        var gov = CruiseGovernor(levels: levels, dwellSeconds: timing.dwellSeconds, initialSpeedMph: 70)
        var now = t0
        _ = gov.update(speedMph: 70, now: now, allowPark: true)
        let descent: [Double] = [55, 45, 35, 25]
        for speed in descent {
            now.addTimeInterval(0.4)
            _ = gov.update(speedMph: speed, now: now, allowPark: true)
        }
        // Clock started at the first downward desire (t0+0.4); jump-based dwell
        // for a multi-band candidate is ≤ 2.5/2 s, so by t0+2.0 it commits.
        now.addTimeInterval(1.2)
        let committed = gov.update(speedMph: 25, now: now, allowPark: true)
        XCTAssertEqual(committed, 2,
                       "Monotone descent should commit directly to the final band")
        XCTAssertEqual(gov.currentIndex, 2)
    }

    /// Anchor speeds deterministically re-quantize to their own level — this is
    /// what makes live targets piecewise-constant.
    func testAnchorSpeedsRoundTripToOwnLevel() {
        for i in levels.indices {
            let anchor = CameraMath.anchorSpeed(level: i, levels: levels)
            XCTAssertEqual(CameraMath.quantizeLevel(speedMph: anchor, levels: levels), i,
                           "Anchor for level \(i) does not round-trip")
        }
    }

    // ── 2. Maneuver envelope continuity ────────────────────────────────────

    func testManeuverEnvelopeIsContinuousAndBounded() {
        let t = CameraTuning.fallback.maneuver
        var previous = CameraMath.maneuverEnvelope(distance: 10_000, t)
        XCTAssertEqual(previous, 1.0)

        var d = Double(t.startDistanceM)
        while d > Double(t.fullTightenDistanceM) - 1 {
            let v = CameraMath.maneuverEnvelope(distance: d, t)
            XCTAssertLessThanOrEqual(v, previous + 1e-9, "Envelope increased at \(d)m — discontinuity risk")
            previous = v
            d -= 5
        }
        XCTAssertEqual(CameraMath.maneuverEnvelope(distance: Double(t.fullTightenDistanceM), t), t.minMultiplier, accuracy: 1e-9)
        XCTAssertEqual(CameraMath.maneuverEnvelope(distance: 0, t), t.minMultiplier)
    }

    // ── 3. Post-maneuver hold & release ────────────────────────────────────

    /// After passing a turn the target must HOLD its tight framing, then ease
    /// out gradually instead of snapping back to cruise altitude.
    func testPostManeuverHoldThenGradualRelease() {
        let stab = CameraStabilizer(tuning: .fallback)
        let approachContext = context(speed: 30, dtt: 60, instruction: "Turn left onto Main St")

        stab.prime(context: approachContext)
        stab.ingest(context: approachContext, now: t0)

        // Pass the turn: instruction advances, DTT jumps far beyond the envelope.
        let passedContext = context(speed: 30, dtt: 1800, instruction: "Continue straight")
        stab.ingest(context: passedContext, now: t0.addingTimeInterval(1.0))
        let heldAltitude = stab.currentTarget.altitude
        let cruiseAltitude = Double(levels[3].altitude) // governed level for ~30 mph
        XCTAssertLessThan(heldAltitude, cruiseAltitude * 0.7,
                          "Target snapped back toward cruise immediately after passing the turn")

        // Mid-release: strictly between held and cruise.
        stab.ingest(context: passedContext, now: t0.addingTimeInterval(2.8))
        let midAltitude = stab.currentTarget.altitude
        XCTAssertGreaterThan(midAltitude, heldAltitude + 1, "Release did not progress during the blend window")
        XCTAssertLessThan(midAltitude, cruiseAltitude - 1, "Release reached cruise too early")

        // After hold + release: fully released to cruise framing.
        stab.ingest(context: passedContext, now: t0.addingTimeInterval(1.0 + 1.2 + 2.6))
        XCTAssertEqual(stab.currentTarget.altitude, cruiseAltitude, accuracy: 1e-6,
                       "Camera never returned to cruise altitude after release window")
    }

    /// Approaching the next maneuver quickly cancels any pending release —
    /// compound maneuvers coalesce instead of ping-ponging.
    func testReleaseCancelsWhenNextManeuverApproaches() {
        let stab = CameraStabilizer(tuning: .fallback)
        stab.prime(context: context(speed: 30, dtt: 60, instruction: "Turn left"))
        stab.ingest(context: context(speed: 30, dtt: 60, instruction: "Turn left"), now: t0)

        stab.ingest(context: context(speed: 30, dtt: 900, instruction: "Turn right"), now: t0.addingTimeInterval(0.5))
        let heldAltitude = stab.currentTarget.altitude

        // Next maneuver closes inside 2 × fullTightenDistance → release aborts.
        stab.ingest(context: context(speed: 30, dtt: 120, instruction: "Turn right"), now: t0.addingTimeInterval(3.5))
        let tightenedAltitude = stab.currentTarget.altitude
        XCTAssertLessThanOrEqual(tightenedAltitude, heldAltitude * 1.05,
                                 "Camera zoomed out between two closely-spaced maneuvers")
    }

    // ── 4. Kinematics ──────────────────────────────────────────────────────

    func testKinematicsRateCapPreventsSnaps() {
        let dt: TimeInterval = 1.0 / 30.0
        let capped = CameraKinematics.approach(
            current: 3000, target: 250, dt: dt,
            tightenTau: timing.tightenTauSeconds, releaseTau: timing.releaseTauSeconds,
            rateCapPerSecond: timing.altitudeRateCapMPerS, snapEpsilon: 0.25
        )
        XCTAssertEqual(capped - 3000, -(timing.altitudeRateCapMPerS * dt), accuracy: 1e-6,
                       "Step exceeded the hard rate cap")
    }

    func testKinematicsTightenIsFasterThanRelease() {
        let dt: TimeInterval = 1.0 / 30.0
        let tightenStep = abs(CameraKinematics.approach(
            current: 1000, target: 800, dt: dt,
            tightenTau: timing.tightenTauSeconds, releaseTau: timing.releaseTauSeconds,
            rateCapPerSecond: 100_000, snapEpsilon: 0.001) - 1000)
        let releaseStep = abs(CameraKinematics.approach(
            current: 800, target: 1000, dt: dt,
            tightenTau: timing.tightenTauSeconds, releaseTau: timing.releaseTauSeconds,
            rateCapPerSecond: 100_000, snapEpsilon: 0.001) - 800)
        XCTAssertGreaterThan(tightenStep, releaseStep * 2,
                             "Tightening must be visibly quicker than releasing (Apple-style asymmetry)")
    }

    func testKinematicsSnapsOntoTarget() {
        let result = CameraKinematics.approach(
            current: 320.1, target: 320, dt: 1.0 / 30.0,
            tightenTau: timing.tightenTauSeconds, releaseTau: timing.releaseTauSeconds,
            rateCapPerSecond: 900, snapEpsilon: 0.25
        )
        XCTAssertEqual(result, 320, accuracy: 0, "Residual error must snap to zero, not linger")
    }

    // ── 5. Decision engine purity & overrides ──────────────────────────────

    func testComputeTargetIsDeterministic() {
        let ctx = context(speed: 27, dtt: 320, instruction: "Turn left")
        let a = CameraDecisionEngine.computeTarget(from: ctx)
        let b = CameraDecisionEngine.computeTarget(from: ctx)
        XCTAssertEqual(a, b)
    }

    func testNearManeuverTargetsTighterThanCruise() {
        let far = CameraDecisionEngine.computeTarget(from: context(speed: 27, dtt: 900))
        let near = CameraDecisionEngine.computeTarget(from: context(speed: 27, dtt: 80))
        XCTAssertLessThan(near.altitude, far.altitude)
    }

    func testForcedPitchModesOverrideEnvelope() {
        let nearTurn = context(speed: 27, dtt: 50, pitchOverride: .forced2D)
        XCTAssertEqual(CameraDecisionEngine.computeTarget(from: nearTurn).pitch, 0, accuracy: 1e-9)

        let forced3D = context(speed: 27, dtt: 50, pitchOverride: .forced3D)
        XCTAssertEqual(CameraDecisionEngine.computeTarget(from: forced3D).pitch, 45, accuracy: 1e-9)
    }

    func testFreeDriveIgnoresManeuverEnvelope() {
        // dtt=0 with no route must NOT collapse the altitude (v1 guarded this
        // behind isNavigating; v2 must too).
        let free = CameraDecisionEngine.computeTarget(
            from: context(speed: 40, dtt: 0, navigating: false)
        )
        XCTAssertEqual(free.altitude, Double(CameraTuning.fallback.cruiseLevels[4].altitude), accuracy: 1e-9)
    }

    // ── 6. Tuning resource integrity ───────────────────────────────────────

    func testBundledTuningDecodesAndMatchesFallbackShape() throws {
        guard let tuning = CameraTuning.loadTuning() else {
            throw XCTSkip("CameraTuning.json not present in test bundle main — fallback covers behaviour")
        }
        XCTAssertGreaterThanOrEqual(tuning.cruiseLevels.count, 4)
        XCTAssertEqual(tuning.cruiseLevels, CameraTuning.fallback.cruiseLevels,
                       "Bundle tuning drifted from compile-time fallback — update one of them")
        XCTAssertEqual(tuning.timing, CameraTuning.fallback.timing)
        XCTAssertEqual(tuning.maneuver, CameraTuning.fallback.maneuver)
        XCTAssertEqual(tuning.pitchFlatten, CameraTuning.fallback.pitchFlatten)
        XCTAssertEqual(tuning.destination, CameraTuning.fallback.destination)
    }
}
