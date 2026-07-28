// Path: Core/AlertEngine.swift

import Foundation
import Combine
import AVFoundation
import AudioToolbox
import CoreHaptics

@MainActor
public protocol AlertEngineProtocol {
    var consecutiveSeconds: Int { get }
    var audioAlertActive: Bool { get }
}

@MainActor
public final class AlertEngine: ObservableObject, AlertEngineProtocol {
    
    @Published public var consecutiveSeconds: Int = 0
    @Published public var audioAlertActive: Bool = false
    
    // MARK: - Snooze
    /// When set, the engine skips `triggerAlert()` until this date passes.
    @Published public var snoozedUntil: Date? = nil
    /// True while the alert is snoozed (current time < snoozedUntil).
    public var isSnoozed: Bool {
        guard let until = snoozedUntil else { return false }
        return until > Date()
    }
    /// How many seconds remaining in the current snooze (0 if not snoozed).
    public var snoozeRemainingSeconds: Int {
        guard let until = snoozedUntil, until > Date() else { return 0 }
        return Int(until.timeIntervalSince(Date()))
    }
    /// Reference to SpeedEngine for auto-expire when stopped.
    private weak var speedEngine: SpeedEngine?
    /// Tracks how long the car has been stopped during snooze.
    private var stoppedWhileSnoozed: TimeInterval = 0
    
    private var timerCancellable: AnyCancellable?
    private var statusCancellable: AnyCancellable?
    private var snoozeAutoExpireCancellable: AnyCancellable?
    private let audioAlertsKey = "audioAlertsEnabled"
    private var isAudioAlertsEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: audioAlertsKey) == nil {
            defaults.set(true, forKey: audioAlertsKey)
        }
        return defaults.bool(forKey: audioAlertsKey)
    }

    // Haptic toggle is independent of the audio toggle since
    // TestFlight v2.2.0 b366. AlertEngine still gates *whether* to even
    // start monitoring on either being on (`handleStatusChange`), but each
    // half of `triggerAlert()` reads its own toggle so a user with
    // audio-off + haptic-on still gets vibration alerts (and vice-versa).
    private let hapticAlertsKey = "hapticAlertsEnabled"
    private var isHapticAlertsEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: hapticAlertsKey) == nil {
            defaults.set(true, forKey: hapticAlertsKey)
        }
        return defaults.bool(forKey: hapticAlertsKey)
    }
    
    // Cooldown
    private var lastBeepTime: Date = .distantPast
    
    // MARK: - Transition Haptics
    /// Tracks previous status so we can detect .safe → .warning and .over → .safe transitions.
    private var previousStatus: SpeedStatus = .safe
    
    // MARK: - Audio (Tone)
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var toneBuffer: AVAudioPCMBuffer?
    
    // MARK: - Haptics
    private var hapticEngine: CHHapticEngine?
    
    // MARK: - Init
    public init(speedEngine: SpeedEngine) {
        self.speedEngine = speedEngine
        setupAudioSession()
        setupToneEngine()
        setupHaptics()
        observeAudioInterruptions()
        
        statusCancellable = speedEngine.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] newStatus in
                self?.handleStatusChange(newStatus)
            }
    }
    
    // MARK: - Snooze
    
    /// Silences alerts for the given duration. Only one snooze at a time;
    /// calling while already snoozed extends the snooze from the current time.
    public func snoozeFor(_ seconds: TimeInterval) {
        snoozedUntil = Date().addingTimeInterval(seconds)
        DebugLogger.shared.log("AlertEngine: snoozed for \(Int(seconds))s")
        
        // Start monitoring for auto-expire when the car stops.
        startSnoozeAutoExpireMonitor()
    }
    
    /// Cancels the current snooze, allowing alerts to resume immediately.
    public func cancelSnooze() {
        snoozedUntil = nil
        stoppedWhileSnoozed = 0
        snoozeAutoExpireCancellable?.cancel()
        snoozeAutoExpireCancellable = nil
        DebugLogger.shared.log("AlertEngine: snooze cancelled")
    }
    
    /// Monitors speed while snoozed. If the car stops (< 2 m/s) for >30
    /// continuous seconds, auto-expires the snooze.
    private func startSnoozeAutoExpireMonitor() {
        snoozeAutoExpireCancellable?.cancel()
        stoppedWhileSnoozed = 0
        
        snoozeAutoExpireCancellable = Timer.publish(every: 2.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                // Only monitor while still snoozed
                guard self.isSnoozed else {
                    self.stoppedWhileSnoozed = 0
                    self.snoozeAutoExpireCancellable?.cancel()
                    self.snoozeAutoExpireCancellable = nil
                    return
                }
                
                let speed = self.speedEngine?.speed ?? 0
                // SpeedEngine.speed is in the active display unit: mph when
                // Imperial, km/h when Metric. Convert to m/s for the 2 m/s
                // threshold check.
                let isMetric = self.speedEngine?.measurementSystem == "Metric"
                let speedMps = isMetric ? speed / 3.6 : speed / 2.23694
                if speedMps < 2.0 {
                    self.stoppedWhileSnoozed += 2.0
                    if self.stoppedWhileSnoozed >= 30.0 {
                        DebugLogger.shared.log("AlertEngine: snooze auto-expired (car stopped >30s)")
                        self.cancelSnooze()
                    }
                } else {
                    self.stoppedWhileSnoozed = 0
                }
            }
    }
    
    // MARK: - Status Handling
    private func handleStatusChange(_ status: SpeedStatus) {
        // ── Transition Haptics ────────────────────────────────────
        // Detect state transitions and fire contextual haptic patterns
        // that are independent of the user's speed-alert style picker.
        // These provide tactile feedback for boundary events.
        
        // Relief haptic: user slowed down from `.over` to `.safe` or `.warning`
        if previousStatus == .over && (status == .safe || status == .warning) {
            DebugLogger.shared.log("AlertEngine: OVER → SAFE/WARNING — relief haptic")
            DispatchQueue.main.async {
                HapticAlertManager.playSuccessHaptic()
            }
        }
        
        // Anticipatory haptic: user is approaching the limit (`.warning` zone)
        // Fires ONLY once on the .safe → .warning transition, NOT on every
        // GPS tick while staying in .warning. The .over → .warning path is
        // already handled by the relief haptic above.
        if previousStatus == .safe && status == .warning {
            DebugLogger.shared.log("AlertEngine: approaching limit — near haptic")
            DispatchQueue.main.async {
                HapticAlertManager.playNearHaptic()
            }
        }
        
        // Store current status for next comparison
        self.previousStatus = status
        
        // Start monitoring if EITHER alert channel is enabled. Audio / haptic
        // toggles are independent since v2.2.0 b366.
        let anyAlertEnabled = isAudioAlertsEnabled || isHapticAlertsEnabled

        if status == .over && anyAlertEnabled {
            if timerCancellable == nil {
                DebugLogger.shared.log("AlertEngine: OVER → start monitoring")
                startMonitoring()
            }
        } else {
            if timerCancellable != nil {
                DebugLogger.shared.log("AlertEngine: STOP monitoring")
                stopMonitoringState()
            }
        }
    }
    
    // MARK: - Monitoring
    private func startMonitoring() {
        consecutiveSeconds = 0
        
        // ── Duck other audio for the ENTIRE speeding duration ──────
        // Activate our session with `.duckOthers`. This lowers the
        // volume of YouTube/Music/Spotify and keeps it lowered until
        // we deactivate (when the user slows down). Every beep that
        // fires while in this state will be clearly audible.
        activateAudioDucking()

        timerCancellable = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }

                // Stop monitoring if the user toggled BOTH audio and haptic
                // off mid-drive. Either one alone keeps the timer running.
                guard self.isAudioAlertsEnabled || self.isHapticAlertsEnabled else {
                    self.stopMonitoringState()
                    return
                }

                self.consecutiveSeconds += 1
                
                // Publish snooze state changes so the UI countdown updates.
                // SwiftUI doesn't re-evaluate the computed `isSnoozed` on
                // its own because no @Published property changed — we force
                // an objectWillChange so Timer-driven countdowns re-render.
                if self.isSnoozed {
                    self.objectWillChange.send()
                }

                if self.consecutiveSeconds >= 1 {
                    self.audioAlertActive = true

                    let now = Date()
                    if now.timeIntervalSince(self.lastBeepTime) >= 2.0 {
                        self.lastBeepTime = now
                        // Skip the actual alert tone/haptic while snoozed,
                        // but keep the consecutive counter ticking so the
                        // user sees the correct "seconds over limit" count
                        // when the beep resumes.
                        if !self.isSnoozed {
                            self.triggerAlert()
                        }
                    }
                }
            }
    }
    
    private func stopMonitoringState() {
        cancelTimer()
        consecutiveSeconds = 0
        audioAlertActive = false
        timerCancellable = nil
        cancelSnooze()
        
        // ── Restore music volume ───────────────────────────────────
        // User has slowed down and status is no longer `.over`.
        // Deactivate our audio session so the other app's (YouTube,
        // Music, Spotify) volume comes back to normal.
        deactivateAudioDucking()
    }
    
    private func cancelTimer() {
        timerCancellable?.cancel()
    }
    
    // MARK: - ALERT
    private func triggerAlert() {
        // Compute severity based on how far over the limit the user is
        var severity: Double = 0.5
        if let engine = speedEngine, engine.limit > 0 {
            // speed and limit are in the active display unit (mph or km/h).
            // Calculate the raw overspeed amount relative to limit + buffer.
            let threshold = Double(engine.limit + engine.userBuffer)
            let overspeedAmount = max(0, engine.speed - threshold)
            // Map overspeed to severity 0.1–1.0: +1 mph over = 0.15, +20 mph over = 1.0
            // In metric (+1.6 km/h = 0.15, +32 km/h = 1.0)
            severity = min(1.0, max(0.1, overspeedAmount / 20.0))
        }
        
        // Audio half: only fires when the audio toggle is on. Independent
        // of the haptic toggle so users can silence the audio while keeping
        // vibration alerts.
        if isAudioAlertsEnabled {
            playTone()
        }
        // Haptic half: HapticAlertManager owns its own master toggle + style
        // picker + deviceSupportsHaptics guard, so we just delegate. Pass
        // severity + consecutiveSeconds so patterns modulate their intensity
        // based on how badly / long the user is speeding.
        HapticAlertManager.shared.fireIfEnabled(
            severity: severity,
            consecutiveSeconds: consecutiveSeconds
        )
    }
    
    // MARK: - Audio Session Interruption Handling
    /// Set when an audio interruption (e.g. YouTube starting playback)
    /// begins, so we know to re-activate the session before the next beep.
    private var wasInterrupted: Bool = false
    
    /// Registers for audio interruption notifications so we can re-activate
    /// our session when the interrupting app (YouTube, Music, etc.) finishes
    /// or when we need to play a beep while interrupted.
    private func observeAudioInterruptions() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }
    
    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        
        switch type {
        case .began:
            // Another app (YouTube, Music) started playing — our session
            // was deactivated. Set the flag so we re-activate before next beep.
            wasInterrupted = true
            DebugLogger.shared.log("AlertEngine: audio interrupted by another app")
        case .ended:
            // The interruption ended. Re-activate the session and restart
            // the audio engine so the next beep plays correctly.
            wasInterrupted = false
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                restartAudioEngine()
                DebugLogger.shared.log("AlertEngine: audio session resumed after interruption")
            } catch {
                DebugLogger.shared.log("AlertEngine: failed to resume audio session: \(error.localizedDescription)")
            }
        @unknown default:
            break
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    /// Activates the audio session with `.duckOthers` to lower other
    /// audio (YouTube, Music, Spotify) for the entire duration the user
    /// is speeding. Called once when status changes to `.over`.
    /// The ducking persists until `deactivateAudioDucking()`, which is
    /// called when the user slows down below the limit.
    private func activateAudioDucking() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .default,
                options: [
                    .mixWithOthers,
                    .interruptSpokenAudioAndMixWithOthers,
                    .duckOthers
                ]
            )
            try session.setActive(true)
            DebugLogger.shared.log("AlertEngine: audio ducking activated (speeding)")
        } catch {
            DebugLogger.shared.log("AlertEngine: activateAudioDucking failed: \(error.localizedDescription)")
        }
    }
    
    /// Deactivates the audio session, allowing other apps' audio
    /// (YouTube, Music, Spotify) to return to full volume.
    /// Called when the user slows down below the speed limit.
    private func deactivateAudioDucking() {
        let session = AVAudioSession.sharedInstance()
        do {
            // `.notifyOthersOnDeactivation` tells the system to notify
            // the previously-interrupted app (YouTube, Music) that it can
            // restore its volume to normal.
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            DebugLogger.shared.log("AlertEngine: audio ducking deactivated (speed normal)")
        } catch {
            DebugLogger.shared.log("AlertEngine: deactivateAudioDucking failed: \(error.localizedDescription)")
        }
    }
    
    /// Re-activates the audio session and restarts the engine.
    /// Called before every beep if we were interrupted, and after
    /// interruptions end.
    ///
    /// ── Silent deactivation fix ─────────────────────────────────────
    /// DriveViewModel.announce() sets the session to `.spokenAudio` mode,
    /// and its `speechSynthesizer(_:didFinish:)` delegate calls
    /// `setActive(false)` after each utterance to restore music volume.
    /// This deactivates the session WITHOUT posting an
    /// `AVAudioSession.interruptionNotification` (because `announce()` uses
    /// `.mixWithOthers`), so `wasInterrupted` never gets set. The original
    /// guards returned early when monitoring was active and no interruption
    /// occurred — causing subsequent beeps to stay silent even though the
    /// `AVAudioEngine` was still running.
    ///
    /// Fix: add `!session.isActive` to both guard conditions so we proceed
    /// to re-activate whenever the session has been silently deactivated
    /// (e.g. by navigation speech ending, or any other non-interrupting
    /// deactivation path).
    private func ensureAudioSessionActive() {
        let session = AVAudioSession.sharedInstance()
        // If we're already monitoring (user is over limit), the session
        // was already activated by activateAudioDucking(). Only re-activate
        // if an interruption occurred (e.g. YouTube took over) OR if the
        // session was silently deactivated (e.g. navigation speech ended).
        guard timerCancellable == nil || wasInterrupted || !session.isActive else { return }
        // If other audio is playing and we weren't interrupted, skip
        // reactivation — unless the session itself is not active (silent
        // deactivation from navigation speech).
        guard !session.isOtherAudioPlaying || wasInterrupted || !session.isActive else { return }
        
        // Log when we detect a silent deactivation (helpful for debugging)
        if !session.isActive && !wasInterrupted {
            DebugLogger.shared.log("AlertEngine: audio session was inactive (likely deactivated by navigation speech) — re-activating")
        }
        
        // Re-apply category and activate. This is a defensive call — it's
        // cheap when the state already matches, and critical when another
        // app (YouTube) has taken over the session.
        do {
            try session.setCategory(
                .playback,
                mode: .default,
                options: [
                    .mixWithOthers,
                    .interruptSpokenAudioAndMixWithOthers,
                    .duckOthers
                ]
            )
            try session.setActive(true)
            wasInterrupted = false
        } catch {
            DebugLogger.shared.log("AlertEngine: audio session reactivate failed: \(error.localizedDescription)")
        }
    }
    
    /// Restarts the AVAudioEngine after it was stopped by an interruption.
    private func restartAudioEngine() {
        guard !audioEngine.isRunning else { return }
        do {
            try audioEngine.start()
            if !playerNode.isPlaying {
                playerNode.play()
            }
            DebugLogger.shared.log("AlertEngine: audio engine restarted")
        } catch {
            DebugLogger.shared.log("AlertEngine: audio engine restart failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Audio Session
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            
            try session.setCategory(
                .playback,
                mode: .default,
                options: [
                    .mixWithOthers,
                    .interruptSpokenAudioAndMixWithOthers,
                    .duckOthers
                ]
            )
            
            try session.setActive(true)
            
            DebugLogger.shared.log("Audio session configured OK")
            
        } catch {
            DebugLogger.shared.log("Audio session error: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Tone Engine
    private func setupToneEngine() {
        let sampleRate: Double = 44100
        let duration: Double = 0.25
        let frequency: Double = 1052.0
        
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        
        toneBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        toneBuffer?.frameLength = frameCount
        
        let theta = 2.0 * Double.pi * frequency / sampleRate
        
        if let buffer = toneBuffer?.floatChannelData?[0] {
            for frame in 0..<Int(frameCount) {
                let value = sin(theta * Double(frame))
                buffer[frame] = value >= 0 ? 1.0 : -1.0 // square wave
            }
        }
        
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
        
        do {
            try audioEngine.start()
            DebugLogger.shared.log("Tone engine started OK")
        } catch {
            DebugLogger.shared.log("Tone engine error: \(error.localizedDescription)")
        }
        playerNode.play()
    }
    
    /// Plays the alert tone with proper audio session management.
    /// Fixes the bug where beeps are inaudible when YouTube/Music is playing:
    ///   1. Re-activates the audio session (YouTube may have deactivated it)
    ///   2. Restarts the audio engine if needed
    ///   3. Schedules the buffer WITHOUT stopping the player node first
    ///   4. Falls back to system sound if AVAudioEngine fails entirely
    private func playTone() {
        guard let buffer = toneBuffer else { return }
        
        // Step 1: Ensure the audio session is active (re-activate if
        // another app like YouTube deactivated it).
        ensureAudioSessionActive()
        
        // Step 2: If the engine stopped (e.g. due to interruption),
        // restart it.
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
                DebugLogger.shared.log("AlertEngine: audio engine restarted for beep")
            } catch {
                DebugLogger.shared.log("AlertEngine: audio engine restart failed: \(error.localizedDescription)")
                // Step 4: Fallback — use system sound
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                return
            }
        }
        
        // Step 3: Schedule the buffer WITHOUT stopping the player node.
        // The `.interrupts` option will interrupt any currently-playing
        // buffer on this node. The old pattern (stop + schedule + play)
        // caused a race where the stop() committed before scheduleBuffer
        // could start, resulting in silence.
        if !playerNode.isPlaying {
            playerNode.play()
        }
        playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts)
    }
    
    // MARK: - HAPTICS SETUP
    private func setupHaptics() {
    guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
        DebugLogger.shared.log("No advanced haptics support")
        return
    }
    
    do {
        hapticEngine = try CHHapticEngine()
        
        // Restart if engine stops
        hapticEngine?.stoppedHandler = { reason in
            DebugLogger.shared.log("Haptics stopped: \(reason.rawValue)")
        }
        
        // Reset handler (CRITICAL)
        hapticEngine?.resetHandler = { [weak self] in
            DebugLogger.shared.log("Haptics reset → restarting engine")
            do {
                try self?.hapticEngine?.start()
            } catch {
                DebugLogger.shared.log("Haptics restart failed: \(error.localizedDescription)")
            }
        }
        
        try hapticEngine?.start()
        DebugLogger.shared.log("Haptic engine started OK")
        
    } catch {
        DebugLogger.shared.log("Haptics setup error: \(error.localizedDescription)")
    }
}
    
    // MARK: - HAPTIC PATTERNS
    
    // Note: The previous `hapticSpeedingAlert()` private method (an
    // aggressive 12-events-per-second continuous barrage) was removed in
    // TestFlight v2.2.0 b366. Speeding haptics are now delegated entirely
    // to `HapticAlertManager.shared.fireIfEnabled()`, which honors the
    // user's master toggle + style pick from Settings → ALERTS.
    //
    // The `hapticExplosion / hapticLeft / hapticRight` helpers below remain
    // because they are called by CarPlayNavigationManager / SmartSpeedLive
    // Activity / DriveViewModel voice prompts — those are NOT speed-alert
    // haptic signals and live in a separate vocabulary.
    
    // Explosion / cloud feel
    public func hapticExplosion() {
        guard let _ = hapticEngine else { return }
        
        let events = [
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    .init(parameterID: .hapticIntensity, value: 1.0),
                    .init(parameterID: .hapticSharpness, value: 1.0)
                ],
                relativeTime: 0
            ),
            CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    .init(parameterID: .hapticIntensity, value: 0.4),
                    .init(parameterID: .hapticSharpness, value: 0.1)
                ],
                relativeTime: 0.05,
                duration: 0.4
            )
        ]
        
        playHaptic(events)
    }
    
    // LEFT
    public func hapticLeft() {
        playHaptic([
            .init(eventType: .hapticTransient,
                  parameters: [.init(parameterID: .hapticIntensity, value: 0.6)],
                  relativeTime: 0),
            .init(eventType: .hapticTransient,
                  parameters: [.init(parameterID: .hapticIntensity, value: 1.0)],
                  relativeTime: 0.15)
        ])
    }
    
    // RIGHT
    public func hapticRight() {
        playHaptic([
            .init(eventType: .hapticTransient,
                  parameters: [.init(parameterID: .hapticIntensity, value: 1.0)],
                  relativeTime: 0),
            .init(eventType: .hapticTransient,
                  parameters: [.init(parameterID: .hapticIntensity, value: 0.6)],
                  relativeTime: 0.15)
        ])
    }
    
    // MARK: - Haptic Player
    private func playHaptic(_ events: [CHHapticEvent]) {
        guard let engine = hapticEngine else {
            // FALLBACK (guaranteed vibration)
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            return
        }
        
        do {
            // Fix: Start the engine directly. If it's already started, 
            // this call is essentially a no-op or resumes it.
            try engine.start()
            
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
            
        } catch {
            DebugLogger.shared.log("AlertEngine: Haptic Error: \(error.localizedDescription)")
            // Fallback to basic vibration if the complex pattern fails
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }
}

