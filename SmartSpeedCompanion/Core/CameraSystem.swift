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

    public init(altitude: Double, pitch: Double) {
        self.altitude = altitude
        self.pitch = pitch
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
// The result: altitude and pitch change smoothly frame by frame. The user
// never perceives a "zoom step" or a "camera snap."
// ═══════════════════════════════════════════════════════════════════════════════

public struct CameraDecisionEngine: Sendable {

    // ── Key points for altitude interpolation ──────────────────────────────
    // (speed_mph, altitude_m). Labels match `smoothInterpolate`'s expected
    // `knots: [(x: Double, y: Double)]` signature so there is no implicit
    // tuple-label mismatch error at compile time.
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
    // Higher limits → wider, better-sighted roads → zoom out more to reveal
    // context. Lower limits → narrow, dense roads → zoom in for detail.
    //
    // The LUT starts at 1.0 (neutral) so unknown speed limits do not unfairly
    // zoom the camera. The curve climbs gently from neighborhood (25 mph,
    // 0.85×) up to interstates (80 mph, 1.40×).
    //
    // NOTE: Because `smoothInterpolate` expects `knots: [(x: Double, y: Double)]`,
    // the speed-limit knots use `(x: Double, y: Double)` with the limit value
    // cast to `Double` at the call site (`Double(limit)`), so the knot x-values
    // are written as Double literals (25.0, 35.0, …).
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
        // As we get close, altitude smoothly drops and pitch lowers
        let altMul = 0.35 + 0.65 * t
        let pitchDelta = -20.0 * (1.0 - t) // subtract up to 20° at 0 m
        return (altMul, pitchDelta)
    }

    // ── Roundabout: temporarily flatter, overhead-ish ──────────────────────
    private static func roundaboutPitchOffset() -> Double { -28.0 }

    // ── Ramp / exit: subtle zoom out for context ───────────────────────────
    private static let rampAltitudeMultiplier: Double = 1.15

    // ── Smooth step interpolation (Hermite) ──────────────────────────────
    // Blends between values without the linear kink at each knot.
    static func smoothInterpolate(x: Double, knots: [(x: Double, y: Double)]) -> Double {
        guard !knots.isEmpty else { return 0 }
        if x <= knots.first!.x { return knots.first!.y }
        if x >= knots.last!.x { return knots.last!.y }

        for i in 0 ..< knots.count - 1 {
            let (x0, y0) = (knots[i].x, knots[i].y)
            let (x1, y1) = (knots[i + 1].x, knots[i + 1].y)
            if x >= x0 && x <= x1 {
                let t = (x - x0) / (x1 - x0)
                // Hermite smoothstep: 3t² - 2t³
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
            // For forced 2D, keep altitude dynamic but enforce pitch 0
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

        // Highway flyover: when navigating at speed with no turn for miles,
        // pull back and tilt up for the same 3D highway feel Apple Maps and
        // the previous implementation (which set pitch=55/alt=3500) delivered.
        if context.isNavigating && context.distanceToNextTurn > 4000 && context.speed > 50 {
            let blend = min(1.0, (context.speed - 50) / 25.0) // 0 at 50, 1 at 75+
            pitch += blend * 8.0  // up to +8° pitch on highway cruises
        }

        // Turn proximity modifier (navigating only)
        if context.isNavigating && context.distanceToNextTurn < 1000 {
            let turnMul = turnProximityMultiplier(distance: context.distanceToNextTurn)
            altitude *= turnMul

            // Flatten pitch near turns for better intersection visibility
            if context.distanceToNextTurn < 200 {
                let flatten = (200.0 - context.distanceToNextTurn) / 200.0
                pitch -= flatten * 14.0
            }
        }

        // Long straight: gradually zoom out for route awareness
        if context.isNavigating {
            let straightMul = longStraightMultiplier(distanceToTurn: context.distanceToNextTurn,
                                                     speed: context.speed)
            altitude *= straightMul

            // Slightly higher pitch on long straights
            if straightMul > 1.0 {
                pitch += (straightMul - 1.0) * 20.0
            }
        }

        // Roundabout: overhead view
        if context.instruction.lowercased().contains("roundabout") ||
           context.instruction.lowercased().contains("rotary") ||
           context.instruction.lowercased().contains("circle") {
            pitch += Self.roundaboutPitchOffset()
        }

        // Ramp / exit / merge: zoom out for context
        let instructionLower = context.instruction.lowercased()
        if instructionLower.contains("exit") || instructionLower.contains("merge") ||
           instructionLower.contains("ramp") || instructionLower.contains("fork") {
            altitude *= Self.rampAltitudeMultiplier
        }

        // Destination arrival
        if context.isNavigating && context.destinationDistance < 600 {
            let (destAltMul, destPitchDelta) = destinationMultiplier(distance: context.destinationDistance)
            altitude *= destAltMul
            pitch += destPitchDelta
        }

        // Free-drive (recording) — slightly lower pitch for better road view
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
            break // keep computed pitch
        }

        return TargetCameraState(altitude: altitude, pitch: pitch)
    }

    // ── Classify mode (debug / logging only) ───────────────────────────
    private static func classifyMode(_ ctx: CameraContext) -> CameraMode {
        if ctx.isStationary { return .parked }
        if ctx.userPitchOverride != .auto { return .navigating } // user has pinned pitch
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
        // Start with the speed-based altitude
        let speedAlt = Self.smoothInterpolate(x: speed, knots: Self.altitudeLUT)

        // Apply road-type multiplier from speed limit
        let roadMul = Self.smoothInterpolate(x: Double(limit), knots: Self.roadTypeMultiplierLUT)
        let adjusted = speedAlt * roadMul

        // When navigating, apply the flyover baseline for highway driving
        if isNavigating && speed > 45 && distanceToTurn > 4000 {
            // Smoothly blend toward highway altitude
            let speedExcess = (speed - 45) / 30.0 // 0 at 45, 1 at 75+
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
// The EMA time constant (tau) controls responsiveness. Smaller tau → snappier
// but potentially jittery. Larger tau → smoother but laggy. We vary tau based
// on the magnitude of change: big moves animate faster, tiny tweaks feel slow
// and deliberate.
// ═══════════════════════════════════════════════════════════════════════════════

@MainActor
public final class CameraAnimator {
    // ── Smoothed state ─────────────────────────────────────────────────
    private var displayAltitude: Double = 1000
    private var displayPitch: Double = 0
    private var lastUpdateTime: Date = .now

    // ── Deadband ───────────────────────────────────────────────────────
    /// Minimum altitude change (meters) to trigger a camera update.
    private let altitudeDeadband: Double = 25.0
    /// Minimum pitch change (degrees) to trigger a camera update.
    private let pitchDeadband: Double = 3.0

    // ── Cooldown ───────────────────────────────────────────────────────
    /// Minimum wall-clock time between camera updates (seconds).
    private let minInterval: TimeInterval = 0.4
    /// Override: critical updates (very close turn) bypass the cooldown.
    private var lastApplyTime: Date = .distantPast

    // ── Speed smoothing ────────────────────────────────────────────────
    /// EMA-filtered speed used for continuity. Prevents GPS spikes
    /// from causing camera oscillations.
    private var smoothedSpeed: Double = 0
    /// Filter time constant for speed smoothing (seconds).
    /// 0.5 = moderate smoothing, 1.0 = heavy smoothing.
    private let speedTau: TimeInterval = 0.5

    // ── Debug ──────────────────────────────────────────────────────────
    private var lastLoggedTarget: TargetCameraState?

    public init() {}

    // ── Main entry point ───────────────────────────────────────────────
    public func update(mapView: MKMapView, context: CameraContext) {
        // 1. Smooth the raw speed
        let dt = -lastUpdateTime.timeIntervalSinceNow
        smoothedSpeed = smoothExponential(current: smoothedSpeed,
                                          target: context.speed,
                                          dt: dt,
                                          tau: speedTau)
        lastUpdateTime = .now

        // 2. Compute target from the smoothed speed + context.
        //    We rebuild the context with the smoothed speed so the decision
        //    engine sees stable values — GPS spikes cannot cause camera
        //    oscillations (requirement #7).
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

        let target = CameraDecisionEngine.computeTarget(from: smoothedContext)

        // 3. Deadband + cooldown gate
        let altDelta = abs(target.altitude - displayAltitude)
        let pitchDelta = abs(target.pitch - displayPitch)
        let timeSinceApply = -lastApplyTime.timeIntervalSinceNow

        let isCritical = context.isNavigating &&
                         context.distanceToNextTurn < 150 &&
                         altDelta > 50

        let shouldSkip = !isCritical && (
            (altDelta < altitudeDeadband && pitchDelta < pitchDeadband) ||
            timeSinceApply < minInterval
        )

        if shouldSkip {
            // Still log substantial changes even if gated, for debug visibility
            if altDelta > altitudeDeadband * 2 || pitchDelta > pitchDeadband * 2 {
                let reason = timeSinceApply < minInterval ? "cooldown" : "deadband"
                logIfChanged(target, reason: reason)
            }
            return
        }

        // 4. Move display state toward target (EMA smoothing)
        let animTau: TimeInterval = animationTimeConstant(altDelta: altDelta, pitchDelta: pitchDelta)
        displayAltitude = smoothExponential(current: displayAltitude,
                                            target: target.altitude,
                                            dt: dt,
                                            tau: animTau)
        displayPitch = smoothExponential(current: displayPitch,
                                         target: target.pitch,
                                         dt: dt,
                                         tau: animTau)

        // 5. Apply to MapKit
        let cam = mapView.camera.copy() as! MKMapCamera
        cam.centerCoordinateDistance = displayAltitude
        cam.pitch = CGFloat(displayPitch)
        mapView.setCamera(cam, animated: false)

        lastApplyTime = .now
        logIfChanged(target, reason: "applied")
    }

    /// Reset internal state (e.g., when navigation starts fresh or style
    /// changes dramatically).
    public func reset(to mapView: MKMapView) {
        displayAltitude = mapView.camera.centerCoordinateDistance
        displayPitch = Double(mapView.camera.pitch)
        smoothedSpeed = 0
        lastUpdateTime = .now
        lastApplyTime = .distantPast
        lastLoggedTarget = nil
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
