// Path: Core/AlertEngine.swift

import Foundation
import Combine
import AVFoundation
import AudioToolbox

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
    
    // MARK: - Init
    public init(speedEngine: SpeedEngine) {
        self.speedEngine = speedEngine
        // NOTE: No direct AVAudioSession configuration here. All audio
        // session ownership lives in AudioSessionCoordinator (single
        // process-wide owner) so the nav-voice announcer and this tone
        // engine stop fighting over category/mode/activation — the root
        // cause of the glitchy CarPlay audio. The coordinator configures
        // lazily on first use and ref-counts activations.
        //
        // Warm up the single haptic engine now so the first speeding
        // alert doesn't pay CHHapticEngine() creation on the alert path
        // (the engine would otherwise be lazily built on the first
        // `triggerAlert()` -> `fireIfEnabled()` call).
        _ = HapticAlertManager.shared
        setupToneEngine()
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
        
        // ── Sustained speeding vibration ──────────────────────────
        // Start the repeating 3s-on / 0.5s-off pulse NOW (not on the
        // 2 s beep cooldown), so the driver feels the vibration the
        // moment they cross the limit. It keeps looping until
        // `stopMonitoringState()` fires when they slow back down.
        // Idempotent — safe to re-call on every monitor tick.
        HapticAlertManager.shared.startSpeedingPulse(
            severity: computedSeverity()
        )

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
                
                // ── Sustained vibration lifecycle ───────────────────
                // Keep the 3s-on / 0.5s-off pulse alive while speeding,
                // but pause it while snoozed or when the user toggles
                // haptics off mid-drive. The pulse resumes automatically
                // on the next tick once snooze expires / haptics return.
                if self.isSnoozed || !self.isHapticAlertsEnabled {
                    HapticAlertManager.shared.stopSpeedingPulse()
                } else {
                    HapticAlertManager.shared.startSpeedingPulse(
                        severity: self.computedSeverity()
                    )
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
        
        // ── Stop the sustained speeding vibration ─────────────────
        // User is back inside the limit (or alerts fully disabled):
        // kill the looping pulse immediately so the phone stops
        // vibrating.
        HapticAlertManager.shared.stopSpeedingPulse()
        
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
    
    /// How far over the limit the user is, normalized 0.1–1.0 (0.5 when no
    /// limit data). Used to modulate the sustained speeding pulse's
    /// intensity: +1 mph over ≈ 0.15, +20 mph over ≈ 1.0 (metric: +1.6 km/h
    /// ≈ 0.15, +32 km/h ≈ 1.0).
    private func computedSeverity() -> Double {
        guard let engine = speedEngine, engine.limit > 0 else { return 0.5 }
        // speed and limit are in the active display unit (mph or km/h).
        let threshold = Double(engine.limit + engine.userBuffer)
        let overspeedAmount = max(0, engine.speed - threshold)
        return min(1.0, max(0.1, overspeedAmount / 20.0))
    }
    
    private func triggerAlert() {
        // Audio half: only fires when the audio toggle is on. Independent
        // of the haptic toggle so users can silence the audio while keeping
        // vibration alerts.
        if isAudioAlertsEnabled {
            playTone()
        }
        // Haptic half: handled by the sustained speeding pulse started in
        // `startMonitoring()` and stopped in `stopMonitoringState()` — the
        // looping 3s-on / 0.5s-off vibration replaces the old per-beep
        // one-shot `fireIfEnabled()` haptic. No per-tick haptic needed here.
    }
    
    // MARK: - Audio Session Interruption Handling
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
            // was deactivated. The coordinator's `ensureActive()` on the
            // next beep (and on `.ended`) re-activates it, so no flag is
            // needed.
            DebugLogger.shared.log("AlertEngine: audio interrupted by another app")
        case .ended:
            // The interruption ended. Re-activate the shared session and
            // restart the audio engine so the next beep plays correctly.
            AudioSessionCoordinator.shared.ensureActive()
            restartAudioEngine()
            DebugLogger.shared.log("AlertEngine: audio session resumed after interruption")
        @unknown default:
            break
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    /// Acquires the shared audio session (with ducking) for the ENTIRE
    /// duration the user is speeding, so music/YouTube stays lowered until
    /// `deactivateAudioDucking()`. Delegates to the single process-wide
    /// `AudioSessionCoordinator` — it never changes category/mode here, so
    /// a speeding alert can no longer yank the session out of the
    /// navigation-voice `.spokenAudio` mode (the glitchy-audio bug).
    private func activateAudioDucking() {
        AudioSessionCoordinator.shared.beginAlertDucking()
        DebugLogger.shared.log("AlertEngine: audio ducking activated (speeding)")
    }

    /// Releases the alert's slot on the shared session, allowing other
    /// apps' audio (YouTube, Music, Spotify) to return to full volume.
    /// The coordinator only deactivates the session when NO other
    /// subsystem (e.g. active navigation voice) still holds it, and uses
    /// `.notifyOthersOnDeactivation` so the previously-ducked app restores
    /// its volume.
    private func deactivateAudioDucking() {
        AudioSessionCoordinator.shared.endAlertDucking()
        DebugLogger.shared.log("AlertEngine: audio ducking deactivated (speed normal)")
    }
    
    /// Ensures the shared session is active before each beep. Delegates to
    /// `AudioSessionCoordinator` — calling `setActive(true)` on an
    /// already-active session is a harmless no-op; when the session was
    /// silently deactivated (e.g. by navigation speech ending or an
    /// interruption), it reliably re-activates it. No category re-apply
    /// here: re-applying the category per beep was what interrupted
    /// ongoing navigation speech (glitchy-audio bug, TestFlight 71).
    private func ensureAudioSessionActive() {
        AudioSessionCoordinator.shared.ensureActive()
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
    // No direct session setup here — all ownership lives in
    // AudioSessionCoordinator (Core/AudioSessionCoordinator.swift) so the
    // nav-voice announcer and this tone engine share ONE stable session
    // policy instead of fighting over category/mode/activation.
    
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
    
    // MARK: - Haptics
    
    // Speeding haptics are owned entirely by `HapticAlertManager.shared`
    // (the single CHHapticEngine for the process), driven from the monitor
    // lifecycle here:
    //   • `startMonitoring()` starts the sustained 3s-on / 0.5s-off looping
    //     pulse the moment the user crosses the limit.
    //   • The 1 s monitor tick keeps it alive (idempotent) and pauses it
    //     while snoozed or when haptics are toggled off mid-drive.
    //   • `stopMonitoringState()` stops it the instant the user is back
    //     inside the limit.
    //
    // NOTE: AlertEngine previously created its own CHHapticEngine here
    // (plus `hapticExplosion` / `hapticLeft` / `hapticRight` helpers).
    // That duplicate engine fought HapticAlertManager's engine over the
    // single-process haptic resource — each engine's resetHandler
    // restarted itself and tore the other one down, so speeding
    // vibrations silently stopped firing (TestFlight feedback:
    // "vibrations are not coming when speeding"). The redundant engine
    // and its dead helpers were removed.
}

