// HapticAlertManager.swift
//
// Single facade over CHHapticEngine so the rest of the app can ask for
// "play me a 'Strong Pulse' haptic" without owning the engine lifecycle,
// knowing the catalog of patterns, knowing how to translate a user-recorded
// tap sequence into a CHHapticPattern, or checking for simulator / iPad
// capability.
//
// TestFlight v2.2.0 (b365) customer feedback (srihan.yeleswarapu@gmail.com):
//   "Maybe right below audio alerts toggle, put haptic alerts selection
//    bar. U should be able to select what type of vibration haptic you
//    want when your speeding. You should also be able to record your
//    own haptic by clicking on the screen and translating that into a
//    haptic sequence."
//
// AlertEngine previously called a hard-coded `hapticSpeedingAlert()` (an
// aggressive 12-event-per-second transient barrage) on every overspeed tick.
// That function has been removed so the user-configurable style below is
// the single source of truth — no more doubling up with Auto-Vibrate.

import Foundation
import CoreHaptics
import SwiftUI
import AudioToolbox

// MARK: - Public catalog

/// Every haptic style the user can pick from in the Settings UI.
/// Persisted as a raw string in `@AppStorage("hapticAlertStyle")`.
public enum HapticStyle: String, CaseIterable, Codable, Sendable {
    case off     = "off"
    case soft    = "soft"
    case strong  = "strong"
    case triple  = "triple"
    case warning = "warning"
    case custom  = "custom"

    public var displayName: String {
        switch self {
        case .off:     return "Off"
        case .soft:    return "Soft Tap"
        case .strong:  return "Strong Pulse"
        case .triple:  return "Triple Tap"
        case .warning: return "Warning Buzz"
        case .custom:  return "Custom (Recorded)"
        }
    }
}

/// One captured tap from the recording UI. `timeOffset` is seconds since
/// the recording started; `intensity` is 0.0-1.0. Persisted as a JSON
/// `[HapticTapEvent]` under `@AppStorage("hapticCustomPattern")`.
public struct HapticTapEvent: Codable, Equatable, Sendable {
    public let timeOffset: TimeInterval
    public let intensity: Double

    public init(timeOffset: TimeInterval, intensity: Double) {
        self.timeOffset = max(0.0, timeOffset)
        self.intensity  = max(0.0, min(1.0, intensity))
    }

    /// Two-tap fallback used if the user has selected "Custom" but hasn't
    /// actually recorded anything yet. Keeps the experience non-empty.
    public static let fallback: [HapticTapEvent] = [
        HapticTapEvent(timeOffset: 0.00, intensity: 1.0),
        HapticTapEvent(timeOffset: 0.18, intensity: 0.7),
    ]
}

// MARK: - Manager

/// `@MainActor` so callers (AlertEngine on the main thread) can fire without
/// `await` ceremony. Backed by a static `shared` because the CHHapticEngine
/// is a single-process resource — multiple instances would tear each other
/// down on `resetHandler` callbacks.
@MainActor
public final class HapticAlertManager: ObservableObject {

    public static let shared = HapticAlertManager()

    // User preferences — read/written directly to UserDefaults. We
    // intentionally do NOT use @AppStorage here because it conforms to
    // DynamicProperty and is meant for SwiftUI Views, not for an
    // @MainActor ObservableObject singleton like ourselves. Accessing a
    // non-static @AppStorage property from inside a SwiftUI
    // ViewBuilder's conditional expression has been observed to
    // silently truncate the form rendering graph (no fatal crash — see
    // TestFlight v2.2.0 b367 feedback where the entire haptic alerts
    // block disappeared from Settings → ALERTS on a taptic-capable
    // iPhone while the Audio Alerts toggle above it continued to
    // render). UserDefaults is the SwiftUI-environment-safe primitive
    // here; the @AppStorage mirror lives on `SettingsView` (which is
    // the SwiftUI View-side reactive source of truth).
    public var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "hapticAlertsEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "hapticAlertsEnabled") }
    }

    public var styleRaw: String {
        get { UserDefaults.standard.string(forKey: "hapticAlertStyle") ?? HapticStyle.strong.rawValue }
        set { UserDefaults.standard.set(newValue, forKey: "hapticAlertStyle") }
    }

    // Custom pattern storage. We store `[HapticTapEvent]` JSON instead of a
    // serialized `CHHapticPattern` because Apple's archival format changes
    // occasionally; raw event times are resilient.
    public var customPatternData: Data {
        get { UserDefaults.standard.data(forKey: "hapticCustomPattern") ?? Data() }
        set { UserDefaults.standard.set(newValue, forKey: "hapticCustomPattern") }
    }

    /// Underlying engine — nil on simulator or any device without haptic
    /// hardware. We DO still construct the manager so the rest of the app
    /// sees a single "fireIfEnabled()" entry point; the fallback path inside
    /// covers the engine==nil case.
    private var engine: CHHapticEngine?

    /// Whether the running hardware supports Core Haptics. iPads return
    /// `false` and the Settings UI hides the haptic controls for them.
    /// Single source of truth — exposed as instance property on the
    /// shared singleton (`HapticAlertManager.shared.deviceSupportsHaptics`).
    public let deviceSupportsHaptics: Bool

    /// Convenience computed var for the current style value.
    public var style: HapticStyle {
        get { HapticStyle(rawValue: styleRaw) ?? .strong }
        set { styleRaw = newValue.rawValue }
    }

    // MARK: - Settings-preview path (picker auditions)

    /// Throttle state for the Settings Picker preview path so a wheel-style
    /// picker can't queue dozens of preview patterns per second. 400 ms is
    /// enough room for the longest built-in pattern (`.warning` is a 0.5 s
    /// continuous event) to play out before the next preview starts;
    /// shorter intervals would cut off mid-play.
    private var lastPreviewTime: Date = .distantPast
    // 0.6 s so the longest built-in pattern (`.warning` is a 0.5 s
    // `hapticContinuous` event) finishes playing before the next
    // preview starts. 0.4 s (initial v1) was tight and risked audible
    // overlap with `.warning`'s tail. Settings picker is non-spammy by
    // spec, so 0.6 s feels interactive on each tap.
    private let previewMinInterval: TimeInterval = 0.6

    /// Play a one-shot preview of the currently selected HapticStyle so the
    /// user can audition styles from the Settings picker without waiting to
    /// go speeding (TestFlight v2.2.0 b366 customer feedback —
    /// srihan.yeleswarapu@gmail.com: "In the Haptic Style thing, when i
    /// select one, I want to feel a sample of it. Like how am I supposed
    /// to know how that feels like?").
    ///
    /// Contract:
    ///   * **Bypasses `isEnabled`** — interacting with the style catalog
    ///     implies a desire to feel the styles, regardless of the master
    ///     on/off toggle. `fireIfEnabled()` is the gated path; this is the
    ///     "always playable" path.
    ///   * **Silent on `.off`** — vibrating when the user explicitly chose
    ///     "Off" breaks the semantic trust of the option; they want silence.
    ///   * **Silent on non-taptic hardware** — iPad picker row is already
    ///     hidden in `SettingsView` behind `deviceSupportsHaptics`, but
    ///     this guard keeps parity if the row is ever exposed elsewhere.
    ///   * **Throttled ≥400 ms** — prevents wheel-style pickers from
    ///     spamming patterns at 30 ms cadence.
    public func previewCurrentStyle() {
        // Settings preview is always-on regardless of the master on/off
        // toggle — only `fireIfEnabled()` honors `isEnabled`.
        guard deviceSupportsHaptics else { return }

        // Honoring the explicit "Off" choice: even though
        // `currentPattern()` returns nil for `.off`, the explicit guard
        // here makes the silence-on-off contract visible AND prevents
        // repeated `.off` taps from burning the throttle clock without
        // actually firing anything (caught in code-review).
        guard style != .off else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPreviewTime) >= previewMinInterval else { return }
        lastPreviewTime = now
        guard let pattern = currentPattern() else { return }
        playPattern(pattern)
    }

    private init() {
        self.deviceSupportsHaptics =
            CHHapticEngine.capabilitiesForHardware().supportsHaptics
        setupEngine()
    }

    private func setupEngine() {
        guard deviceSupportsHaptics else {
            DebugLogger.shared.log("HapticAlertManager: no hardware support; will fall back to system vibrate")
            return
        }
        do {
            let engine = try CHHapticEngine()
            engine.stoppedHandler = { reason in
                DebugLogger.shared.log("HapticAlertManager stopped: \(reason.rawValue)")
            }
            engine.resetHandler = { [weak self] in
                guard let self else { return }
                do {
                    try self.engine?.start()
                } catch {
                    DebugLogger.shared.log("HapticAlertManager restart failed: \(error.localizedDescription)")
                }
            }
            try engine.start()
            self.engine = engine
        } catch {
            DebugLogger.shared.log("HapticAlertManager setup error: \(error.localizedDescription)")
            self.engine = nil
        }
    }

    // MARK: - Public API

    /// Play the configured haptic *style* (if master toggle on AND style != .off).
    /// Callers (AlertEngine) drive this on their own 2 s cooldown.
    public func fireIfEnabled() {
        guard isEnabled else { return }
        guard style != .off else { return }
        // iPad / Simulator (or any device whose hardware reports
        // `supportsHaptics == false`): we don't have a taptic engine to
        // deliver the chosen style. Stay silent rather than falling back
        // to a phantom system vibrate — the user didn't pick "Off" so they
        // expect a vibration that matches the selected style, but a generic
        // kSystemSoundID_Vibrate buzz deceives them.
        guard deviceSupportsHaptics else { return }
        guard let pattern = currentPattern() else {
            // Engine exists but pattern build failed (e.g. malformed custom
            // event list). Single universal vibrate is the right fallback
            // here — beats going silent on a hardware-capable device.
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            return
        }
        playPattern(pattern)
    }

    /// Returns the CHHapticPattern for the current style setting — exposed so
    /// the recording-preview UI can use the same builder path without a
    /// dedicated preview-only function.
    public func currentPattern() -> CHHapticPattern? {
        guard deviceSupportsHaptics else { return nil }
        let events: [CHHapticEvent]
        switch style {
        case .off:
            return nil
        case .soft:
            events = [
                CHHapticEvent(eventType: .hapticTransient,
                              parameters: [
                                .init(parameterID: .hapticIntensity, value: Float(0.5)),
                                .init(parameterID: .hapticSharpness, value: Float(0.4))
                              ],
                              relativeTime: 0)
            ]
        case .strong:
            events = [
                CHHapticEvent(eventType: .hapticTransient,
                              parameters: [
                                .init(parameterID: .hapticIntensity, value: Float(1.0)),
                                .init(parameterID: .hapticSharpness, value: Float(1.0))
                              ],
                              relativeTime: 0)
            ]
        case .triple:
            events = stride(from: 0.0, through: 0.26, by: 0.13).map { t in
                CHHapticEvent(eventType: .hapticTransient,
                              parameters: [
                                .init(parameterID: .hapticIntensity, value: Float(0.9)),
                                .init(parameterID: .hapticSharpness, value: Float(0.7))
                              ],
                              relativeTime: t)
            }
        case .warning:
            events = [
                CHHapticEvent(eventType: .hapticContinuous,
                              parameters: [
                                .init(parameterID: .hapticIntensity, value: Float(0.9)),
                                .init(parameterID: .hapticSharpness, value: Float(0.3))
                              ],
                              relativeTime: 0,
                              duration: 0.5)
            ]
        case .custom:
            events = customEvents().map { tap in
                CHHapticEvent(eventType: .hapticTransient,
                              parameters: [
                                .init(parameterID: .hapticIntensity, value: Float(tap.intensity)),
                                .init(parameterID: .hapticSharpness, value: Float(0.5))
                              ],
                              relativeTime: tap.timeOffset)
            }
        }
        guard !events.isEmpty else { return nil }
        do {
            return try CHHapticPattern(events: events, parameters: [])
        } catch {
            DebugLogger.shared.log("HapticAlertManager pattern build error: \(error.localizedDescription)")
            return nil
        }
    }

    /// Persist a captured tap sequence (.custom). Also auto-selects .custom
    /// style so the user doesn't have to flip the picker after recording.
    public func saveCustomPattern(_ taps: [HapticTapEvent]) {
        guard !taps.isEmpty else { return }
        // Sort + clamp — the recording UI caps at 5.0 s. We re-clamp here so
        // a future caller (TestFlight simulator, future "import pattern"
        // feature) can't bypass the limit by handing a pre-built array.
        let clamped = taps
            .sorted { $0.timeOffset < $1.timeOffset }
            .filter { $0.timeOffset <= 5.0 }
        guard !clamped.isEmpty else { return }
        do {
            let data = try JSONEncoder().encode(clamped)
            customPatternData = data
            style = .custom
        } catch {
            DebugLogger.shared.log("HapticAlertManager save error: \(error.localizedDescription)")
        }
    }

    /// Play a *candidate* (not-yet-saved) tap sequence so the recording UI
    /// can offer a "Preview" button.
    public func previewCandidate(_ taps: [HapticTapEvent]) {
        guard !taps.isEmpty else { return }
        guard deviceSupportsHaptics, let engine = engine else {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            return
        }
        let events = taps.map { tap in
            CHHapticEvent(eventType: .hapticTransient,
                          parameters: [
                            .init(parameterID: .hapticIntensity, value: Float(tap.intensity)),
                            .init(parameterID: .hapticSharpness, value: Float(0.5))
                          ],
                          relativeTime: tap.timeOffset)
        }
        do {
            try engine.start()
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            DebugLogger.shared.log("HapticAlertManager preview error: \(error.localizedDescription)")
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }

    // MARK: - Internals

    private func customEvents() -> [HapticTapEvent] {
        guard !customPatternData.isEmpty,
              let decoded = try? JSONDecoder().decode([HapticTapEvent].self,
                                                     from: customPatternData),
              !decoded.isEmpty else {
            return HapticTapEvent.fallback
        }
        return decoded
    }

    private func playPattern(_ pattern: CHHapticPattern) {
        guard let engine = engine else {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            return
        }
        do {
            // (Re-)start before each play so a backgrounded engine that came
            // back to the foreground is alive when we ask for a player.
            try engine.start()
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            DebugLogger.shared.log("HapticAlertManager play error: \(error.localizedDescription)")
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }
}
