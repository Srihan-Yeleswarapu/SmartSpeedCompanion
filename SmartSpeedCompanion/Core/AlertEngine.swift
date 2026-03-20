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
        let alertsEnabled = isAudioAlertsEnabled
        
        if status == .over && alertsEnabled {
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
                
                guard self.isAudioAlertsEnabled else {
                    self.stopMonitoringState()
                    return
                }
                
                self.consecutiveSeconds += 1
                
                if self.consecutiveSeconds >= 3 {
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
        playTone()
        hapticSpeedingAlert()
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
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        
        do {
            hapticEngine = try CHHapticEngine()
            try hapticEngine?.start()
        } catch {
            DebugLogger.shared.log("Haptics error: \(error.localizedDescription)")
        }
    }
    
    // MARK: - HAPTIC PATTERNS
    
    // 🚨 SPEEDING: aggressive, spammy, impossible to ignore
    private func hapticSpeedingAlert() {
        guard let _ = hapticEngine else { return }
        
        var events: [CHHapticEvent] = []
        
        for i in stride(from: 0.0, to: 1.0, by: 0.08) {
            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    .init(parameterID: .hapticIntensity, value: 1.0),
                    .init(parameterID: .hapticSharpness, value: 1.0)
                ],
                relativeTime: i
            )
            events.append(event)
        }
        
        playHaptic(events)
    }
    
    // 💥 Explosion / cloud feel
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
    
    // ↩️ LEFT
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
    
    // ↪️ RIGHT
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
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try hapticEngine?.makePlayer(with: pattern)
            try player?.start(atTime: 0)
        } catch {
            DebugLogger.shared.log("Haptic playback error: \(error.localizedDescription)")
        }
    }
}
