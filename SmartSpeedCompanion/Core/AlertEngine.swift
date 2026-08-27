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
        // Haptics are opt-in. Older builds defaulted this missing key to true,
        // which made users who never enabled vibration receive the sustained
        // speeding pulse unexpectedly after an update.
        if defaults.object(forKey: hapticAlertsKey) == nil {
            defaults.set(false, forKey: hapticAlertsKey)
        }
        return defaults.bool(forKey: hapticAlertsKey)
    }
    
    // Cooldown
    private var lastBeepTime: Date = .distantPast
    
    // MARK: - Transition Haptics
    /// Tracks previous status so we can detect .safe → .warning and .over → .safe transitions.
    private var previousStatus: SpeedStatus = .safe
    
    // MARK: - Audio (Tone)
    // AVAudioEngine touches the audio graph when it is initialized. Keep
    // both objects lazy so constructing the shared DriveViewModel at launch
    // cannot trigger audio-daemon work on the UIKit thread.
    private lazy var audioEngine = AVAudioEngine()
    private lazy var playerNode = AVAudioPlayerNode()
    private var toneBuffer: AVAudioPCMBuffer?
    /// AVAudioEngine graph creation and startup can synchronously wait on the
    /// audio daemon. Keep first-use preparation off the main actor just like
    /// AVAudioSession activation.
    private let audioPreparationQueue = DispatchQueue(
        label: "com.speedsense.tone-preparation",
        qos: .userInitiated
    )
    /// True while the current overspeed episode owns the shared audio cue.
    private var alertSessionHeld = false
    /// AudioServices sound ID built from the tone buffer, used by the
    /// fallback alert path (plays through AudioServices' own audio path,
    /// which works even when AVAudioEngine cannot start).
    private var fallbackAlertSoundID: SystemSoundID = 0
    
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
        // LAUNCH-HANG FIX (2026-08-02 UIKit-runloop reports): the tone
        // engine (AVAudioEngine) and the haptic engine (CHHapticEngine)
        // are NO LONGER created here. `setupToneEngine()` started the
        // AVAudioEngine and `HapticAlertManager.shared` created/started
        // the CHHapticEngine synchronously on the main thread during app
        // launch — two of the three back-to-back launch hangs seen in
        // TestFlight build 549. Both are now built lazily on first actual
        // alert use (see `ensureToneEngine()` and
        // `HapticAlertManager.ensureEngine()`), keeping the launch path
        // free of synchronous audio/haptic hardware bring-up.
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
        // A missing speed limit is not an alertable condition. The speed
        // engine represents unknown data as limit == 0 and safely reports
        // `.safe`; do not turn that bookkeeping transition into a relief
        // vibration or allow an earlier overspeed timer to keep beeping.
        guard speedEngine?.isLimitResolved == true,
              (speedEngine?.limit ?? 0) > 0 else {
            previousStatus = .safe
            if timerCancellable != nil {
                stopMonitoringState()
            }
            return
        }

        // ── Transition Haptics ────────────────────────────────────
        // Detect state transitions and fire contextual haptic patterns
        // that are independent of the user's speed-alert style picker.
        // These provide tactile feedback for boundary events.
        
        // Relief haptic: user slowed down from `.over` to `.safe` or `.warning`
        if isHapticAlertsEnabled,
           previousStatus == .over && (status == .safe || status == .warning) {
            DebugLogger.shared.log("AlertEngine: OVER → SAFE/WARNING — relief haptic")
            DispatchQueue.main.async {
                HapticAlertManager.playSuccessHaptic()
            }
        }
        
        // Anticipatory haptic: user is approaching the limit (`.warning` zone)
        // Fires ONLY once on the .safe → .warning transition, NOT on every
        // GPS tick while staying in .warning. The .over → .warning path is
        // already handled by the relief haptic above.
        if isHapticAlertsEnabled,
           previousStatus == .safe && status == .warning {
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
        lastBeepTime = .distantPast
        
        // Keep media interrupted for the whole speeding episode. The user
        // must not miss the next warning while the car remains over the
        // limit; focus is released only when status returns to safe/warning.
        if isAudioAlertsEnabled {
            beginAlertAudioFocus()
        }

        // ── Sustained speeding vibration ──────────────────────────
        // Start the pulse only for a real, resolved over-limit condition.
        // This second guard protects against a stale status transition or a
        // future caller accidentally starting monitoring with limit == 0.
        if isHapticAlertsEnabled,
           let engine = speedEngine,
           engine.isLimitResolved,
           engine.limit > 0,
           isActuallyOverLimit(engine) {
            HapticAlertManager.shared.startSpeedingPulse(
                severity: computedSeverity()
            )
        }

        // Do not make the driver wait for the first one-second timer tick.
        // A valid over-limit transition should produce an audible cue now;
        // the timer below supplies the sustained reminders.
        consecutiveSeconds = 1
        audioAlertActive = isAudioAlertsEnabled
        if !isSnoozed {
            lastBeepTime = Date()
            triggerAlert()
            BackgroundHapticBridge.shared.handleSpeedingTick(
                hapticsEnabled: isHapticAlertsEnabled,
                speed: speedEngine?.speed ?? 0,
                limit: speedEngine?.limit ?? 0
            )
        }

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

                // Reconcile audio focus when the setting changes during an
                // overspeed episode: disabling audio must restore media now,
                // while enabling it must acquire focus before the next tone.
                if self.isAudioAlertsEnabled {
                    self.beginAlertAudioFocus()
                } else {
                    self.endAlertAudioFocus()
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
                let hasResolvedOverLimit: Bool = {
                    guard let engine = self.speedEngine,
                          engine.isLimitResolved,
                          engine.limit > 0 else { return false }
                    return self.isActuallyOverLimit(engine)
                }()
                if self.isSnoozed || !self.isHapticAlertsEnabled || !hasResolvedOverLimit {
                    HapticAlertManager.shared.stopSpeedingPulse()
                } else {
                    HapticAlertManager.shared.startSpeedingPulse(
                        severity: self.computedSeverity()
                    )
                }

                if self.consecutiveSeconds >= 1 {
                    self.audioAlertActive = self.isAudioAlertsEnabled

                    let now = Date()
                    if now.timeIntervalSince(self.lastBeepTime) >= 2.0 {
                        self.lastBeepTime = now
                        // Skip the actual alert tone/haptic while snoozed,
                        // but keep the consecutive counter ticking so the
                        // user sees the correct "seconds over limit" count
                        // when the beep resumes.
                        if !self.isSnoozed {
                            self.triggerAlert()
                            BackgroundHapticBridge.shared.handleSpeedingTick(
                                hapticsEnabled: self.isHapticAlertsEnabled,
                                speed: self.speedEngine?.speed ?? 0,
                                limit: self.speedEngine?.limit ?? 0
                            )
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
        BackgroundHapticBridge.shared.reset()
        lastBeepTime = .distantPast
        
        // Restore the previous media app as soon as the user is no longer
        // over the limit. Navigation speech can keep its own independent
        // cue lease if a direction is being spoken at the same time.
        endAlertAudioFocus()
    }
    
    private func cancelTimer() {
        timerCancellable?.cancel()
    }
    
    // MARK: - ALERT
    
    /// How far over the limit the user is, normalized 0.1–1.0 (0.5 when no
    /// limit data). Used to modulate the sustained speeding pulse's
    /// intensity: +1 mph over ≈ 0.15, +20 mph over ≈ 1.0 (metric: +1.6 km/h
    /// ≈ 0.15, +32 km/h ≈ 1.0).
    /// Pure policy used by both the initial pulse and its timer refreshes.
    /// Keeping this independent of Core Haptics makes the accidental-vibration
    /// regression testable and ensures unknown limits never become alerts.
    internal nonisolated static func shouldStartSpeedingPulse(
        speed: Double,
        limit: Int,
        buffer: Int,
        measurementSystem: String,
        isLimitResolved: Bool
    ) -> Bool {
        guard isLimitResolved, limit > 0 else { return false }
        let thresholdMph = Double(limit + buffer)
        let threshold = measurementSystem == "Metric"
            ? thresholdMph * 1.60934
            : thresholdMph
        return speed > threshold
    }

    private func isActuallyOverLimit(_ engine: SpeedEngine) -> Bool {
        Self.shouldStartSpeedingPulse(
            speed: engine.speed,
            limit: engine.limit,
            buffer: engine.userBuffer,
            measurementSystem: engine.measurementSystem,
            isLimitResolved: engine.isLimitResolved
        )
    }

    private func computedSeverity() -> Double {
        guard let engine = speedEngine, engine.limit > 0 else { return 0.5 }
        // `limit` and `userBuffer` are stored in MPH while `speed` is already
        // in the active display unit. Convert the threshold before measuring
        // severity so metric users get the same alert intensity as imperial
        // users.
        let isMetric = engine.measurementSystem == "Metric"
        let thresholdMph = Double(engine.limit + engine.userBuffer)
        let threshold = isMetric ? thresholdMph * 1.60934 : thresholdMph
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
            // Only recover a tone engine that was actually used by an active
            // speeding alert. Navigation speech also generates interruption
            // notifications, and it must not lazily construct/start a tone
            // graph in response.
            guard alertSessionHeld, toneEngineReady else { return }
            AudioSessionCoordinator.shared.ensureActive()
            restartAudioEngine()
            DebugLogger.shared.log("AlertEngine: audio session resumed after interruption")
        @unknown default:
            break
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        if fallbackAlertSoundID != 0 {
            AudioServicesDisposeSystemSoundID(fallbackAlertSoundID)
        }
    }
    
    /// Keeps the session focused for the entire overspeed episode. The
    /// coordinator requests a real interruption first and uses ducking only
    /// when exclusive activation is rejected by the current route.
    private func beginAlertAudioFocus() {
        guard !alertSessionHeld else { return }
        AudioSessionCoordinator.shared.beginCue()
        alertSessionHeld = true
        DebugLogger.shared.log("AlertEngine: audio focus acquired for speeding episode")
    }

    private func endAlertAudioFocus() {
        guard alertSessionHeld else { return }
        alertSessionHeld = false
        // Suspend the tone engine BEFORE releasing the cue. A running
        // AVAudioEngine holds the AVAudioSession active, so the coordinator's
        // setActive(false) would fail and `.notifyOthersOnDeactivation` would
        // never reach the interrupted media app — leaving YouTube/Music
        // paused for the rest of the drive (regression from the 24/7 tone
        // engine). Pausing the engine first lets the session deactivate and
        // the previous media resume, exactly like it did before the engine
        // was left running.
        suspendToneEngine()
        AudioSessionCoordinator.shared.endCue()
        DebugLogger.shared.log("AlertEngine: audio focus released after speeding episode")
    }

    /// Stops the tone engine's rendering so the shared audio session can be
    /// deactivated between overspeed episodes. Uses `pause()` rather than
    /// `stop()`: a paused AVAudioEngine can be resumed with a plain
    /// `start()`, while a stopped one throws -10851 on restart unless it is
    /// reset first — the exact bug that broke every beep after the first in
    /// the old per-beep stop()/start() cycle. The engine is built lazily, so
    /// if it never fired yet there is nothing to suspend.
    private func suspendToneEngine() {
        guard toneEngineReady else { return }
        if audioEngine.isRunning {
            playerNode.stop()
            audioEngine.pause()
            DebugLogger.shared.log("AlertEngine: tone engine paused (media can resume)")
        }
    }

    /// Rebuilds the tone-engine graph after an interruption. A phone call
    /// / Siri / another app's playback stops the engine underneath us, so
    /// this restarts it so the next beep plays. BEEP-REGRESSION FIX: this
    /// is a SYSTEM stop, not our own per-beep stop — the per-beep
    /// stop()/start() cycle (CARPLAY TTS experiment) was what silently
    /// killed every beep after the first; engine start after a genuine
    /// interruption is the documented recovery path.
    private func restartAudioEngine() {
        // LAUNCH-HANG FIX: if no beep has fired yet the tone engine may
        // never have been built (it is lazily created on first alert).
        // Build it before anything else so a mid-session interruption
        // can't hit an un-initialized graph.
        ensureToneEngine()
        guard toneEngineReady else { return }

        // `AVAudioEngine.start()` can wait for the audio daemon after an
        // interruption. Capture the already-prepared graph on the main actor,
        // then restart it on the same utility queue used for preparation.
        let engine = audioEngine
        let player = playerNode
        audioPreparationQueue.async {
            guard !engine.isRunning else {
                DebugLogger.shared.log("AlertEngine: tone engine still running after interruption")
                return
            }
            do {
                try engine.start()
                if !player.isPlaying {
                    player.play()
                }
                DebugLogger.shared.log("AlertEngine: audio engine restarted after interruption")
            } catch {
                DebugLogger.shared.log("AlertEngine: audio engine restart failed: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Audio Session
    // No direct session setup here — all ownership lives in
    // AudioSessionCoordinator (Core/AudioSessionCoordinator.swift) so the
    // nav-voice announcer and this tone engine share ONE stable session
    // policy instead of fighting over category/mode/activation.
    
    // MARK: - Tone Engine
    /// True once `ensureToneEngine()` has been attempted. Guards the lazy
    /// one-shot build so the AVAudioEngine hardware is only started on the
    /// first actual alert (LAUNCH-HANG FIX — see `init` note).
    private var toneEngineReady = false
    private var toneEnginePreparationStarted = false

    /// Builds the tone-engine graph (buffer + node wiring) on first use.
    /// Deliberately NOT called from `init`: starting AVAudioEngine
    /// synchronously during app launch was one of the main-thread launch
    /// hangs in TestFlight build 549.
    ///
    /// BEEP-REGRESSION FIX (2026-08-07): the engine is STARTED here and
    /// left running for the rest of the drive. The previous per-beep
    /// stop()/start() cycle from the CarPlay TTS experiment was based on
    /// the wrong theory — the user's own diagnostic (recorded in the
    /// 814d1c3 commit) confirmed the beeps were ALWAYS clean over CarPlay
    /// and the nav-voice choppiness was specific to AVSpeechSynthesizer's
    /// own pipeline (fixed by the compact-voice selection + session
    /// options + Now Playing dedup). The stop()/start() cycle, however,
    /// silently killed every beep after the first: after `stop()`, calling
    /// `start()` again without `reset()` throws -10851 or starts an engine
    /// that produces no output, and the error fallback was a vibration,
    /// not a sound — testers reported "no sound coming out at all when you
    /// speed." Restoring the once-started, always-running engine (the
    /// behavior proven clean by the user's diagnostic).
    ///
    /// The tone buffer is also built at the session's negotiated sample
    /// rate (CarPlay links are typically 48 kHz) instead of a hard-coded
    /// 44.1 kHz, so the mixer never has to resample a live stream mid-drive.
    private func ensureToneEngine() {
        guard !toneEngineReady, !toneEnginePreparationStarted else { return }
        toneEnginePreparationStarted = true

        // Use the session's current sample rate (the caller has already
        // requested audio focus) so the tone graph matches the hardware
        // instead of forcing a 44.1 kHz resample while nav voice is playing.
        // Every potentially blocking AVAudioEngine operation stays on this
        // utility queue. The first beep uses the AudioServices fallback while
        // preparation is in flight; later beeps use the prepared graph.
        audioPreparationQueue.async { [weak self] in
            let sessionRate = AVAudioSession.sharedInstance().sampleRate
            let sampleRate: Double = sessionRate > 0 ? sessionRate : 44_100
            let duration: Double = 0.25
            let frequency: Double = 1_052.0
            let frameCount = AVAudioFrameCount(sampleRate * duration)

            guard let format = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: 1
            ),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                DebugLogger.shared.log("AlertEngine: tone format creation failed")
                return
            }
            buffer.frameLength = frameCount

            let theta = 2.0 * Double.pi * frequency / sampleRate
            if let samples = buffer.floatChannelData?[0] {
                for frame in 0..<Int(frameCount) {
                    let value = sin(theta * Double(frame))
                    samples[frame] = value >= 0 ? 1.0 : -1.0 // square wave
                }
            }

            let preparedEngine = AVAudioEngine()
            let preparedPlayer = AVAudioPlayerNode()
            preparedEngine.attach(preparedPlayer)
            preparedEngine.connect(
                preparedPlayer,
                to: preparedEngine.mainMixerNode,
                format: format
            )

            do {
                try preparedEngine.start()
                DebugLogger.shared.log("Tone engine started OK")
            } catch {
                DebugLogger.shared.log("Tone engine error: \(error.localizedDescription)")
                return
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.audioEngine = preparedEngine
                self.playerNode = preparedPlayer
                self.toneBuffer = buffer
                self.toneEngineReady = true
                if !preparedPlayer.isPlaying {
                    preparedPlayer.play()
                }
            }
        }
    }
    
    /// Builds a `SystemSoundID` from the tone buffer (written once to a
    /// temp WAV) so the engine-failure fallback plays a REAL audible tone
    /// through AudioServices — an audio path entirely independent of
    /// AVAudioEngine. `kSystemSoundID_UserPreferredAlert` is macOS-only and
    /// undocumented numeric system-sound IDs can silently no-op on newer
    /// iOS, so a file-based sound is the only guaranteed-audible option.
    private func prepareFallbackAlertSound() {
        guard fallbackAlertSoundID == 0 else { return }

        // Generate the fallback independently of AVAudioEngine. If the audio
        // graph failed before its PCM buffer was created, the fallback still
        // has a real tone to play through AudioServices.
        let frameCount = 11_025 // 250 ms at 44.1 kHz
        let sampleRate = 44_100
        let frequency = 1_052.0

        // 16-bit PCM mono WAV (44-byte header).
        func le16(_ v: UInt16) -> [UInt8] {
            [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
        }
        func le32(_ v: UInt32) -> [UInt8] {
            [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
             UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        }

        let dataSize = UInt32(frameCount * 2)
        var wav = Data()
        wav.append(contentsOf: Array("RIFF".utf8))
        wav.append(contentsOf: le32(36 + dataSize))
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        wav.append(contentsOf: le32(16))
        wav.append(contentsOf: le16(1))  // PCM
        wav.append(contentsOf: le16(1))  // mono
        wav.append(contentsOf: le32(UInt32(sampleRate)))
        wav.append(contentsOf: le32(UInt32(sampleRate) * 2))  // byte rate
        wav.append(contentsOf: le16(2))  // block align
        wav.append(contentsOf: le16(16))  // bits per sample
        wav.append(contentsOf: Array("data".utf8))
        wav.append(contentsOf: le32(dataSize))

        var samples = [UInt8](repeating: 0, count: frameCount * 2)
        let theta = 2.0 * Double.pi * frequency / Double(sampleRate)
        for i in 0..<frameCount {
            let value = sin(theta * Double(i)) >= 0 ? 1.0 : -1.0
            let int16 = Int16(value * 32767.0)
            samples[i * 2] = UInt8(int16 & 0xFF)
            samples[i * 2 + 1] = UInt8((int16 >> 8) & 0xFF)
        }
        wav.append(contentsOf: samples)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speedsense-fallback-alert.wav")
        do {
            try wav.write(to: url)
            var soundID: SystemSoundID = 0
            let status = AudioServicesCreateSystemSoundID(url as CFURL, &soundID)
            if status == noErr && soundID != 0 {
                fallbackAlertSoundID = soundID
                DebugLogger.shared.log("AlertEngine: fallback alert sound prepared")
            } else {
                DebugLogger.shared.log("AlertEngine: fallback alert sound creation failed: \(status)")
            }
        } catch {
            DebugLogger.shared.log("AlertEngine: fallback alert WAV write failed: \(error.localizedDescription)")
        }
    }

    /// Plays the alert tone with proper audio session management.
    /// Fixes the bug where beeps are inaudible when YouTube/Music is playing:
    ///   1. Re-activates the audio session (YouTube may have deactivated it)
    ///   2. Restarts the audio engine if needed
    ///   3. Schedules the buffer WITHOUT stopping the player node first
    ///   4. Falls back to system sound if AVAudioEngine fails entirely
    private func playTone() {
        // `startMonitoring()` already owns audio focus for the entire
        // overspeed episode. Do not activate/deactivate per beep: that would
        // churn the CarPlay route and could resume media between warnings.
        
        // LAUNCH-HANG FIX: build the tone engine on the first actual beep
        // (see `ensureToneEngine` / `init` note) instead of at launch.
        ensureToneEngine()
        guard toneEngineReady, let buffer = toneBuffer else {
            prepareFallbackAlertSound()
            if fallbackAlertSoundID != 0 {
                AudioServicesPlaySystemSound(fallbackAlertSoundID)
            } else {
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }
            return
        }
        
        // Step 2: If the engine stopped (e.g. due to interruption),
        // restart it. BEEP-REGRESSION FIX: this is only needed after a
        // SYSTEM interruption (not after our own beeps — we no longer stop
        // the engine between beeps, which was silently killing every beep
        // after the first).
        if !audioEngine.isRunning {
            // Restart asynchronously rather than synchronously waiting on the
            // audio daemon in the GPS/timer callback. The fallback keeps this
            // warning audible while the graph comes back.
            restartAudioEngine()
            prepareFallbackAlertSound()
            if fallbackAlertSoundID != 0 {
                AudioServicesPlaySystemSound(fallbackAlertSoundID)
            } else {
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }
            return
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

