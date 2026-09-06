import Foundation
import MapKit
import QuartzCore

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Camera System v2 — "steady-cam" architecture
//
// WHY THIS EXISTS
//
// v1 recomputed an "ideal" altitude every tick from ~10 stacked continuous
// multipliers (turn proximity × lane guidance × sharp turn × congestion × exit
// × overlap × urban cap × long straight × speed boost × ramp), every one keyed
// to noisy inputs (GPS speed ±2 mph, distance-to-turn shrinking every fix).
// The target therefore moved on EVERY tick, and two maneuvers produced the
// signature sawtooth: distance-to-turn decays smoothly into a turn (constant
// zoom-in drift), the instruction advances, distance-to-turn jumps to 2000+ m,
// every multiplier snaps back to 1.0 (instant zoom-out). Repeat forever.
// A deadband + cooldown gate turned that noise into visible 0.5 s steps.
//
// HOW PRODUCTION NAVIGATION CAMERAS WORK (validated against Mapbox Navigation
// SDK's NavigationViewportDataSource docs and observed Apple/Google behaviour):
//
//   1. Zoom derives from a SMALL SET OF DISCRETE LEVELS (road class / speed
//      bands) that change RARELY — never continuously re-derived from raw speed.
//   2. Level switches use HYSTERESIS + DWELL TIME so GPS noise cannot flap a
//      boundary (Mapbox: `distanceToCoalesceCompoundManeuvers`; Schmitt-trigger
//      style band edges).
//   3. Maneuver framing is ONE envelope with a single pitch-flatten trigger
//      (~180 m), not compound keyword heuristics ("then", "exit", "merge"...).
//   4. After passing a maneuver the camera HOLDS its tight framing briefly,
//      then releases slowly — asymmetric tighten/release. This is what kills
//      the post-turn zoom-out whiplash.
//   5. Animation runs on its OWN CLOCK (display link) with bounded rates —
//      completely decoupled from SwiftUI render ticks and their irregular dt.
//
// This file implements exactly that. The public API consumed by LiveMapView,
// CarPlayMapController and the unit tests is unchanged.
//
// Tuning lives in `Resources/CameraTuning.json` (see `CameraTuning` below);
// compile-time fallbacks ship in the binary so a malformed resource degrades
// gracefully to last-known-good behaviour.
// ═══════════════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Tuning schema
// ═══════════════════════════════════════════════════════════════════════════════

/// One discrete cruise framing level. The vehicle occupies level *i* while its
/// smoothed speed is in `(holdSpeedMph, maxSpeedMph]`; switching INTO the level
/// requires exceeding `maxSpeedMph` (or dropping below `holdSpeedMph`) and
/// STAYING there for the governor's dwell time. The wide gap between
/// `holdSpeedMph` and `maxSpeedMph` is the hysteresis band that makes GPS noise
/// unable to flap the camera between levels.
public struct CruiseLevelSpec: Codable, Sendable, Equatable {
    public var maxSpeedMph: Double
    public var holdSpeedMph: Double
    public var altitude: Double
    public var pitch: Double

    public init(maxSpeedMph: Double, holdSpeedMph: Double, altitude: Double, pitch: Double) {
        self.maxSpeedMph = maxSpeedMph
        self.holdSpeedMph = holdSpeedMph
        self.altitude = altitude
        self.pitch = pitch
    }
}

/// Single maneuver-zoom envelope (replaces v1's ten stacked multipliers).
public struct ManeuverTuning: Codable, Sendable, Equatable {
    /// Distance at which tightening begins.
    public var startDistanceM: Double
    /// Distance at which the envelope reaches `minMultiplier` and holds.
    public var fullTightenDistanceM: Double
    /// Altitude multiplier at the maneuver (e.g. 0.5 = half the cruise altitude).
    public var minMultiplier: Double

    public init(startDistanceM: Double, fullTightenDistanceM: Double, minMultiplier: Double) {
        self.startDistanceM = startDistanceM
        self.fullTightenDistanceM = fullTightenDistanceM
        self.minMultiplier = minMultiplier
    }
}

/// Mapbox-style single pitch-flatten trigger near a maneuver.
public struct PitchFlattenTuning: Codable, Sendable, Equatable {
    public var triggerDistanceM: Double
    public var fullFlattenDistanceM: Double
    public var maxFlattenDeg: Double

    public init(triggerDistanceM: Double, fullFlattenDistanceM: Double, maxFlattenDeg: Double) {
        self.triggerDistanceM = triggerDistanceM
        self.fullFlattenDistanceM = fullFlattenDistanceM
        self.maxFlattenDeg = maxFlattenDeg
    }
}

public struct DestinationTuning: Codable, Sendable, Equatable {
    public var startDistanceM: Double
    public var minMultiplier: Double
    public var maxPitchReductionDeg: Double

    public init(startDistanceM: Double, minMultiplier: Double, maxPitchReductionDeg: Double) {
        self.startDistanceM = startDistanceM
        self.minMultiplier = minMultiplier
        self.maxPitchReductionDeg = maxPitchReductionDeg
    }
}

public struct TimingTuning: Codable, Sendable, Equatable {
    /// How long the speed must stay inside a neighbouring band before the
    /// governor commits to it. Multi-band jumps divide this by the jump size.
    public var dwellSeconds: Double
    /// Time constant while TIGHTENING (zooming in / flattening). Fast — the
    /// driver needs the maneuver view promptly.
    public var tightenTauSeconds: Double
    /// Time constant while RELEASING (zooming out / tilting up). Slow — the
    /// gradual release is what reads as "premium" instead of "whiplash".
    public var releaseTauSeconds: Double
    /// Hard ceiling on altitude change rate (m/s) regardless of tau.
    public var altitudeRateCapMPerS: Double
    /// Hard ceiling on pitch change rate (deg/s).
    public var pitchRateCapDegPerS: Double
    /// After passing a maneuver, hold the tight framing this long…
    public var postManeuverHoldSeconds: Double
    /// …then blend to the computed target over this long.
    public var postManeuverReleaseSeconds: Double
    /// EMA time constant applied to raw GPS speed before the governor sees it.
    public var speedSmoothingTauSeconds: Double

    public init(
        dwellSeconds: Double,
        tightenTauSeconds: Double,
        releaseTauSeconds: Double,
        altitudeRateCapMPerS: Double,
        pitchRateCapDegPerS: Double,
        postManeuverHoldSeconds: Double,
        postManeuverReleaseSeconds: Double,
        speedSmoothingTauSeconds: Double
    ) {
        self.dwellSeconds = dwellSeconds
        self.tightenTauSeconds = tightenTauSeconds
        self.releaseTauSeconds = releaseTauSeconds
        self.altitudeRateCapMPerS = altitudeRateCapMPerS
        self.pitchRateCapDegPerS = pitchRateCapDegPerS
        self.postManeuverHoldSeconds = postManeuverHoldSeconds
        self.postManeuverReleaseSeconds = postManeuverReleaseSeconds
        self.speedSmoothingTauSeconds = speedSmoothingTauSeconds
    }
}

/// Decoded shape of `CameraTuning.json`.
public struct CameraTuning: Codable, Sendable, Equatable {
    public var cruiseLevels: [CruiseLevelSpec]
    public var maneuver: ManeuverTuning
    public var pitchFlatten: PitchFlattenTuning
    public var destination: DestinationTuning
    public var timing: TimingTuning

    /// Read and decode the bundled `CameraTuning.json`. Returns `nil` if the
    /// resource is missing or malformed; callers fall back to `CameraTuning.fallback`.
    public static func loadTuning() -> CameraTuning? {
        guard let url = Bundle.main.url(forResource: "CameraTuning", withExtension: "json") else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(CameraTuning.self, from: data)
        } catch {
            DebugLogger.shared.log("CameraTuning.json decode FAILED: \(error.localizedDescription). Using hardcoded fallback tables.")
            return nil
        }
    }

    /// Resolved once per launch: bundle resource if valid, else compile-time fallback.
    public static let current: CameraTuning = {
        loadTuning() ?? .fallback
    }()

    /// Compile-time defaults mirroring `Resources/CameraTuning.json`.
    public static let fallback = CameraTuning(
        cruiseLevels: [
            CruiseLevelSpec(maxSpeedMph: 3,   holdSpeedMph: 0,  altitude: 320,  pitch: 0),
            CruiseLevelSpec(maxSpeedMph: 15,  holdSpeedMph: 11, altitude: 420,  pitch: 16),
            CruiseLevelSpec(maxSpeedMph: 25,  holdSpeedMph: 19, altitude: 560,  pitch: 26),
            CruiseLevelSpec(maxSpeedMph: 35,  holdSpeedMph: 27, altitude: 780,  pitch: 34),
            CruiseLevelSpec(maxSpeedMph: 45,  holdSpeedMph: 35, altitude: 1100, pitch: 42),
            CruiseLevelSpec(maxSpeedMph: 55,  holdSpeedMph: 43, altitude: 1550, pitch: 48),
            CruiseLevelSpec(maxSpeedMph: 65,  holdSpeedMph: 51, altitude: 2100, pitch: 53),
            CruiseLevelSpec(maxSpeedMph: 999, holdSpeedMph: 56, altitude: 2800, pitch: 57)
        ],
        maneuver: ManeuverTuning(startDistanceM: 700, fullTightenDistanceM: 90, minMultiplier: 0.5),
        pitchFlatten: PitchFlattenTuning(triggerDistanceM: 180, fullFlattenDistanceM: 40, maxFlattenDeg: 14),
        destination: DestinationTuning(startDistanceM: 500, minMultiplier: 0.5, maxPitchReductionDeg: 18),
        timing: TimingTuning(
            dwellSeconds: 2.5,
            tightenTauSeconds: 0.6,
            releaseTauSeconds: 1.8,
            altitudeRateCapMPerS: 900,
            pitchRateCapDegPerS: 25,
            postManeuverHoldSeconds: 1.2,
            postManeuverReleaseSeconds: 2.5,
            speedSmoothingTauSeconds: 1.8
        )
    )
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - CameraContext
//
// Stateless snapshot consumed by the decision engine. Built by DriveViewModel
// consumers every tick. Public surface unchanged from v1.
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
    /// Vehicle direction of travel (degrees, 0 = north) the map should orient
    /// UP during turn-by-turn navigation. Supplied by the iPhone map during
    /// active guidance; `nil` leaves heading ownership with MapKit (free
    /// driving, route preview). CarPlay does not read this field — it passes
    /// the course directly via `update(mapView:context:course:)`.
    public let vehicleCourse: Double?

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
        userPitchOverride: DriveViewModel.MapPitchMode,
        vehicleCourse: Double? = nil
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
        self.vehicleCourse = vehicleCourse
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - CameraMode (diagnostics only)
//
// Retained from v1 for debug logging continuity. Mode transitions carry NO
// behavioural weight — all framing maths below is continuous by construction.
// ═══════════════════════════════════════════════════════════════════════════════

public enum CameraMode: String, Sendable {
    case parked
    case freeDrive
    case navigating
    case approachingTurn
    case sharpTurn
    case destinationArrival
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - TargetCameraState
// ═══════════════════════════════════════════════════════════════════════════════

public struct TargetCameraState: Sendable, Equatable {
    /// Camera altitude (`MKMapCamera.centerCoordinateDistance`) in meters.
    public var altitude: Double
    /// Camera pitch in degrees (0 = top-down).
    public var pitch: Double
    /// Retained for API compatibility with v1 callers. v2's kinematics derive
    /// their time constants from movement direction instead.
    public var requestedAnimationTau: TimeInterval?
    /// Retained for API compatibility with v1 callers.
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
// MARK: - CameraMath
//
// Pure scalar helpers shared by the engine, stabilizer, and tests.
// Every function is C¹-continuous across its domain — there are no discrete
// jumps anywhere in the pipeline.
// ═══════════════════════════════════════════════════════════════════════════════

enum CameraMath {
    /// Hermite smoothstep: 0 at x=0, 1 at x=1, zero slope at both ends.
    static func smoothstep(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3.0 - 2.0 * t)
    }

    /// Altitude multiplier for the upcoming-maneuver envelope.
    /// 1.0 beyond `startDistanceM`, easing to `minMultiplier` at
    /// `fullTightenDistanceM` and HOLDING that value underneath it (the hold is
    /// what keeps the camera stable through the maneuver itself instead of
    /// snapping back out the instant DTT bottoms out).
    static func maneuverEnvelope(distance d: CLLocationDistance, _ t: ManeuverTuning) -> Double {
        if d >= t.startDistanceM { return 1.0 }
        if d <= t.fullTightenDistanceM { return t.minMultiplier }
        let x = (t.startDistanceM - d) / (t.startDistanceM - t.fullTightenDistanceM)
        return 1.0 - (1.0 - t.minMultiplier) * smoothstep(x)
    }

    /// Degrees of pitch reduction near a maneuver (Mapbox `pitchNearManeuver`).
    static func pitchFlattenReduction(distance d: CLLocationDistance, _ t: PitchFlattenTuning) -> Double {
        if d >= t.triggerDistanceM { return 0 }
        if d <= t.fullFlattenDistanceM { return t.maxFlattenDeg }
        let x = (t.triggerDistanceM - d) / (t.triggerDistanceM - t.fullFlattenDistanceM)
        return t.maxFlattenDeg * smoothstep(x)
    }

    /// (altitude multiplier, pitch reduction) while closing on the destination.
    static func destinationModifier(distance d: CLLocationDistance, _ t: DestinationTuning)
        -> (multiplier: Double, pitchReduction: Double) {
        if d >= t.startDistanceM { return (1.0, 0.0) }
        let x = smoothstep(d / t.startDistanceM) // 1 far away, 0 at arrival
        let multiplier = t.minMultiplier + (1.0 - t.minMultiplier) * x
        let pitchReduction = t.maxPitchReductionDeg * (1.0 - x)
        return (multiplier, pitchReduction)
    }

    /// Discrete cruise level for a given speed (no hysteresis — pure lookup).
    /// Used by the governor internally and by stateless callers (tests, restore).
    static func quantizeLevel(speedMph: Double, levels: [CruiseLevelSpec]) -> Int {
        return levels.firstIndex(where: { speedMph <= $0.maxSpeedMph }) ?? (levels.count - 1)
    }

    /// Representative speed that deterministically quantizes back to level i.
    /// Feeding this into the engine makes targets EXACTLY the table values —
    /// fully deterministic per level, immune to sub-band speed noise.
    static func anchorSpeed(level i: Int, levels: [CruiseLevelSpec]) -> Double {
        if i >= levels.count - 1 {
            return levels[levels.count - 1].maxSpeedMph + 10.0
        }
        return levels[i].maxSpeedMph * 0.98
    }

    /// Shortest angular wrap of a signed delta (degrees) into -180...180.
    static func angularDistance(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d < -180 { d += 360 }
        return d
    }

    /// Normalize a heading into 0...360.
    static func normalizedHeading(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    /// Rotate `current` toward `target` (degrees) by at most `maxDelta`,
    /// taking the shortest way around the compass (handles the 0/360 wrap).
    static func rotatingApproach(current: Double, target: Double, maxDelta: Double) -> Double {
        let delta = angularDistance(target - current)
        let step = min(max(delta, -maxDelta), maxDelta)
        return normalizedHeading(current + step)
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - CruiseGovernor
//
// The anti-jitter heart: converts a noisy speed stream into a STABLE level
// index using three mechanisms:
//
//   HYSTERESIS — moving DOWN a level requires falling below the current
//   level's `holdSpeedMph`, well beneath the `maxSpeedMph` entry edge. A
//   vehicle cruising near a boundary sits deep inside one level's capture
//   band regardless of ±3 mph GPS noise.
//
//   DWELL WITH DIRECTIONAL RETENTION — any candidate switch must survive
//   for `dwellSeconds` (divided by multi-band jump size). The clock RESETS
//   only when the candidate REVERSES direction relative to the current
//   level; advancing further along the same direction (a continuous
//   deceleration walking down the table) retains the running clock, so a
//   highway exit reframes in one motion instead of paying full dwell at
//   every band edge.
//
//   NAVIGATION DOWN-SHIFT LOCK — during active guidance, low speed (red
//   lights, jams) never pulls the cruise level down: road geometry owns
//   framing there via the maneuver envelope. Only up-shifts are allowed.
//   Free-drive keeps the full hysteresis including relaxing to level 0.
//
// Fully deterministic given injected dates — unit-testable without clocks.
// ═══════════════════════════════════════════════════════════════════════════════

struct CruiseGovernor {
    private let levels: [CruiseLevelSpec]
    private let dwellSeconds: TimeInterval

    private(set) var currentIndex: Int
    private var candidateIndex: Int?
    private var candidateSince: Date?

    init(levels: [CruiseLevelSpec] = CameraTuning.current.cruiseLevels,
         dwellSeconds: TimeInterval = CameraTuning.current.timing.dwellSeconds,
         initialSpeedMph: Double = 0) {
        self.levels = levels
        self.dwellSeconds = dwellSeconds
        self.currentIndex = CameraMath.quantizeLevel(speedMph: initialSpeedMph, levels: levels)
    }

    /// Feed one smoothed speed sample; returns the committed level index.
    mutating func update(speedMph: Double, now: Date, allowPark: Bool) -> Int {
        let current = currentIndex

        var desired = CameraMath.quantizeLevel(speedMph: speedMph, levels: levels)

        if !allowPark {
            // Active guidance: speed dips (lights, traffic) must not downshift
            // the cruise level — only up-shifts are permitted. Framing while
            // slow is owned by the maneuver/destination envelopes.
            desired = max(desired, max(current, 1))
        } else if desired < current, speedMph >= levels[current].holdSpeedMph {
            // Free-drive down-shift hysteresis: inside the current level's
            // hold band we refuse to move down, however long we linger.
            desired = current
        }

        if desired == current {
            candidateIndex = nil
            candidateSince = nil
            return current
        }

        let newDirectionIsUp = desired > current
        if candidateIndex != desired {
            var restarting = candidateSince == nil
            if let existing = candidateIndex {
                let oldDirectionIsUp = existing > current
                restarting = restarting || (oldDirectionIsUp != newDirectionIsUp)
            }
            candidateIndex = desired
            if restarting {
                candidateSince = now
            }
            // Same-direction advancement intentionally KEEPS the running
            // dwell clock (see type doc comment).
        }

        guard let committedCandidate = candidateIndex,
              let since = candidateSince else { return current }
        let jump = abs(committedCandidate - current)
        let effectiveDwell = dwellSeconds / Double(min(jump, 3))
        guard now.timeIntervalSince(since) >= effectiveDwell else {
            return current
        }

        currentIndex = committedCandidate
        candidateIndex = nil
        candidateSince = nil
        #if DEBUG
        DebugLogger.shared.log("CAM cruise level \(current) → \(committedCandidate)")
        #endif
        return committedCandidate
    }

    /// Force-commit a level (used when seeding from a known camera state).
    mutating func force(_ index: Int) {
        currentIndex = max(0, min(index, levels.count - 1))
        candidateIndex = nil
        candidateSince = nil
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - CameraDecisionEngine
//
// Pure computation: context in, ideal target out. No state, no clocks, no side
// effects — identical inputs always yield identical outputs (enforced by test).
//
// Pipeline:
//   1. Quantize speed → cruise level → (base altitude, base pitch).
//   2. Multiply altitude by the single maneuver envelope (navigating only).
//   3. Subtract the single pitch-flatten trigger near the maneuver.
//   4. Apply the destination-arrival modifier (navigating only).
//   5. Clamp; fade pitch to 0 while genuinely stopped; honour user overrides.
//
// The ANIMATOR feeds this function governed inputs (level-anchor speed +
// released-envelope multiplier) so live targets are piecewise-constant and the
// smoothing stage produces long, calm glides rather than constant correction.
// ═══════════════════════════════════════════════════════════════════════════════

public enum CameraDecisionEngine {

    /// Compute the ideal camera state. Stable public API (v1 signature).
    public static func computeTarget(from context: CameraContext) -> TargetCameraState {
        computeTarget(from: context, maneuverMultiplierOverride: nil)
    }

    /// Internal variant letting the stabilizer substitute its post-maneuver
    /// released multiplier for the instantaneous envelope value.
    static func computeTarget(from context: CameraContext,
                              maneuverMultiplierOverride: Double?,
                              tuning: CameraTuning = CameraTuning.current) -> TargetCameraState {

        // ── User-pinned 2D: altitude logic runs, pitch hard-zero ──────────
        if context.userPitchOverride == .forced2D {
            let alt = resolvedAltitude(for: context, tuning: tuning,
                                       maneuverMultiplierOverride: maneuverMultiplierOverride)
            return TargetCameraState(altitude: alt, pitch: 0)
        }

        let levelIdx = CameraMath.quantizeLevel(speedMph: context.speed, levels: tuning.cruiseLevels)
        var altitude = tuning.cruiseLevels[levelIdx].altitude
        var pitch = tuning.cruiseLevels[levelIdx].pitch

        // ── Active guidance modifiers ──────────────────────────────────────
        if context.isNavigating && context.hasRoute {
            let envelope = maneuverMultiplierOverride
                ?? CameraMath.maneuverEnvelope(distance: max(context.distanceToNextTurn, 0), tuning.maneuver)
            altitude *= envelope

            pitch -= CameraMath.pitchFlattenReduction(distance: context.distanceToNextTurn,
                                                      tuning.pitchFlatten)

            let dest = CameraMath.destinationModifier(distance: max(context.destinationDistance, 0),
                                                      tuning.destination)
            altitude *= dest.multiplier
            pitch -= dest.pitchReduction
        }

        // ── Clamp to sane bounds ───────────────────────────────────────────
        altitude = min(max(altitude, 250), 4200)
        pitch = min(max(pitch, 0), 60)

        // ── Stationary pitch fade ──────────────────────────────────────────
        // Smooth Hermite fade over 0–5 mph. Live ticks feed GOVERNED anchor
        // speeds here, so this is all-or-nothing per cruise level (no flicker
        // around the threshold); stateless callers get the gentle fade.
        if context.userPitchOverride == .auto, context.speed < 5.0 {
            pitch *= CameraMath.smoothstep(context.speed / 5.0)
        }

        // ── User pitch overrides win over everything ──────────────────────
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

    private static func resolvedAltitude(for context: CameraContext,
                                         tuning: CameraTuning,
                                         maneuverMultiplierOverride: Double?) -> Double {
        let levelIdx = CameraMath.quantizeLevel(speedMph: context.speed, levels: tuning.cruiseLevels)
        var altitude = tuning.cruiseLevels[levelIdx].altitude
        if context.isNavigating && context.hasRoute {
            let envelope = maneuverMultiplierOverride
                ?? CameraMath.maneuverEnvelope(distance: max(context.distanceToNextTurn, 0), tuning.maneuver)
            altitude *= envelope
            let dest = CameraMath.destinationModifier(distance: max(context.destinationDistance, 0),
                                                      tuning.destination)
            altitude *= dest.multiplier
        }
        return min(max(altitude, 250), 4200)
    }

    /// Diagnostic classification retained for parity with v1 debug logs.
    static func classifyMode(_ ctx: CameraContext) -> CameraMode {
        if ctx.isStationary { return .parked }
        guard ctx.isNavigating else { return .freeDrive }
        if ctx.destinationDistance < 150 { return .destinationArrival }
        if ctx.distanceToNextTurn < 125 { return .sharpTurn }
        if ctx.distanceToNextTurn < 700 { return .approachingTurn }
        return .navigating
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - CameraKinematics
//
// Frame-rate-independent exponential approach with:
//   • ASYMMETRIC time constants — tightening is quick (tau 0.6 s), releasing
//     is unhurried (tau 1.8 s). This mirrors Apple Maps' feel and removes the
//     post-turn "whiplash" even outside hold windows.
//   • HARD RATE CAPS — even a 2000 m target jump converges as a bounded glide,
//     never a snap.
//   • SNAP EPSILON — settles exactly onto the target so residual error can't
//     accumulate.
// Pure functions; unit-testable without MapKit.
// ═══════════════════════════════════════════════════════════════════════════════

enum CameraKinematics {

    static func approach(current: Double,
                         target: Double,
                         dt: TimeInterval,
                         tightenTau: TimeInterval,
                         releaseTau: TimeInterval,
                         rateCapPerSecond: Double,
                         snapEpsilon: Double) -> Double {
        guard dt > 0 else { return current }
        let tau = max(target < current ? tightenTau : releaseTau, 0.01)
        let alpha = 1.0 - exp(-dt / tau)
        var next = current + alpha * (target - current)

        let maxStep = rateCapPerSecond * dt
        let delta = next - current
        if abs(delta) > maxStep {
            next = current + (delta > 0 ? maxStep : -maxStep)
        }

        if abs(target - next) < snapEpsilon {
            next = target
        }
        return next
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - CameraStabilizer
//
// Owns every piece of decision state so the maths stays testable without
// MKMapView or runloops:
//
//   • Speed EMA (τ ≈ 1.8 s) feeding the…
//   • …CruiseGovernor (hysteresis + dwell), whose committed level yields a
//     DETERMINISTIC anchor speed fed into the engine, plus…
//   • …post-maneuver release tracking: when the instruction advances right
//     after a close approach (DTT < 120 m), the tight envelope multiplier is
//     HELD for 1.2 s, then blended toward the computed value over 2.5 s.
//     This replaces v1 behaviors #11/#12 with one mechanism that triggers on
//     geometry, not instruction keywords.
//
// `currentTarget` is refreshed on every `ingest` and consumed by the animator
// at display-link rate.
// ═══════════════════════════════════════════════════════════════════════════════

final class CameraStabilizer {
    private(set) var currentTarget = TargetCameraState(altitude: 320, pitch: 0)
    private(set) var currentLevelIndex = 0

    private var governor: CruiseGovernor
    private var smoothedSpeed: Double = 0
    private var primed = false
    private var lastIngestDate: Date?

    // The raw distance-to-turn can move backwards by tens of metres between
    // GPS fixes. Filter its altitude envelope asymmetrically so a noisy fix
    // can tighten promptly but cannot immediately zoom back out.
    private var filteredManeuverMultiplier: Double?
    private var lastEnvelopeUpdateDate: Date?

    // Post-maneuver release state
    private var lastInstruction: String = ""
    private var lastDTT: CLLocationDistance = 0
    private var releaseStart: Date?
    private var heldMultiplier: Double = 1.0

    private let tuning: CameraTuning

    init(tuning: CameraTuning = CameraTuning.current) {
        self.tuning = tuning
        self.governor = CruiseGovernor(levels: tuning.cruiseLevels,
                                       dwellSeconds: tuning.timing.dwellSeconds)
    }

    /// Consume one application tick. `now` is injectable for tests.
    func ingest(context: CameraContext, now: Date) {
        // 1. Smooth raw GPS speed using the real update interval. SwiftUI and
        // CarPlay do not publish on a guaranteed 500 ms cadence.
        if !primed {
            smoothedSpeed = context.speed
            primed = true
            let initialIndex = CameraMath.quantizeLevel(speedMph: smoothedSpeed, levels: tuning.cruiseLevels)
            governor.force(initialIndex)
            currentLevelIndex = initialIndex
        } else {
            let dt = min(max(now.timeIntervalSince(lastIngestDate ?? now), 0.05), 2.0)
            let tau = max(tuning.timing.speedSmoothingTauSeconds, 0.01)
            let alpha = 1.0 - exp(-dt / tau)
            smoothedSpeed += alpha * (context.speed - smoothedSpeed)
        }
        lastIngestDate = now

        // 2. Post-maneuver release bookkeeping (before computing the target).
        updateReleaseState(context: context, now: now)

        // 3. Govern the cruise level from the smoothed speed.
        let allowPark = !context.isNavigating
        currentLevelIndex = governor.update(speedMph: smoothedSpeed, now: now, allowPark: allowPark)

        // 4. Deterministic anchor speed → engine sees a rock-steady input.
        let anchoredContext = anchoredContext(from: context)

        let hasActiveGuidance = context.isNavigating && context.hasRoute
        let computedEnvelope = hasActiveGuidance
            ? CameraMath.maneuverEnvelope(distance: max(context.distanceToNextTurn, 0), tuning.maneuver)
            : 1.0
        let filteredEnvelope = updateManeuverMultiplier(computed: computedEnvelope, now: now)
        let effectiveEnvelope: Double
        if releaseStart != nil {
            // The explicit post-maneuver hold/release owns the first release
            // after a turn. Do not double-slow that transition with the normal
            // envelope filter.
            effectiveEnvelope = effectiveManeuverMultiplier(computed: computedEnvelope, now: now)
        } else {
            effectiveEnvelope = filteredEnvelope
        }

        currentTarget = CameraDecisionEngine.computeTarget(from: anchoredContext,
                                                           maneuverMultiplierOverride: effectiveEnvelope,
                                                           tuning: tuning)
    }

    /// Seed from a known-good context (used by `restoreCamera`) so the next
    /// ingest continues smoothly instead of ramping from zero.
    func prime(context: CameraContext) {
        smoothedSpeed = context.speed
        primed = true
        lastIngestDate = nil
        let idx = CameraMath.quantizeLevel(speedMph: context.speed, levels: tuning.cruiseLevels)
        currentLevelIndex = idx
        governor.force(idx)
        lastInstruction = context.instruction
        lastDTT = context.distanceToNextTurn

        let hasActiveGuidance = context.isNavigating && context.hasRoute
        filteredManeuverMultiplier = hasActiveGuidance
            ? CameraMath.maneuverEnvelope(distance: max(context.distanceToNextTurn, 0), tuning.maneuver)
            : nil
        lastEnvelopeUpdateDate = nil
        currentTarget = CameraDecisionEngine.computeTarget(
            from: anchoredContext(from: context),
            maneuverMultiplierOverride: filteredManeuverMultiplier,
            tuning: tuning
        )
    }

    /// Full reset — forget speed history and release state.
    func reset() {
        primed = false
        smoothedSpeed = 0
        lastIngestDate = nil
        filteredManeuverMultiplier = nil
        lastEnvelopeUpdateDate = nil
        releaseStart = nil
        heldMultiplier = 1.0
        lastInstruction = ""
        lastDTT = 0
        governor = CruiseGovernor(levels: tuning.cruiseLevels,
                                  dwellSeconds: tuning.timing.dwellSeconds)
        currentLevelIndex = 0
    }

    // ── Private ────────────────────────────────────────────────────────────

    private func updateReleaseState(context: CameraContext, now: Date) {
        guard context.isNavigating else {
            releaseStart = nil
            lastInstruction = context.instruction
            lastDTT = context.distanceToNextTurn
            return
        }

        let instructionChanged = context.instruction != lastInstruction
        let justPassedManeuver = instructionChanged
            && !lastInstruction.isEmpty
            && lastDTT > 0
            && lastDTT < 120

        if justPassedManeuver, releaseStart == nil {
            heldMultiplier = CameraMath.maneuverEnvelope(distance: lastDTT, tuning.maneuver)
            releaseStart = now
            #if DEBUG
            DebugLogger.shared.log("CAM maneuver passed → hold \(Int(tuning.timing.postManeuverHoldSeconds))s, release \(Int(tuning.timing.postManeuverReleaseSeconds))s")
            #endif
        }

        // Coalescing: if we're already tightening toward the NEXT maneuver,
        // the envelope governs — drop any pending release immediately.
        if releaseStart != nil,
           context.distanceToNextTurn <= tuning.maneuver.fullTightenDistanceM * 2 {
            releaseStart = nil
        }

        lastInstruction = context.instruction
        lastDTT = context.distanceToNextTurn
    }

    private func anchoredContext(from context: CameraContext) -> CameraContext {
        CameraContext(
            speed: CameraMath.anchorSpeed(level: currentLevelIndex, levels: tuning.cruiseLevels),
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
    }

    private func updateManeuverMultiplier(computed: Double, now: Date) -> Double {
        guard computed.isFinite else { return filteredManeuverMultiplier ?? 1.0 }
        guard let current = filteredManeuverMultiplier else {
            filteredManeuverMultiplier = computed
            lastEnvelopeUpdateDate = now
            return computed
        }

        let dt = min(max(now.timeIntervalSince(lastEnvelopeUpdateDate ?? now), 0.05), 2.0)
        let tau = max(
            computed < current ? tuning.timing.tightenTauSeconds : tuning.timing.releaseTauSeconds,
            0.01
        )
        let alpha = 1.0 - exp(-dt / tau)
        filteredManeuverMultiplier = current + alpha * (computed - current)
        lastEnvelopeUpdateDate = now
        return filteredManeuverMultiplier ?? computed
    }

    private func effectiveManeuverMultiplier(computed: Double, now: Date) -> Double {
        guard let start = releaseStart else { return computed }
        let hold = max(tuning.timing.postManeuverHoldSeconds, 0)
        let release = max(tuning.timing.postManeuverReleaseSeconds, 0)
        let elapsed = now.timeIntervalSince(start)

        if elapsed < hold {
            return heldMultiplier
        }
        if release <= 0 || elapsed >= hold + release {
            releaseStart = nil
            filteredManeuverMultiplier = computed
            lastEnvelopeUpdateDate = now
            return computed
        }

        let x = CameraMath.smoothstep((elapsed - hold) / release)
        return heldMultiplier + (computed - heldMultiplier) * x
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - CameraAnimator
//
// Thin MainActor shell that:
//   • accepts context updates from SwiftUI/CarPlay at THEIR cadence,
//   • integrates the stabilizer's target on a CADisplayLink (its own clock —
//     immune to irregular render ticks, the root cause of v1's dt bugs),
//   • writes `mapView.camera` ONLY when the write governor approves — the
//     integrated value must have moved beyond a small epsilon AND the
//     minimum write interval must have elapsed. Every camera assignment
//     re-arms MapKit's tracking controller and re-renders tiles, so a
//     30 fps write stream (the display-link rate) reads as strobing;
//     capping writes to ~5/sec leaves MapKit undisturbed between writes.
//   • auto-suspends the link after 3 s without fresh context (detached map,
//     backgrounded app, parked) and resumes on the next update.
//
// CRITICAL (unchanged from v1): use the `mapView.camera` PROPERTY setter, not
// `setCamera(_:animated:)`. With user tracking enabled the property setter
// leaves the tracked center point alone; `setCamera(_:animated:)` can disable
// tracking, and the ensuing tracking-re-enable/reset cycle manifested as rapid
// zoom-in/zoom-out pulses.
// ═══════════════════════════════════════════════════════════════════════════════

@MainActor
final class DisplayLinkProxy: NSObject {
    weak var animator: CameraAnimator?

    @objc func frameTick(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            animator?.frameTick(link)
        }
    }
}

/// Pure, testable write policy for `CameraAnimator`.
///
/// The animator integrates altitude/pitch on its own 30 fps clock, but
/// MapKit must not receive a camera write at that rate: every camera
/// assignment re-arms the tracking controller and re-renders tiles, which
/// reads as visible strobing/stuttering on the map. The governor allows at
/// most one write per `minimumWriteInterval`, and only when the integrated
/// state has actually moved beyond the epsilon thresholds.
struct CameraWriteGovernor {
    let minimumWriteInterval: TimeInterval
    let epsilonAltitude: Double
    let epsilonPitch: Double
    let epsilonHeading: Double

    init(minimumWriteInterval: TimeInterval = 0.2,
         epsilonAltitude: Double = 2.5,
         epsilonPitch: Double = 0.20,
         epsilonHeading: Double = 1.0) {
        self.minimumWriteInterval = minimumWriteInterval
        self.epsilonAltitude = epsilonAltitude
        self.epsilonPitch = epsilonPitch
        self.epsilonHeading = epsilonHeading
    }

    /// True when a camera write is warranted.
    ///
    /// - Parameters:
    ///   - timeSinceLastWrite: seconds since the previous write, or `nil`
    ///     on the first write of a session (always allowed when moved).
    ///   - altitudeDelta: integrated minus currently-applied altitude.
    ///   - pitchDelta: integrated minus currently-applied pitch.
    ///   - headingDelta: shortest angular distance (degrees) between the
    ///     desired and currently-applied map heading.
    func shouldWrite(timeSinceLastWrite: TimeInterval?,
                     altitudeDelta: Double,
                     pitchDelta: Double,
                     headingDelta: Double = 0) -> Bool {
        let moved = abs(altitudeDelta) >= epsilonAltitude
            || abs(pitchDelta) >= epsilonPitch
            || abs(headingDelta) >= epsilonHeading
        guard moved else { return false }
        guard let since = timeSinceLastWrite else { return true }
        return since >= minimumWriteInterval
    }
}

@MainActor
public final class CameraAnimator {
    private var stabilizer = CameraStabilizer()

    private var displayAltitude: Double = 320
    private var displayPitch: Double = 0
    /// Integrated map heading (degrees, 0-360) applied while the animator
    /// owns rotation (active navigation on iPhone, or CarPlay course mode).
    /// nil = MapKit's own tracking owns heading (free driving, route preview).
    private var displayHeading: Double?
    /// Desired "up" direction (vehicle course, 0-360). nil = leave heading to
    /// MapKit's followWithHeading. Supplied by CarPlay via the `course:`
    /// entry point, or by any caller through `CameraContext.vehicleCourse`.
    private var desiredCourse: Double?
    /// True while the animator is walking the camera bearing back to north-up
    /// after course ownership ended (navigation stopped). Keeps ownership of
    /// `camera.heading` during the unwind so the map rotates smoothly back to
    /// north instead of snapping or freezing mid-rotation.
    private var isUnwindingToNorth: Bool = false
    /// Degrees per tick for the post-navigation north-up unwind.
    private let northUnwindStepDeg: Double = 4
    /// Cap on how fast the map may rotate to follow the course (deg/s).
    private let headingRotationRateCapDegPerS: Double = 60

    private weak var attachedMapView: MKMapView?
    private var displayLinkProxy: DisplayLinkProxy?
    private var displayLink: CADisplayLink?
    private var lastFrameTimestamp: CFTimeInterval?
    private var lastContextUpdate: Date = .distantPast
    /// Ignore stale display-link frames after a new target arrives. MapKit may
    /// still be settling a previous camera write; issuing another write during
    /// that settling window is what produces the visible zoom-in strobe.
    private var cameraWriteSuppressedUntil: CFTimeInterval = 0
    /// Timestamp of the most recent camera write (0 = none yet). The write
    /// governor rate-limits MapKit assignments so the display link's 30 fps
    /// integration never turns into a 30 fps camera-write stream — the
    /// visible map strobe/stutter reported in TestFlight.
    private var lastCameraWriteTimestamp: CFTimeInterval = 0
    // A camera assignment can trigger MapKit's own tracking transaction. Keep
    // a quiet settling window after each assignment instead of immediately
    // issuing another assignment on the next governor slot.
    private let cameraSettlingInterval: CFTimeInterval = 0.35
    private let writeGovernor = CameraWriteGovernor()

    private let tuning = CameraTuning.current

    public init() {}

    // ── Main entry point (v1-compatible signature) ────────────────────────
    /// Generic / iPhone path. When `context.vehicleCourse` is supplied
    /// (active turn-by-turn navigation) the animator OWNS map rotation and
    /// orients the vehicle's direction of travel UP — the same model the
    /// CarPlay path uses. This is deliberate: writing the camera for the
    /// altitude/pitch glide dislodges MapKit's `.followWithHeading` compass
    /// tracker, which left the heading beam pointing up while the map stayed
    /// north-up (TestFlight 2.3.0 b640). When `vehicleCourse` is nil (free
    /// driving, route preview) heading stays with MapKit's tracking.
    public func update(mapView: MKMapView, context: CameraContext) {
        desiredCourse = context.vehicleCourse.map { CameraMath.normalizedHeading($0) }
        // When course ownership ends (navigation stopped) unwind the camera
        // bearing back to north-up over the following ticks instead of
        // freezing the map at the last course rotation.
        if desiredCourse == nil, displayHeading != nil {
            isUnwindingToNorth = true
        }
        internalUpdate(mapView: mapView, context: context)
    }

    /// CarPlay path: orient the map so the vehicle's direction of travel
    /// points UP, using the GPS course rather than the car's (unreliable)
    /// compass heading. The heading is rotated toward the course inside the
    /// same rate-limited camera write, so it never re-introduces the strobe.
    public func update(mapView: MKMapView, context: CameraContext, course: Double) {
        desiredCourse = CameraMath.normalizedHeading(course)
        internalUpdate(mapView: mapView, context: context)
    }

    private func internalUpdate(mapView: MKMapView, context: CameraContext) {
        attachedMapView = mapView
        lastContextUpdate = Date()
        // Give MapKit one display interval to finish its own tracking/camera
        // transaction before our next custom write.
        cameraWriteSuppressedUntil = CACurrentMediaTime() + (1.0 / 30.0)

        stabilizer.ingest(context: context, now: lastContextUpdate)
        ensureDisplayLink()
    }

    /// Stop driving the camera (manual detach, search focus, etc.). The next
    /// `update(mapView:context:)` call transparently resumes the loop.
    public func suspend() {
        invalidateDisplayLink()
    }

    /// Seed internal display state from the live map camera.
    public func reset(to mapView: MKMapView) {
        displayAltitude = mapView.camera.centerCoordinateDistance
        displayPitch = Double(mapView.camera.pitch)
        displayHeading = nil
        isUnwindingToNorth = false
        cameraWriteSuppressedUntil = CACurrentMediaTime() + (1.0 / 30.0)
        lastCameraWriteTimestamp = 0
        stabilizer.reset()
    }

    /// Restore the camera after MapKit resumes user tracking following a
    /// manual pan/pinch (v1-compatible signature and behaviour, now backed by
    /// the stable engine output).
    public func restoreCamera(
        on mapView: MKMapView,
        context: CameraContext,
        centerCoordinate: CLLocationCoordinate2D? = nil
    ) {
        let target = CameraDecisionEngine.computeTarget(from: context)
        let trackingMode = mapView.userTrackingMode
        let restoreTracking = trackingMode != .none

        if restoreTracking {
            mapView.setUserTrackingMode(.none, animated: false)
        }

        applyTargetCamera(on: mapView, target: target, centerCoordinate: centerCoordinate)

        if restoreTracking {
            mapView.setUserTrackingMode(trackingMode, animated: false)
            Task { @MainActor [weak self, weak mapView] in
                guard let self, let mapView,
                      mapView.userTrackingMode == trackingMode else { return }
                self.applyTargetCamera(on: mapView, target: target, centerCoordinate: centerCoordinate)
            }
        }

        // Continue smoothing FROM the restored camera with a primed stabilizer
        // so the very next tick doesn't drift or ramp from stale state.
        reset(to: mapView)
        stabilizer.prime(context: context)
    }

    // ── Display-link loop ─────────────────────────────────────────────────

    private func ensureDisplayLink() {
        guard displayLink == nil || displayLink?.isPaused == true else { return }
        if displayLink != nil { displayLink?.invalidate(); displayLink = nil }

        let proxy = DisplayLinkProxy()
        proxy.animator = self
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.frameTick(_:)))
        // 30 fps is ample for altitude/pitch glides and halves CPU/GPU churn on
        // ProMotion displays. MapKit's heading-follow runs at full rate independently.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
        displayLinkProxy = proxy
        lastFrameTimestamp = nil
        cameraWriteSuppressedUntil = CACurrentMediaTime() + (1.0 / 30.0)
    }

    private func invalidateDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy = nil
        lastFrameTimestamp = nil
    }

    fileprivate func frameTick(_ link: CADisplayLink) {
        guard let mapView = attachedMapView else {
            invalidateDisplayLink()
            return
        }

        // Watchdog: no fresh context for 3 s (detached, searching, parked,
        // backgrounded) — stop ticking until the next update arrives.
        if Date().timeIntervalSince(lastContextUpdate) > 3.0 {
            invalidateDisplayLink()
            return
        }

        guard link.timestamp >= cameraWriteSuppressedUntil else { return }

        let target = stabilizer.currentTarget
        var dt: TimeInterval = 1.0 / 30.0
        if let last = lastFrameTimestamp {
            dt = min(max(link.timestamp - last, 0.001), 0.1)
        }
        lastFrameTimestamp = link.timestamp

        displayAltitude = CameraKinematics.approach(
            current: displayAltitude,
            target: target.altitude,
            dt: dt,
            // Zoom-in is intentionally slower than zoom-out. This avoids
            // rapid repeated altitude changes when GPS/map gestures update
            // the target in quick succession.
            tightenTau: max(tuning.timing.tightenTauSeconds, 1.2),
            releaseTau: tuning.timing.releaseTauSeconds,
            rateCapPerSecond: min(tuning.timing.altitudeRateCapMPerS, 85),
            snapEpsilon: 0.75
        )
        displayPitch = CameraKinematics.approach(
            current: displayPitch,
            target: target.pitch,
            dt: dt,
            tightenTau: tuning.timing.tightenTauSeconds,
            releaseTau: tuning.timing.releaseTauSeconds,
            rateCapPerSecond: tuning.timing.pitchRateCapDegPerS,
            snapEpsilon: 0.02
        )

        // Course heading (CarPlay `course:` entry point, or the iPhone
        // navigation path through `CameraContext.vehicleCourse`): rotate the
        // map so the vehicle's direction of travel points up. GPS course is
        // already smooth, so this is a light, rate-capped step (handles the
        // 0/360 wrap) rather than a discrete jump.
        if let desiredCourse {
            isUnwindingToNorth = false
            if displayHeading == nil {
                displayHeading = desiredCourse
            } else {
                displayHeading = CameraMath.rotatingApproach(
                    current: displayHeading!,
                    target: desiredCourse,
                    maxDelta: headingRotationRateCapDegPerS * dt
                )
            }
        } else if isUnwindingToNorth, let currentHeading = displayHeading {
            // Post-navigation unwind: walk the bearing back to north-up at a
            // fixed gentle pace. Delta-based termination covers any starting
            // bearing (up to a full 180° swing). On convergence, release
            // heading ownership entirely: the last written bearing rests
            // within one step of north (imperceptible), and a nil
            // `displayHeading` guarantees the governor can never fight a
            // later user rotation during free driving.
            let delta = CameraMath.angularDistance(0 - currentHeading)
            if abs(delta) <= northUnwindStepDeg {
                displayHeading = nil
                isUnwindingToNorth = false
            } else {
                displayHeading = CameraMath.rotatingApproach(
                    current: currentHeading,
                    target: 0,
                    maxDelta: northUnwindStepDeg
                )
            }
        }

        // Governor-gated write: only touch MapKit when the integrated state
        // moved beyond epsilon AND the minimum write interval has elapsed.
        // The display link integrates at 30 fps, but writing the map camera
        // at that rate re-arms MapKit's tracking controller and re-renders
        // tiles on every frame — the classic nav-map strobe. A bounded write
        // cadence keeps the glide smooth while leaving MapKit completely
        // undisturbed between writes.
        let camCurrentAlt = mapView.camera.centerCoordinateDistance
        let camCurrentPitch = Double(mapView.camera.pitch)
        let camCurrentHeading = Double(mapView.camera.heading)
        let headingDelta = displayHeading.map { abs(CameraMath.angularDistance($0 - camCurrentHeading)) } ?? 0
        let timeSinceLastWrite: TimeInterval? = lastCameraWriteTimestamp == 0
            ? nil
            : link.timestamp - lastCameraWriteTimestamp
        guard lastCameraWriteTimestamp == 0
                || link.timestamp - lastCameraWriteTimestamp >= cameraSettlingInterval else { return }
        guard writeGovernor.shouldWrite(
            timeSinceLastWrite: timeSinceLastWrite,
            altitudeDelta: displayAltitude - camCurrentAlt,
            pitchDelta: displayPitch - camCurrentPitch,
            headingDelta: headingDelta
        ) else { return }
        lastCameraWriteTimestamp = link.timestamp

        let cam = mapView.camera.copy() as! MKMapCamera
        cam.centerCoordinateDistance = displayAltitude
        cam.pitch = CGFloat(displayPitch)
        if let displayHeading {
            cam.heading = displayHeading
        }
        let trackingMode = mapView.userTrackingMode
        // Property setter (iOS 13+) — see class doc comment for why this must
        // never become setCamera(_:animated:) while tracking is active.
        mapView.camera = cam
        // A direct camera assignment can displace MapKit's tracking
        // controller (follow-with-heading drops back to .none). Re-assert
        // the mode in the SAME turn so the map is never left untracked
        // between writes; the recenter is a no-op because the write
        // preserved the tracked center coordinate. Without this, the map
        // sits untracked until the next SwiftUI pass re-engages it — the
        // 2 Hz recenter snap that reads as convulsing/spasming.
        if trackingMode != .none, mapView.userTrackingMode != trackingMode {
            mapView.setUserTrackingMode(trackingMode, animated: false)
        }
    }

    private func applyTargetCamera(
        on mapView: MKMapView,
        target: TargetCameraState,
        centerCoordinate: CLLocationCoordinate2D?
    ) {
        let camera = mapView.camera.copy() as! MKMapCamera
        if let centerCoordinate {
            camera.centerCoordinate = centerCoordinate
        }
        camera.centerCoordinateDistance = target.altitude
        camera.pitch = CGFloat(target.pitch)
        mapView.camera = camera
    }
}
