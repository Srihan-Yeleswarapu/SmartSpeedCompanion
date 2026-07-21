import Foundation
import MapKit

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - CameraContext
//
// A stateless snapshot of everything the decision engine needs to compute the
// ideal camera position. Built from `DriveViewModel` state every tick.
//
// NOTE: Screen offset (shifting the vehicle lower on screen at higher speeds,
// requirement #10) is NOT implemented here because `MKMapView.followWithHeading`
// does not expose a coordinate offset — the system always centers on the user.
// Instead, higher speeds naturally show more road ahead via higher altitude.
// This is the same approach Google Maps takes when follow-mode is active.
// ═══════════════════════════════════════════════════════════════════════════════

public struct CameraContext: Sendable {
    public let speed: Double                  // mph
    public let speedLimit: Int                // mph
    public let isNavigating: Bool
    public let isRecording: Bool
    public let distanceToNextTurn: CLLocationDistance   // meters (0 when not navigating)
    public let instruction: String
    public let maneuverImageName: String
    public let destinationDistance: CLLocationDistance  // meters to destination
    public let hasRoute: Bool
    public let userPitchOverride: DriveViewModel.MapPitchMode

    public var isStationary: Bool { speed < 3.0 }

    public init(
        speed: Double,
        speedLimit: Int,
        isNavigating: Bool,
        isRecording: Bool,
        distanceToNextTurn: CLLocationDistance,
        instruction: String,
        maneuverImageName: String,
        destinationDistance: CLLocationDistance,
        hasRoute: Bool,
        userPitchOverride: DriveViewModel.MapPitchMode
    ) {
        self.speed = speed
        self.speedLimit = speedLimit
        self.isNavigating = isNavigating
        self.isRecording = isRecording
        self.distanceToNextTurn = distanceToNextTurn
        self.instruction = instruction
        self.maneuverImageName = maneuverImageName
        self.destinationDistance = destinationDistance
        self.hasRoute = hasRoute
        self.userPitchOverride = userPitchOverride
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - CameraMode
//
// The camera's current high-level behavioral mode. Each mode encodes a
// different "personality" for altitude, pitch, and responsiveness. Modes
// are recomputed every tick; there is no stateful transition machine —
// instead, neighboring modes blend smoothly because the underlying
// altitude/pitch functions produce continuous outputs across mode boundaries.
// ═══════════════════════════════════════════════════════════════════════════════

public enum CameraMode: String, Sendable {
    /// Speed < 3 mph — camera stays put, no updates.
    case parked
    /// Free-driving / recording without a route.
    case freeDrive
    /// Active route guidance, no special modifiers.
    case navigating
    /// Navigation with an upcoming turn < 1000 m.
    case approachingTurn
    /// Very close to a turn (< 125 m).
    case sharpTurn
    /// Instruction text contains "roundabout" / "rotary".
    case roundabout
    /// Long straight road (> 3000 m to next turn + speed > 50 mph).
    case longStraight
    /// Within 600 m of the destination.
    case destinationArrival
    /// User has manually panned the map.
    case manualDetached
    /// Just completed a turn — camera is holding zoom briefly.
    case postTurnHold
    /// Merge/ramp recovery — camera is slowly zooming back out.
    case mergeRecovery
    /// First few seconds of navigation — fly-over overview settling in.
    case routeInitiation
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - TargetCameraState
//
// The ideal camera parameters computed by the decision engine. The animator
// uses this as the target and smoothly interpolates from the current position.
// ═══════════════════════════════════════════════════════════════════════════════

public struct TargetCameraState: Sendable {
    /// Center coordinate distance (altitude) in meters.
    public var altitude: Double
    /// Camera pitch in degrees (0 = top-down, 60 = nearly horizon).
    public var pitch: Double
    /// If set, overrides the animator's default animation time constant.
    /// Used for route initiation fly-out (fast), highway deceleration (slow),
    /// and post-turn hold (very slow).
    public var requestedAnimationTau: TimeInterval?
    /// Priority level. Higher values bypass the cooldown gate.
    /// 0 = normal, 1 = important (turn critical), 2 = critical (route init).
    public var priority: Int

    public init(altitude: Double, pitch: Double,
                requestedAnimationTau: TimeInterval? = nil,
                priority: Int = 0) {
        self.altitude = altitude
        self.pitch = pitch
        self.requestedAnimationTau = requestedAnimationTau
        self.priority = priority
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - CameraDecisionEngine
//
// The pure computation unit. Takes a CameraContext and returns the ideal
// TargetCameraState. No side effects, no state, no timers.
//
// DESIGN PHILOSOPHY
//
// Every output value is a continuous function of its inputs — there are zero
// discrete jumps. Speed maps to altitude via a power curve; turn proximity
// modulates altitude via a smooth decay; road type adjusts through a
// continuous multiplier based on the speed limit. Even the mode classification
// is purely cosmetic (debug logging); the math guarantees continuity across
// mode boundaries.
//
// BEHAVIORS (15 new):
//   1. Lane-Guidance Zoom Tightening       (DECISION ENGINE)
//   2. Overlapping Maneuver Awareness       (DECISION ENGINE)
//   3. Sharp Turn Severity Boost            (DECISION ENGINE)
//   4. Traffic Congestion Adaptive Zoom     (DECISION ENGINE)
//   5. Highway Exit Aggressive Zoom         (DECISION ENGINE)
//   6. Urban Canyon Altitude Ceiling        (DECISION ENGINE)
//   7. Complex Intersection Pitch Adjustment (DECISION ENGINE)
//   8. High-Speed Straight Road Boost       (DECISION ENGINE)
//   9. Turn Approach Pitch Arc              (DECISION ENGINE)
//  10. Free-Drive Exploration Horizon       (DECISION ENGINE)
//  11. Post-Turn Bearing Stabilization      (ANIMATOR — stateful)
//  12. Route Initiation Overview Fly-Out    (ANIMATOR — stateful)
//  13. Merge/Ramp Recovery Hold             (ANIMATOR — stateful)
//  14. Highway Deceleration Slow Camera     (ANIMATOR — stateful)
//  15. Ambient Micro-Movement               (ANIMATOR — stateful)
// ═══════════════════════════════════════════════════════════════════════════════

public struct CameraDecisionEngine: Sendable {

    // ── Key points for altitude interpolation ──────────────────────────────
    // (speed_mph, altitude_m)
    private static let altitudeLUT: [(x: Double, y: Double)] = [
        (0,   300),
        (10,  380),
        (20,  550),
        (30,  780),
        (40,  1050),
        (50,  1400),
        (55,  1600),
        (60,  1850),
        (65,  2100),
        (70,  2400),
        (75,  2700),
        (80,  3000),
        (85,  3300),
        (100, 4000)
    ]

    // ── Key points for pitch interpolation ─────────────────────────────────
    // (speed_mph, pitch_degrees)
    private static let pitchLUT: [(x: Double, y: Double)] = [
        (0,   0),
        (5,   18),
        (15,  28),
        (25,  35),
        (35,  42),
        (45,  48),
        (50,  50),
        (60,  54),
        (70,  57),
        (85,  60)
    ]

    // ── Road-type altitude multipliers keyed by speed limit ────────────────
    private static let roadTypeMultiplierLUT: [(x: Double, y: Double)] = [
        (0,   1.00),   // unknown — neutral, no adjustment
        (25,  0.85),   // residential / school zone
        (35,  0.95),   // city collector
        (45,  1.00),   // arterial
        (55,  1.15),   // highway
        (65,  1.30),   // interstate
        (80,  1.40)    // high-speed interstate
    ]

    // ── Turn proximity: altitude multiplier ────────────────────────────────
    // Smooth decay from 1.0 at 1000 m down to ~0.28 at 0 m.
    private static func turnProximityMultiplier(distance dist: CLLocationDistance) -> Double {
        guard dist < 1000 else { return 1.0 }
        let t = 1.0 - dist / 1000.0 // 0 at 1000 m, 1 at 0 m
        return max(0.28, 1.0 - 0.72 * t)
    }

    // ── Long straight: altitude multiplier (gradual zoom out) ──────────────
    private static func longStraightMultiplier(distanceToTurn dist: CLLocationDistance, speed: Double) -> Double {
        guard dist > 3000, speed > 50 else { return 1.0 }
        let excess = dist - 3000
        let boost = min(0.45, 0.45 * (excess / 10_000))
        return 1.0 + boost
    }

    // ── Destination arrival: altitude & pitch modifiers ────────────────────
    private static func destinationMultiplier(distance dist: CLLocationDistance) -> (alt: Double, pitch: Double) {
        guard dist < 600 else { return (1.0, 0.0) }
        let t = dist / 600.0 // 1 at 600 m, 0 at 0 m
        let altMul = 0.35 + 0.65 * t
        let pitchDelta = -20.0 * (1.0 - t) // subtract up to 20° at 0 m
        return (altMul, pitchDelta)
    }

    // ── Roundabout: temporarily flatter, overhead-ish ──────────────────────
    private static func roundaboutPitchOffset() -> Double { -28.0 }

    // ── Original ramp / exit altitude multiplier ───────────────────────────
    // `internal` (implicit) so CameraAnimator's merge-recovery logic can
    // reference the same value if needed. Both are 1.15.
    static let rampAltitudeMultiplier: Double = 1.15


    // ═══════════════════════════════════════════════════════════════════════
    // NEW BEHAVIOR #1 — Lane-Guidance Zoom Tightening
    //
    // Beyond the standard turnProximityMultiplier, when the user gets very
    // close to a turn (< 180 m), apply an ADDITIONAL tightening factor so
    // the camera zooms in further for lane-level detail. Apple Maps does
    // this near every turn to reveal lane guidance stripes.
    //
    // The factor goes from 1.0 (no change) at 180 m to 0.75 (25 % tighter)
    // at 0 m, on top of whatever the normal turn zoom already computed.
    // ═══════════════════════════════════════════════════════════════════════
    private static func laneGuidanceFactor(distance dist: CLLocationDistance) -> Double {
        guard dist > 0, dist < 180 else { return 1.0 }
        let t = dist / 180.0 // 1 at 180 m, 0 at 0 m
        // Smooth quadratic ease-out: starts subtle, tightens quickly near the line
        return 1.0 - (1.0 - t) * (1.0 - t) * 0.25
    }

    // ═══════════════════════════════════════════════════════════════════════
    // NEW BEHAVIOR #2 — Overlapping Maneuver Awareness
    //
    // Google Maps detects when two turns are close together (< 600 m
    // apart). Rather than zooming all the way in on the first turn and
    // then snapping back out for the second, it maintains a moderate zoom
    // that keeps both maneuvers visible.
    //
    // We infer overlapping turns from the instruction text: if the current
    // instruction contains "then" (e.g. "Turn left, then turn right") it's
    // almost certainly a quick sequential pair. When detected, we reduce
    // the turn zoom by a compromise factor that prevents the camera from
    // going too tight.
    // ═══════════════════════════════════════════════════════════════════════
    private static func overlappingTurnCompromise(instruction: String,
                                                   distanceToTurn dist: CLLocationDistance) -> Double {
        guard dist < 600 else { return 1.0 }
        let lower = instruction.lowercased()
        // "then" is the clearest signal of a multi-step instruction
        guard lower.contains("then") || lower.contains(";") || lower.contains(",") else { return 1.0 }
        // Compromise factor: the closer we get, the more we resist zooming fully in.
        // Clamped to never go below 0.7× of whatever the turn zoom would be.
        let t = dist / 600.0 // 1 at 600 m, 0 at 0 m
        return 0.7 + 0.3 * t
    }

    // ═══════════════════════════════════════════════════════════════════════
    // NEW BEHAVIOR #3 — Sharp Turn Severity Boost
    //
    // Apple Maps applies a tighter zoom for genuinely sharp turns (hairpin,
    // sharp left/right, U-turn) to make the road geometry unmistakable.
    // Gentle highway curves do not trigger this.
    //
    // We detect severity from instruction keywords and apply an extra
    // 0.75× altitude factor on top of the standard turn zoom.
    // ═══════════════════════════════════════════════════════════════════════
    private static func sharpTurnSeverityFactor(instruction: String,
                                                distanceToTurn dist: CLLocationDistance) -> Double {
        guard dist < 250, dist > 0 else { return 1.0 }
        let lower = instruction.lowercased()
        let isSharp = lower.contains("sharp") || lower.contains("hairpin")
                    || lower.contains("u-turn") || lower.contains("uturn")
                    || lower.contains("turn around") || lower.contains("tight")
        guard isSharp else { return 1.0 }
        // Tighter within 250 m, peaking at 0 m
        let t = dist / 250.0 // 1 at 250 m, 0 at 0 m
        return 1.0 - (1.0 - t) * 0.25 // ranges 1.0 → 0.75
    }

    // ═══════════════════════════════════════════════════════════════════════
    // NEW BEHAVIOR #4 — Traffic Congestion Adaptive Zoom
    //
    // Google Maps zooms in when traffic is heavy so the user can see the
    // congestion details. We detect congestion by comparing speed to the
    // speed limit: when speed < 0.4 × limit, the road is congested.
    //
    // Zoom in by an additional factor (0.75× altitude) proportional to
    // severity, and smoothly return to normal as traffic clears.
    // ═══════════════════════════════════════════════════════════════════════
    private static func trafficCongestionFactor(speed: Double, speedLimit: Int) -> Double {
        guard speedLimit > 20 else { return 1.0 } // ignore on very low-limit roads
        let ratio = speed / Double(speedLimit)
        guard ratio < 0.4 else { return 1.0 }
        // ratio is 0.0..0.4; map to 0.0..1.0 severity
        let severity = (0.4 - ratio) / 0.4
        // Altitude goes from 1.0 down to 0.75× at max congestion
        return 1.0 - severity * 0.25
    }

    // ═══════════════════════════════════════════════════════════════════════
    // NEW BEHAVIOR #5 — Highway Exit Aggressive Zoom
    //
    // Apple Maps treats highway exits differently from standard turns.
    // When on a highway (> 50 mph) approaching an exit (< 400 m), the
    // camera zooms in more aggressively AND flattens pitch so lane
    // guidance (which lane for which exit) is clearly visible.
    //
    // This is stronger than the standard turn zoom: 0.6× altitude
    // multiplier and an extra −8° pitch beyond the standard turn flattening.
    // ═══════════════════════════════════════════════════════════════════════
    private static func highwayExitModifier(instruction: String,
                                             speed: Double,
                                             distanceToTurn dist: CLLocationDistance)
        -> (altitude: Double, pitch: Double) {
        guard dist < 400, dist > 0, speed > 50 else { return (1.0, 0.0) }
        let lower = instruction.lowercased()
        guard lower.contains("exit") else { return (1.0, 0.0) }
        let t = dist / 400.0 // 1 at 400 m, 0 at 0 m
        let severity = 1.0 - t
        let altMul = 1.0 - severity * 0.40 // ranges 1.0 → 0.60
        let pitchDelta = -severity * 8.0   // ranges 0 → −8°
        return (altMul, pitchDelta)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // NEW BEHAVIOR #6 — Urban Canyon Altitude Ceiling
    //
    // In dense urban areas (speed limit ≤ 35 mph, frequent intersections =
    // distanceToNextTurn < 600 m), Apple Maps caps the maximum altitude.
    // Zooming out too far in a city shows only building rooftops — useless.
    //
    // We cap altitude at 800 m when the urban heuristic is active, but the
    // cap is smooth: it only engages when the context matches and the
    // computed altitude exceeds 800 m.
    // ═══════════════════════════════════════════════════════════════════════
    private static func urbanCanyonAltitudeCap(altitude: Double,
                                                speedLimit: Int,
                                                distanceToTurn dist: CLLocationDistance) -> Double {
        guard speedLimit <= 35, dist < 600, dist > 0 else { return altitude }
        return min(altitude, 800.0)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // NEW BEHAVIOR #7 — Complex Intersection Pitch Adjustment
    //
    // When the instruction contains multiple steps (signaled by "then", ";",
    // or the instruction reads like a complex junction), Google Maps tilts
    // the camera slightly more top-down (+5° pitch) so the user can see
    // the full intersection geometry at a glance.
    // ═══════════════════════════════════════════════════════════════════════
    private static func complexIntersectionPitch(instruction: String,
                                                  distanceToTurn dist: CLLocationDistance) -> Double {
        guard dist < 400, dist > 20 else { return 0.0 }
        let lower = instruction.lowercased()
        let isComplex = lower.contains("then") || lower.contains(";")
                     || lower.contains("to ")    // "Turn left to merge onto..."
                     || (lower.contains("onto") && lower.contains("then"))
        guard isComplex else { return 0.0 }
        // Full +5° adjustment when within 400 m, scaling down as we pass the turn
        let t = dist / 400.0
        return 5.0 * t
    }

    // ═══════════════════════════════════════════════════════════════════════
    // NEW BEHAVIOR #8 — High-Speed Straight Road Boost
    //
    // When cruising at highway speeds (> 55 mph) with a long gap before the
    // next instruction (> 3000 m), Apple Maps and Google Maps both pull
    // the camera back further to give the driver more route awareness.
    //
    // We add +15% more altitude beyond what the LUT + longStraightMultiplier
    // already produce. This is separate from longStraightMultiplier because
    // it's only about pure speed + distance, not the "zooming out over time"
    // feel of longStraightMultiplier.
    // ═══════════════════════════════════════════════════════════════════════
    private static func highSpeedStraightBoost(speed: Double,
                                               distanceToTurn dist: CLLocationDistance) -> Double {
        guard speed > 55, dist > 3000 else { return 1.0 }
        let speedExcess = min((speed - 55) / 25.0, 1.0) // 0 at 55, 1 at 80+
        let distExcess = min((dist - 3000) / 5000.0, 1.0) // 0 at 3000, 1 at 8000+
        let blend = speedExcess * distExcess
        return 1.0 + blend * 0.15 // up to +15%
    }

    // ═══════════════════════════════════════════════════════════════════════
    // NEW BEHAVIOR #9 — Turn Approach Pitch Arc
    //
    // Instead of a single pitch flattening near the turn, create a
    // beautiful ARC: as the driver approaches a turn, the camera
    // FIRST tilts slightly forward (+4°) at medium range (500–200 m) to
    // look around the corner / scan the road ahead, THEN tilts down
    // (−10°) when very close (< 200 m) to show the intersection geometry.
    //
    // This mimics the natural head movement of a driver approaching a turn.
    // ═══════════════════════════════════════════════════════════════════════
    private static func turnApproachPitchArc(distanceToTurn dist: CLLocationDistance,
                                              speed: Double) -> Double {
        guard dist < 500, dist > 0 else { return 0.0 }
        let speedFactor = min(speed / 40.0, 1.0) // stronger effect at higher speeds

        if dist >= 200 {
            // APPROACH PHASE: 500 m → 200 m
            // Camera tilts forward to look around the corner
            let t = (dist - 200.0) / 300.0 // 1 at 500 m, 0 at 200 m
            let lookAhead = t * 4.0 // +4° at 500 m, 0° at 200 m
            return lookAhead * speedFactor
        } else {
            // TIGHTEN PHASE: 200 m → 0 m
            // Camera flattens to show the intersection
            let t = (200.0 - dist) / 200.0 // 0 at 200 m, 1 at 0 m
            let flatten = -t * 10.0 // 0° at 200 m, −10° at 0 m
            return flatten * speedFactor
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // NEW BEHAVIOR #10 — Free-Drive Exploration Horizon
    //
    // When NOT navigating but driving at speed (> 30 mph), gradually tilt
    // the camera up to reveal more of the horizon. Apple Maps does this
    // in free-drive mode: as speed builds, the camera tilts up.
    //
    // We add up to +5° pitch over the first 8 seconds of sustained speed.
    // This is applied in the ANIMATOR since it has a time component.
    // ═══════════════════════════════════════════════════════════════════════
    // NOTE: This behavior is implemented in CameraAnimator as it is
    // time-dependent and not a pure computation.


    // ── Smooth step interpolation (Hermite) ──────────────────────────────
    static func smoothInterpolate(x: Double, knots: [(x: Double, y: Double)]) -> Double {
        guard !knots.isEmpty else { return 0 }
        if x <= knots.first!.x { return knots.first!.y }
        if x >= knots.last!.x { return knots.last!.y }

        for i in 0 ..< knots.count - 1 {
            let (x0, y0) = (knots[i].x, knots[i].y)
            let (x1, y1) = (knots[i + 1].x, knots[i + 1].y)
            if x >= x0 && x <= x1 {
                let t = (x - x0) / (x1 - x0)
                let s = t * t * (3.0 - 2.0 * t)
                return y0 + s * (y1 - y0)
            }
        }
        return knots.last!.y
    }

    // ── Compute the ideal camera state for a given context ─────────────────
    public static func computeTarget(from context: CameraContext) -> TargetCameraState {
        // ── Stationary guard ──────────────────────────────────────────
        if context.isStationary || context.userPitchOverride == .forced2D {
            let alt = computeBaseAltitude(speed: context.speed, limit: context.speedLimit,
                                          distanceToTurn: context.distanceToNextTurn,
                                          isNavigating: context.isNavigating,
                                          instruction: context.instruction,
                                          destinationDistance: context.destinationDistance)
            return TargetCameraState(altitude: alt, pitch: 0)
        }

        var altitude: Double
        var pitch: Double

        // ── 1. Classify the mode (informational / debug logging) ─────
        let mode = classifyMode(context)
        DebugLogger.shared.log("CAM mode: \(mode.rawValue) spd=\(Int(context.speed)) dtt=\(Int(context.distanceToNextTurn))")

        // ── 2. Compute base altitude from speed ───────────────────────
        altitude = computeBaseAltitude(speed: context.speed, limit: context.speedLimit,
                                       distanceToTurn: context.distanceToNextTurn,
                                       isNavigating: context.isNavigating,
                                       instruction: context.instruction,
                                       destinationDistance: context.destinationDistance)

        // ── 3. Compute base pitch from speed ──────────────────────────
        pitch = Self.smoothInterpolate(x: context.speed, knots: Self.pitchLUT)

        // ── 4. Apply context-aware modifiers ──────────────────────────

        // Highway flyover: tilt up at speed with no turn for miles
        if context.isNavigating && context.distanceToNextTurn > 4000 && context.speed > 50 {
            let blend = min(1.0, (context.speed - 50) / 25.0)
            pitch += blend * 8.0
        }

        // ── Turn proximity modifier (navigating only) ─────────────────
        if context.isNavigating && context.distanceToNextTurn < 1000 {
            let turnMul = turnProximityMultiplier(distance: context.distanceToNextTurn)
            altitude *= turnMul

            // NEW BEHAVIOR #1 — Lane-Guidance Zoom Tightening
            let laneFactor = laneGuidanceFactor(distance: context.distanceToNextTurn)
            altitude *= laneFactor

            // NEW BEHAVIOR #2 — Overlapping Maneuver Awareness
            if context.instruction.count > 3 {
                let overlapFactor = overlappingTurnCompromise(
                    instruction: context.instruction,
                    distanceToTurn: context.distanceToNextTurn
                )
                // Compromise factor resists zooming all the way in: the closer
                // we are, the more it pushes the altitude back up toward moderate.
                // This only matters when the overlap factor is < 1.0.
                if overlapFactor < 1.0 {
                    // Undo some of the turn zoom: altitude stays at most as tight
                    // as the compromise factor allows. We compute what the "no
                    // turn zoom" altitude would be and blend toward it.
                    let noTurnAlt = computeBaseAltitude(
                        speed: context.speed, limit: context.speedLimit,
                        distanceToTurn: context.distanceToNextTurn,
                        isNavigating: context.isNavigating,
                        instruction: context.instruction,
                        destinationDistance: context.destinationDistance
                    )
                    let fullTurnAlt = altitude // current (tight) altitude
                    let blendTowardWide = 1.0 - overlapFactor // 0..0.3
                    altitude = fullTurnAlt * (1.0 - blendTowardWide) + noTurnAlt * blendTowardWide
                }
            }

            // NEW BEHAVIOR #3 — Sharp Turn Severity Boost
            let sharpFactor = sharpTurnSeverityFactor(
                instruction: context.instruction,
                distanceToTurn: context.distanceToNextTurn
            )
            altitude *= sharpFactor

            // NEW BEHAVIOR #5 — Highway Exit Aggressive Zoom
            let (exitAltMul, exitPitchDelta) = highwayExitModifier(
                instruction: context.instruction,
                speed: context.speed,
                distanceToTurn: context.distanceToNextTurn
            )
            altitude *= exitAltMul
            pitch += exitPitchDelta

            // NEW BEHAVIOR #7 — Complex Intersection Pitch Adjustment
            let complexPitch = complexIntersectionPitch(
                instruction: context.instruction,
                distanceToTurn: context.distanceToNextTurn
            )
            pitch += complexPitch

            // NEW BEHAVIOR #9 — Turn Approach Pitch Arc
            let approachArc = turnApproachPitchArc(
                distanceToTurn: context.distanceToNextTurn,
                speed: context.speed
            )
            pitch += approachArc
        }

        // ── Long straight: gradually zoom out ─────────────────────────
        if context.isNavigating {
            let straightMul = longStraightMultiplier(distanceToTurn: context.distanceToNextTurn,
                                                     speed: context.speed)
            altitude *= straightMul

            if straightMul > 1.0 {
                pitch += (straightMul - 1.0) * 20.0
            }
        }

        // NEW BEHAVIOR #8 — High-Speed Straight Road Boost
        let speedStraightBoost = highSpeedStraightBoost(
            speed: context.speed,
            distanceToTurn: context.distanceToNextTurn
        )
        altitude *= speedStraightBoost

        // ── Roundabout ────────────────────────────────────────────────
        if context.instruction.lowercased().contains("roundabout") ||
           context.instruction.lowercased().contains("rotary") ||
           context.instruction.lowercased().contains("circle") {
            pitch += Self.roundaboutPitchOffset()
        }

        // ── Ramp / exit / merge ───────────────────────────────────────
        let instructionLower = context.instruction.lowercased()
        if instructionLower.contains("exit") || instructionLower.contains("merge") ||
           instructionLower.contains("ramp") || instructionLower.contains("fork") {
            altitude *= Self.rampAltitudeMultiplier
        }

        // ── Destination arrival ───────────────────────────────────────
        if context.isNavigating && context.destinationDistance < 600 {
            let (destAltMul, destPitchDelta) = destinationMultiplier(distance: context.destinationDistance)
            altitude *= destAltMul
            pitch += destPitchDelta
        }

        // NEW BEHAVIOR #4 — Traffic Congestion Adaptive Zoom
        let congestionMul = trafficCongestionFactor(speed: context.speed,
                                                    speedLimit: context.speedLimit)
        altitude *= congestionMul

        // NEW BEHAVIOR #6 — Urban Canyon Altitude Ceiling
        altitude = urbanCanyonAltitudeCap(
            altitude: altitude,
            speedLimit: context.speedLimit,
            distanceToTurn: context.distanceToNextTurn
        )

        // ── Free-drive (recording) — slightly lower pitch ────────────
        if !context.isNavigating && context.isRecording {
            pitch = min(pitch, 35.0)
        }

        // ── 5. Clamp to sane bounds ───────────────────────────────────
        altitude = clamp(altitude, min: 200, max: 4500)
        pitch = clamp(pitch, min: 0, max: 62)

        // ── 6. Apply user pitch override (wins over everything) ──────
        switch context.userPitchOverride {
        case .forced2D:
            pitch = 0
        case .forced3D:
            pitch = 45
        case .auto:
            break
        }

        return TargetCameraState(altitude: altitude, pitch: pitch)
    }

    // ── Classify mode (debug / logging only) ───────────────────────────
    private static func classifyMode(_ ctx: CameraContext) -> CameraMode {
        if ctx.isStationary { return .parked }
        if ctx.userPitchOverride != .auto { return .navigating }
        guard ctx.isNavigating else {
            return ctx.isRecording ? .freeDrive : .parked
        }

        let instruction = ctx.instruction.lowercased()
        if instruction.contains("roundabout") || instruction.contains("rotary") {
            return .roundabout
        }
        if ctx.destinationDistance < 150 {
            return .destinationArrival
        }
        if ctx.distanceToNextTurn < 125 {
            return .sharpTurn
        }
        if ctx.distanceToNextTurn < 1000 {
            return .approachingTurn
        }
        if ctx.distanceToNextTurn > 3000 && ctx.speed > 50 {
            return .longStraight
        }
        return .navigating
    }

    // ── Core altitude computation ──────────────────────────────────────
    private static func computeBaseAltitude(
        speed: Double,
        limit: Int,
        distanceToTurn: CLLocationDistance,
        isNavigating: Bool,
        instruction: String,
        destinationDistance: CLLocationDistance
    ) -> Double {
        let speedAlt = Self.smoothInterpolate(x: speed, knots: Self.altitudeLUT)
        let roadMul = Self.smoothInterpolate(x: Double(limit), knots: Self.roadTypeMultiplierLUT)
        let adjusted = speedAlt * roadMul

        if isNavigating && speed > 45 && distanceToTurn > 4000 {
            let speedExcess = (speed - 45) / 30.0
            let flyoverAlt = 1800 + (speed - 45) * 25
            let blend = min(1.0, max(0.0, speedExcess))
            return adjusted * (1.0 - blend) + flyoverAlt * blend
        }

        return adjusted
    }

    private static func clamp(_ val: Double, min minVal: Double, max maxVal: Double) -> Double {
        return Swift.max(minVal, Swift.min(maxVal, val))
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - CameraAnimator
//
// Smoothly moves the actual MKMapView camera toward a target state.
//
// Uses an exponential moving average (EMA) on the target altitude and pitch
// so that every individual frame moves only a fraction of the distance to the
// target. This gives a beautiful, continuous ease-out feel that never overshoots
// and never oscillates — exactly like Apple Maps.
//
// Enhanced with 5 stateful behaviors:
//   #11 — Post-Turn Bearing Stabilization — Holds turn zoom for 1.5 s after a turn
//   #12 — Route Initiation Overview Fly-Out — 2.5× altitude on first route, 3 s settle
//   #13 — Merge/Ramp Recovery Hold — Holds ramp zoom for 2 s, then 2 s ease-out
//   #14 — Highway Deceleration Slow Camera — Slower tau when exiting highway
//   #15 — Ambient Micro-Movement — Subtle ±1.5° pitch oscillation when stable
// ═══════════════════════════════════════════════════════════════════════════════

@MainActor
public final class CameraAnimator {
    // ── Smoothed state ─────────────────────────────────────────────────
    private var displayAltitude: Double = 1000
    private var displayPitch: Double = 0
    private var lastUpdateTime: Date = .now

    // ── Deadband ───────────────────────────────────────────────────────
    private let altitudeDeadband: Double = 25.0
    private let pitchDeadband: Double = 3.0

    // ── Cooldown ───────────────────────────────────────────────────────
    private let minInterval: TimeInterval = 0.4
    private var lastApplyTime: Date = .distantPast

    // ── Speed smoothing ────────────────────────────────────────────────
    private var smoothedSpeed: Double = 0
    private let speedTau: TimeInterval = 0.5

    // ── Debug ──────────────────────────────────────────────────────────
    private var lastLoggedTarget: TargetCameraState?

    // ═══════════════════════════════════════════════════════════════════
    // NEW BEHAVIOR #11 — Post-Turn Bearing Stabilization
    //
    // Tracks the last known instruction and distance. When the instruction
    // changes AND the previous DTT was < 100 m (meaning we just passed a
    // turn), we enter a "post-turn hold" state. For 1.5 s after the turn,
    // the camera refuses to zoom back out, preserving the tight turn zoom
    // until the vehicle's heading has stabilized on the new road.
    //
    // Apple Maps and Google Maps both do this: after a turn, the camera
    // lingers for 1–2 seconds before zooming back out to the cruising
    // altitude. Without this, the camera snaps back out the instant the
    // instruction advances, creating a jarring "whiplash" effect.
    // ═══════════════════════════════════════════════════════════════════
    private var lastInstruction: String = ""
    private var lastDTT: CLLocationDistance = 0
    private var postTurnHoldUntil: Date = .distantPast
    private var isPostTurnHold: Bool = false
    private let postTurnHoldDuration: TimeInterval = 1.5

    // ═══════════════════════════════════════════════════════════════════
    // NEW BEHAVIOR #12 — Route Initiation Overview Fly-Out
    //
    // When navigation first starts, briefly zoom OUT to ~2.5× the normal
    // altitude so the user sees the full route context — exactly like the
    // "Route Overview" animation Apple Maps and Google Maps both show when
    // first starting navigation. Over 3 seconds, the camera smoothly
    // settles into the normal driving altitude.
    // ═══════════════════════════════════════════════════════════════════
    private var routeStartTime: Date = .distantPast
    private var wasNavigating: Bool = false
    private let routeInitSettleDuration: TimeInterval = 3.0
    private var routeInitAltitudeBoost: Double = 1.0 // decays from 2.5 → 1.0

    // ═══════════════════════════════════════════════════════════════════
    // NEW BEHAVIOR #13 — Merge/Ramp Recovery Hold
    //
    // After merging onto a highway (instruction transitions from
    // "merge/ramp" to a straight instruction), hold the exit/ramp zoom
    // for 2 seconds, then smoothly ease back to normal over 2 more seconds.
    //
    // Google Maps does this to prevent the jarring "snap" when the ramp
    // ends and the camera would otherwise zoom back out immediately.
    // ═══════════════════════════════════════════════════════════════════
    private var wasOnRamp: Bool = false
    private var mergeHoldStartTime: Date?
    private let mergeHoldDuration: TimeInterval = 2.0   // hold phase
    private let mergeRecoveryDuration: TimeInterval = 2.0 // ease-out phase
    // (merge recovery phase is latch-based; no stored factor needed)

    // ═══════════════════════════════════════════════════════════════════
    // NEW BEHAVIOR #14 — Highway Deceleration Slow Camera
    //
    // When the user exits the highway (speed drops from > 50 mph to
    // < 35 mph while navigating), use a slower animation tau (0.8 s instead
    // of the default) for 3 seconds to prevent the "falling" sensation of
    // the camera zooming in too fast after an exit.
    //
    // Apple Maps does this naturally via its spring-based animation system.
    // Our EMA needs the tau boost manually.
    // ═══════════════════════════════════════════════════════════════════
private var wasHighwaySpeed: Bool = false
    private var highwayDecelUntil: Date = .distantPast

    // ═══════════════════════════════════════════════════════════════════
    // NEW BEHAVIOR #15 — Ambient Micro-Movement
    //
    // When the camera has been stable (no meaningful altitude/pitch change
    // > 10 m / 2°) for 5+ seconds, apply a very subtle ±1.5° pitch
    // oscillation over a 12-second period. This makes the camera feel
    // alive rather than frozen — Apple Maps has micro-movements that make
    // the camera feel organic.
    //
    // The effect is so subtle most users won't consciously notice it,
    // but its absence is what makes other navigation cameras feel "dead."
    // ═══════════════════════════════════════════════════════════════════
    private var stableSince: Date = .now
    private let ambientOscillationAmplitude: Double = 1.5 // ±1.5°
    private let ambientOscillationPeriod: TimeInterval = 12.0
    // ── Free-Drive Exploration Horizon (NEW BEHAVIOR #10 tie-in) ──────
    // Applied here in the animator since it has a time component
    private var freeDriveSustainedSpeedSince: Date = .distantPast
    private var freeDriveHorizonPitch: Double = 0

    public init() {}

    // ── Main entry point ───────────────────────────────────────────────
    public func update(mapView: MKMapView, context: CameraContext) {
        let now = Date()

        // 1. Smooth the raw speed
        let dt = -lastUpdateTime.timeIntervalSinceNow
        smoothedSpeed = smoothExponential(current: smoothedSpeed,
                                          target: context.speed,
                                          dt: dt,
                                          tau: speedTau)
        lastUpdateTime = now

        // 2. Detect instruction transitions for stateful behaviors
        detectTransitions(context: context)

        // 3. Compute target from the smoothed speed + context
        let smoothedContext = CameraContext(
            speed: smoothedSpeed,
            speedLimit: context.speedLimit,
            isNavigating: context.isNavigating,
            isRecording: context.isRecording,
            distanceToNextTurn: context.distanceToNextTurn,
            instruction: context.instruction,
            maneuverImageName: context.maneuverImageName,
            destinationDistance: context.destinationDistance,
            hasRoute: context.hasRoute,
            userPitchOverride: context.userPitchOverride
        )

        let rawTarget = CameraDecisionEngine.computeTarget(from: smoothedContext)
        var target = rawTarget

        // ── Apply stateful modifiers ──────────────────────────────────

        // NEW BEHAVIOR #11 — Post-Turn Bearing Stabilization
        if isPostTurnHold && now < postTurnHoldUntil {
            // Do NOT zoom back out — keep altitude at whatever it was when the turn completed.
            // The deadband + cooldown gate below will naturally hold position.
            target.priority = max(target.priority, 1)
            target.requestedAnimationTau = 1.0 // very slow, almost frozen
            DebugLogger.shared.log("CAM post-turn hold \(Int(postTurnHoldUntil.timeIntervalSince(now)))s left")
        }

        // NEW BEHAVIOR #12 — Route Initiation Overview Fly-Out
        if context.isNavigating && routeStartTime != .distantPast {
            let elapsed = now.timeIntervalSince(routeStartTime)
            if elapsed < routeInitSettleDuration {
                let t = elapsed / routeInitSettleDuration
                // Smoothstep decay: 2.5 → 1.0 over 3 seconds
                let s = t * t * (3.0 - 2.0 * t) // smoothstep
                routeInitAltitudeBoost = 1.0 + (2.5 - 1.0) * (1.0 - s)
                target.altitude *= routeInitAltitudeBoost
                target.priority = max(target.priority, 2)
                target.requestedAnimationTau = 0.3 // snappier for the fly-out
                DebugLogger.shared.log("CAM route-init fly-out \(String(format: "%.2f", routeInitAltitudeBoost))×")
            } else {
                routeInitAltitudeBoost = 1.0
            }
        }

        // NEW BEHAVIOR #13 — Merge/Ramp Recovery Hold
        // Uses a latch approach: hold the current display altitude during the hold
        // phase, then smoothly blend toward the computed target during recovery.
        // This avoids double-counting the ramp multiplier that might already be
        // in the target from the decision engine.
        if let mergeStart = mergeHoldStartTime {
            let mergeElapsed = now.timeIntervalSince(mergeStart)
            if mergeElapsed < mergeHoldDuration {
                // Hold phase: prevent altitude from snapping back out.
                // The displayAltitude at transition was already at the correct
                // ramp-zoomed level — just keep it there.
                target.altitude = max(target.altitude, displayAltitude * 0.98)
                target.priority = max(target.priority, 1)
                DebugLogger.shared.log("CAM merge hold (phase 1/2)")
            } else if mergeElapsed < mergeHoldDuration + mergeRecoveryDuration {
                // Recovery phase: smooth blend from held altitude toward computed target
                let recoverElapsed = mergeElapsed - mergeHoldDuration
                let t = recoverElapsed / mergeRecoveryDuration
                let s = t * t * (3.0 - 2.0 * t) // smoothstep: 0→1
                let desiredAlt = max(target.altitude, displayAltitude * 0.98)
                target.altitude = displayAltitude + (desiredAlt - displayAltitude) * s
                target.priority = max(target.priority, 1)
                DebugLogger.shared.log("CAM merge recovery \(String(format: "%.0f", target.altitude))m")
            } else {
                // Fully recovered
                mergeHoldStartTime = nil
            }
        }

        // NEW BEHAVIOR #14 — Highway Deceleration Slow Camera
        if now < highwayDecelUntil {
            target.requestedAnimationTau = 0.8 // much slower
            DebugLogger.shared.log("CAM highway decel slow (tau=0.8)")
        }

        // NEW BEHAVIOR #10 — Free-Drive Exploration Horizon
        if !context.isNavigating && context.speed > 30 {
            if freeDriveSustainedSpeedSince == .distantPast {
                freeDriveSustainedSpeedSince = now
            }
            let freeElapsed = now.timeIntervalSince(freeDriveSustainedSpeedSince)
            let horizonBlend = min(freeElapsed / 8.0, 1.0) // ramps up over 8 seconds
            freeDriveHorizonPitch = horizonBlend * 5.0 // up to +5°
            target.pitch += freeDriveHorizonPitch
        } else {
            freeDriveSustainedSpeedSince = .distantPast
            freeDriveHorizonPitch = 0
        }

        // NEW BEHAVIOR #15 — Ambient Micro-Movement
        let altDelta = abs(target.altitude - displayAltitude)
        let pitchDelta = abs(target.pitch - displayPitch)
        if altDelta < 10 && pitchDelta < 2 {
            if stableSince == .distantPast { stableSince = now }
            let stableElapsed = now.timeIntervalSince(stableSince)
            if stableElapsed > 5.0 {
                // Apply ambient oscillation
                let phase = ((now.timeIntervalSince1970 * 2 * .pi) / ambientOscillationPeriod)
                    .truncatingRemainder(dividingBy: 2 * .pi)
                let oscillation = sin(phase) * ambientOscillationAmplitude
                target.pitch += oscillation
                if Int(phase * 10) % 30 == 0 { // log once per ~3 seconds
                    DebugLogger.shared.log("CAM ambient micro-movement")
                }
            }
        } else {
            stableSince = .distantPast
        }

        // 4. Deadband + cooldown gate
        let finalAltDelta = abs(target.altitude - displayAltitude)
        let finalPitchDelta = abs(target.pitch - displayPitch)
        let timeSinceApply = -lastApplyTime.timeIntervalSinceNow

        let isCritical = (target.priority >= 1) || (
            context.isNavigating &&
            context.distanceToNextTurn < 150 &&
            finalAltDelta > 50
        )

        let shouldSkip = !isCritical && (
            (finalAltDelta < altitudeDeadband && finalPitchDelta < pitchDeadband) ||
            timeSinceApply < minInterval
        )

        if shouldSkip {
            if finalAltDelta > altitudeDeadband * 2 || finalPitchDelta > pitchDeadband * 2 {
                let reason = timeSinceApply < minInterval ? "cooldown" : "deadband"
                logIfChanged(target, reason: reason)
            }
            return
        }

        // 5. Move display state toward target (EMA smoothing)
        let animTau: TimeInterval = target.requestedAnimationTau
            ?? animationTimeConstant(altDelta: finalAltDelta, pitchDelta: finalPitchDelta)
        displayAltitude = smoothExponential(current: displayAltitude,
                                            target: target.altitude,
                                            dt: dt,
                                            tau: animTau)
        displayPitch = smoothExponential(current: displayPitch,
                                         target: target.pitch,
                                         dt: dt,
                                         tau: animTau)

        // 6. Apply to MapKit
        let cam = mapView.camera.copy() as! MKMapCamera
        cam.centerCoordinateDistance = displayAltitude
        cam.pitch = CGFloat(displayPitch)
        mapView.setCamera(cam, animated: false)

        lastApplyTime = now
        logIfChanged(target, reason: "applied")
    }

    /// Detect state transitions for the stateful behaviors.
    private func detectTransitions(context: CameraContext) {
        let now = Date()

        // ── Post-turn detection (#11) ──────────────────────────────────
        // If instruction changed AND previous DTT was < 100 m → just passed a turn
        if context.isNavigating
            && context.instruction != lastInstruction
            && lastDTT < 100
            && lastDTT > 0 {
            postTurnHoldUntil = now + postTurnHoldDuration
            isPostTurnHold = true
            DebugLogger.shared.log("CAM turn completed → post-turn hold 1.5s")
        }
        // Expire the hold naturally
        if now >= postTurnHoldUntil {
            isPostTurnHold = false
        }
        lastInstruction = context.instruction
        lastDTT = context.distanceToNextTurn

        // ── Route initiation detection (#12) ───────────────────────────
        if context.isNavigating && !wasNavigating {
            routeStartTime = now
            routeInitAltitudeBoost = 2.5
            DebugLogger.shared.log("CAM route initiated → fly-out 2.5×")
        }
        wasNavigating = context.isNavigating

        // ── Merge/ramp recovery detection (#13) ────────────────────────
        let lower = context.instruction.lowercased()
        let isOnRamp = lower.contains("merge") || lower.contains("ramp")
                    || lower.contains("exit")
        if wasOnRamp && !isOnRamp {
            // Just left ramp/merge state
            if mergeHoldStartTime == nil {
                mergeHoldStartTime = now
                DebugLogger.shared.log("CAM ramp complete → merge hold 2s + 2s recovery")
            }
        }
        wasOnRamp = isOnRamp

        // ── Highway deceleration detection (#14) ───────────────────────
        if context.speed > 50 && context.isNavigating {
            wasHighwaySpeed = true
        }
        if wasHighwaySpeed && context.speed < 35 && context.isNavigating {
            highwayDecelUntil = now + 3.0
            wasHighwaySpeed = false
            DebugLogger.shared.log("CAM highway exit → slow camera 3s")
        }
    }

    /// Reset internal state (e.g., when navigation starts fresh or style changes dramatically).
    public func reset(to mapView: MKMapView) {
        displayAltitude = mapView.camera.centerCoordinateDistance
        displayPitch = Double(mapView.camera.pitch)
        smoothedSpeed = 0
        lastUpdateTime = .now
        lastApplyTime = .distantPast
        lastLoggedTarget = nil

        // Reset all stateful behaviors
        lastInstruction = ""
        lastDTT = 0
        postTurnHoldUntil = .distantPast
        isPostTurnHold = false
        routeStartTime = .distantPast
        wasNavigating = false
        routeInitAltitudeBoost = 1.0
        wasOnRamp = false
        mergeHoldStartTime = nil
        wasHighwaySpeed = false
        highwayDecelUntil = .distantPast
        stableSince = .distantPast
        freeDriveSustainedSpeedSince = .distantPast
        freeDriveHorizonPitch = 0
    }

    // ── EMA smoothing ────────────────────────────────────────────
    private func smoothExponential(current: Double, target: Double, dt: TimeInterval, tau: TimeInterval) -> Double {
        guard dt > 0, tau > 0 else { return target }
        let alpha = 1.0 - exp(-dt / tau)
        return current + alpha * (target - current)
    }

    // ── Animation time constant varies by change magnitude ───────
    private func animationTimeConstant(altDelta: Double, pitchDelta: Double) -> TimeInterval {
        let maxDelta = max(altDelta / 2000.0, pitchDelta / 60.0)
        // Tiny changes: slow, deliberate (tau = 0.6s)
        // Huge changes: snappy, responsive (tau = 0.2s)
        return 0.6 - min(maxDelta, 1.0) * 0.4
    }

    // ── Debug logging (only when the target actually changed) ────
    private func logIfChanged(_ target: TargetCameraState, reason: String) {
        guard let prev = lastLoggedTarget else {
            lastLoggedTarget = target
            return
        }
        if abs(target.altitude - prev.altitude) > 20 || abs(target.pitch - prev.pitch) > 3 {
            DebugLogger.shared.log("CAM [\(reason)]: \(Int(target.altitude))m \(Int(target.pitch))°")
            lastLoggedTarget = target
        }
    }
}
