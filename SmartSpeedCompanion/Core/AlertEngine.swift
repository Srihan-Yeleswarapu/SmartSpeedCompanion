// Path: Core/AlertEngine.swift

import Foundation
import Combine
import AudioToolbox
import AVFoundation

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
    
    // Cooldown tracking
    private var lastBeepTime: Date = .distantPast
    
    // Tone generation
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var toneBuffer: AVAudioPCMBuffer?
    
    // MARK: - Init
    public init(speedEngine: SpeedEngine) {
        setupAudioSession()
        setupToneEngine()
        
        statusCancellable = speedEngine.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] newStatus in
                self?.handleStatusChange(newStatus)
            }
    }
    
    // MARK: - Status Handling
    private func handleStatusChange(_ status: SpeedStatus) {
        let alertsEnabled = UserDefaults.standard.bool(forKey: "audioAlertsEnabled")
        
        if status == .over && alertsEnabled {
            if timerCancellable == nil {
                DebugLogger.shared.log("AlertEngine: Status is OVER. Starting monitor.")
                startMonitoring()
            }
        } else {
            if timerCancellable != nil {
                DebugLogger.shared.log("AlertEngine: Status is \(status) (Alerts: \(alertsEnabled)). Stopping monitor.")
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
                
                // Re-check setting mid-drive
                guard UserDefaults.standard.bool(forKey: "audioAlertsEnabled") else {
                    self.stopMonitoringState()
                    return
                }
                
                self.consecutiveSeconds += 1
                
                // Trigger after 3s, then every 2s
                if self.consecutiveSeconds >= 3 {
                    self.audioAlertActive = true
                    
                    let now = Date()
                    if now.timeIntervalSince(self.lastBeepTime) >= 2.0 {
                        self.lastBeepTime = now
                        self.playAlert()
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
    
    // MARK: - Alert (Sound + Vibration)
    private func playAlert() {
        playTone()
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
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
                    .defaultToSpeaker
                ]
            )
            
            try session.setActive(true)
            
            // Force speaker (helps in car scenarios)
            try session.overrideOutputAudioPort(.speaker)
            
            DebugLogger.shared.log("AlertEngine: Audio session configured.")
        } catch {
            DebugLogger.shared.log("AlertEngine: Audio session error: \(error.localizedDescription)")
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
                // Square wave = sharper alert sound
                let value = sin(theta * Double(frame))
                buffer[frame] = value >= 0 ? 1.0 : -1.0
            }
        }
        
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
        
        do {
            try audioEngine.start()
            DebugLogger.shared.log("AlertEngine: Tone engine started.")
        } catch {
            DebugLogger.shared.log("AlertEngine: Tone engine error: \(error.localizedDescription)")
        }
    }
    
    private func playTone() {
        guard let buffer = toneBuffer else { return }
        
        playerNode.stop()
        playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        playerNode.play()
        
        DebugLogger.shared.log("AlertEngine: Tone played (1052 Hz).")
    }
}