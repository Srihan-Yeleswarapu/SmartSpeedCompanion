// Path: Core/BackgroundHapticBridge.swift
//
// Background vibration fallback for overspeed alerts.
//
// WHY THIS EXISTS
// iOS forbids third-party apps from driving the taptic engine
// (CHHapticEngine / UINotificationFeedbackGenerator / AudioServices
// kSystemSoundID_Vibrate) while the app is backgrounded. When the user
// leaves Speedio to use another app (YouTube, Maps, etc.) or locks the
// phone in a holder, the `HapticAlertManager` speeding pulse therefore
// goes silent even though GPS keeps running. The ONE sanctioned way to
// request a background buzz is a local notification with a sound attached —
// the system's notification vibration accompanies it.
//
// The trick: we attach a SILENT sound file (Resources/silent_alert.wav)
// so the notification can vibrate without adding an audible alert. This
// preserves the user's "audio alerts OFF" choice. Users who keep Sounds ON
// for Speedio in Settings → Notifications get the buzz with no audible tone.
//
// CAVEATS (documented for the Settings footer)
//   • Requires notification permission — requested when the toggle is
//     switched on and again at session start when the toggle is enabled.
//   • Respects the user's iPhone settings: Focus modes, Do Not Disturb, or
//     Sounds switched off for the app can silence the buzz.
//   • The buzz cadence is throttled (15 s) — notifications are delivered
//     by the system and should not be spammed.

import Foundation
import UIKit
import UserNotifications
import CarPlay

@MainActor
public final class BackgroundHapticBridge {

    public static let shared = BackgroundHapticBridge()

    // ── Preference ────────────────────────────────────────────────────
    /// Persisted master switch ("Vibrate in Background" in Settings →
    /// ALERTS). Defaults OFF so enabling it is an explicit, discoverable
    /// opt-in — and so the notification-permission prompt only ever
    /// appears when the user actually asks for this behavior.
    private let defaultsKey = "backgroundVibrationAlertsEnabled"
    public var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    // ── Throttle ──────────────────────────────────────────────────────
    /// Minimum gap between two background buzzes while still over the
    /// limit. 15 s ≈ one buzz every quarter minute of sustained speeding —
    /// frequent enough to feel in a pocket, sparse enough to avoid
    /// notification spam, lock-screen stacking, and iOS's per-app daily
    /// notification budget (every buzz is a distinct delivered alert).
    private var lastAlertAt: Date = .distantPast
    private let alertInterval: TimeInterval = 15.0

    private init() {}

    // MARK: - Permission

    /// Requests notification authorization (`.alert` + `.sound`) if the
    /// user hasn't decided yet. Safe to call from any foreground context;
    /// no-ops once the status is `.authorized` / `.denied`.
    public func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error = error {
                    DebugLogger.shared.log("BackgroundHapticBridge: authorization error \(error.localizedDescription)")
                } else {
                    DebugLogger.shared.log("BackgroundHapticBridge: notification authorization \(granted ? "granted" : "denied")")
                }
            }
        }
    }

    // MARK: - Alert tick (called by AlertEngine every 1 s monitor tick)

    /// Evaluates whether to deliver a background buzz RIGHT NOW. Self-
    /// gating: master toggle, haptic-alerts toggle, true-background state,
    /// CarPlay-exclusion, and the 15 s throttle all live here so the
    /// caller (AlertEngine) can fire on every tick without ceremony.
    public func handleSpeedingTick(hapticsEnabled: Bool, speed: Double, limit: Int) {
        guard isEnabled, hapticsEnabled else { return }
        // Respect the Haptic Style picker: a user who explicitly chose
        // "Off" in Settings expects silence from every vibration surface,
        // foreground (HapticAlertManager) and background alike. The buzz
        // here is the system's generic notification vibration, not the
        // user's selected/custom pattern.
        guard HapticAlertManager.shared.style != .off else { return }
        // Only when the phone app is truly backgrounded (another app in
        // the foreground, or the screen locked). While Speedio is the
        // foreground app the real CHHapticEngine pulse already works.
        guard UIApplication.shared.applicationState == .background else { return }
        // Skip while CarPlay is driving the session — alerts are already
        // delivered in the car; buzzing the phone too would be redundant.
        let carPlayActive = UIApplication.shared.connectedScenes.contains {
            ($0 as? CPTemplateApplicationScene)?.activationState == .foregroundActive
        }
        guard !carPlayActive else { return }

        let now = Date()
        guard now.timeIntervalSince(lastAlertAt) >= alertInterval else { return }
        lastAlertAt = now
        postVibrationNotification(speed: speed, limit: limit)
    }

    /// Resets the throttle so the next speeding episode buzzes immediately.
    /// Called by AlertEngine when the user returns inside the limit.
    public func reset() {
        lastAlertAt = .distantPast
    }

    // MARK: - Delivery

    private func postVibrationNotification(speed: Double, limit: Int) {
        // NOTE: authorization is intentionally NOT requested here — this
        // path can run while backgrounded, where a permission prompt is
        // unreliable. The foreground hooks cover it: Settings toggle
        // `.onChange` and `DriveViewModel.startSession`.

        let content = UNMutableNotificationContent()
        content.title = "Speed Alert"
        let measurementSystem = SpeedFormatting.measurementSystem()
        let unit = measurementSystem == "Metric" ? "km/h" : "mph"
        // Speed is already in the active display unit; the stored limit is
        // canonical MPH and must be converted for a metric notification.
        let displayLimit = SpeedFormatting.displayLimit(
            forMph: limit,
            measurementSystem: measurementSystem
        )
        let speedText = "\(Int(speed.rounded())) \(unit)"
        content.body = limit > 0
            ? "You're over the speed limit — \(speedText) (limit \(displayLimit) \(unit))"
            : "You're over the speed limit — \(speedText)"
        content.threadIdentifier = "speeding-alert"

        // A missing silent resource must never turn an audio-disabled alert
        // into an audible notification. The project bundles silent_alert.wav;
        // if a malformed/development bundle omits it, deliver no notification
        // rather than violate the user's audio preference.
        guard Bundle.main.url(forResource: "silent_alert", withExtension: "wav") != nil else {
            DebugLogger.shared.log("BackgroundHapticBridge: silent alert resource missing")
            return
        }
        content.sound = UNNotificationSound(named: UNNotificationSoundName("silent_alert.wav"))

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                DebugLogger.shared.log("BackgroundHapticBridge: notification delivery failed: \(error.localizedDescription)")
            }
        }
    }
}
