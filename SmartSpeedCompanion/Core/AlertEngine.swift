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
    
    private var timerCancellable: AnyCancellable?
    private var statusCancellable: AnyCancellable?
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
    
    // MARK: - Audio (Tone)
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var toneBuffer: AVAudioPCMBuffer?
    
    // MARK: - Haptics
    private var hapticEngine: CHHapticEngine?
    
    // MARK: - Init
    public init(speedEngine: SpeedEngine) {
        setupAudioSession()
        setupToneEngine()
        setupHaptics()
        
        statusCancellable = speedEngine.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] newStatus in
                self?.handleStatusChange(newStatus)
            }
    }
    
    // MARK: - Status Handling
    private func handleStatusChange(_ status: SpeedStatus) {
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

                if self.consecutiveSeconds >= 1 {
                    self.audioAlertActive = true

                    let now = Date()
                    if now.timeIntervalSince(self.lastBeepTime) >= 2.0 {
                        self.lastBeepTime = now
                        self.triggerAlert()
                    }
                }
            }
    }
    
    private func stopMonitoringState() {
        cancelTimer()
        consecutiveSeconds = 0
        audioAlertActive = false
        timerCancellable = nil
    }
    
    private func cancelTimer() {
        timerCancellable?.cancel()
    }
    
    // MARK: - ALERT
    private func triggerAlert() {
        // Audio half: only fires when the audio toggle is on. Independent
        // of the haptic toggle so users can silence the audio while keeping
        // vibration alerts.
        if isAudioAlertsEnabled {
            playTone()
        }
        // Haptic half: HapticAlertManager owns its own master toggle + style
        // picker + deviceSupportsHaptics guard, so we just delegate. Falls
        // back to a system vibrate only when the user picked a non-Off style
        // on a haptic-capable device whose engine somehow failed.
        HapticAlertManager.shared.fireIfEnabled()
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
                .interruptSpokenAudioAndMixWithOthers
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
        } catch {
            DebugLogger.shared.log("Tone engine error: \(error.localizedDescription)")
        }
        playerNode.play()
    }
    
    private func playTone() {
    guard let buffer = toneBuffer else { return }
    
    // Ensure engine is running
    if !audioEngine.isRunning {
        do {
            try audioEngine.start()
            DebugLogger.shared.log("Audio engine restarted")
        } catch {
            DebugLogger.shared.log("Audio engine restart failed: \(error.localizedDescription)")
            return
        }
    }
    
    if !playerNode.isPlaying {
        playerNode.play()
    }
    
    playerNode.stop()
    playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts)
    playerNode.play()
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

