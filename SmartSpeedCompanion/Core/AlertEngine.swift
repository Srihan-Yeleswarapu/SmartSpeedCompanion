// Path: Core/AlertEngine.swift
import Foundation
import Combine
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
    
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    
    private var timerCancellable: AnyCancellable?
    private var statusCancellable: AnyCancellable?
    
    public init(speedEngine: SpeedEngine) {
        setupAudio()
        
        statusCancellable = speedEngine.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] newStatus in
                self?.handleStatusChange(newStatus)
            }
        
        configureAudioSession()
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: nil)
    }
    
    deinit {
        let engine = audioEngine
        Task { @MainActor in
            engine.stop()
        }
        NotificationCenter.default.removeObserver(self)
    }

    private func configureAudioSession() {
        do {
            // Using .mixWithOthers is ESSENTIAL to not stop background music on launch.
            // Mode .moviePlayback or .default is sometimes more reliable for synthesized beeps than .spokenAudio
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers, .mixWithOthers])
            DebugLogger.shared.log("Audio Session Configured: .playback/mixWithOthers")
        } catch {
            DebugLogger.shared.log("Audio Session CONFIG FAILED: \(error.localizedDescription)")
        }
    }
    
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
                stopMonitoring()
            }
        }
    }
    
    private func startMonitoring() {
        consecutiveSeconds = 0
        timerCancellable = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                
                // Re-check setting in case it changed mid-drive
                guard UserDefaults.standard.bool(forKey: "audioAlertsEnabled") else {
                    self.stopMonitoring()
                    return
                }
                
                self.consecutiveSeconds += 1
                // Reduced from 5s to 3s for better real-world responsiveness
                if self.consecutiveSeconds >= 3 {
                    self.audioAlertActive = true
                    self.playBeep()
                }
            }
    }
    
    private func stopMonitoring() {
        timerCancellable?.cancel()
        timerCancellable = nil
        consecutiveSeconds = 0
        audioAlertActive = false
        playerNode.stop()
        
        // Deactivate session when monitoring stops to restore music volume
        Task { @MainActor in
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
    
    private func setupAudio() {
        audioEngine.attach(playerNode)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 1)!
        audioEngine.connect(playerNode, to: audioEngine.outputNode, format: format)
        
        do {
            try audioEngine.start()
            DebugLogger.shared.log("AudioEngine STARTED successfully")
        } catch {
            DebugLogger.shared.log("AudioEngine START FAILED: \(error.localizedDescription)")
        }
    }
    
    private func playBeep() {
        // 1. Ensure Session is Active
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            DebugLogger.shared.log("Beep Session Activate FAILED: \(error.localizedDescription)")
        }

        // 2. Ensure Engine is Running
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
                DebugLogger.shared.log("AudioEngine RESTARTED for beep")
            } catch {
                DebugLogger.shared.log("AudioEngine RESTART FAILED: \(error.localizedDescription)")
                return
            }
        }
        
        let sampleRate = 44100.0
        let duration: TimeInterval = 0.35
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            DebugLogger.shared.log("Beep: Failed to create buffer")
            return
        }
        
        buffer.frameLength = frameCount
        let channels = Int(format.channelCount)
        
        // Slightly higher volume (0.25 vs 0.15) and clearer frequency (1046Hz = C6)
        for frame in 0..<Int(frameCount) {
            let value = Float(0.25 * sin(2.0 * .pi * 1046.0 * Double(frame) / sampleRate))
            for channel in 0..<channels {
                buffer.floatChannelData?[channel][frame] = value
            }
        }
        
        // Interrupts active audio on this node to play immediately
        playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        playerNode.play()
        
        // NOTE: We no longer deactivate session here.
        // We deactivate ONLY in stopMonitoring() to avoid rapid toggle issues.
        // This means while over speed, the music remains ducked. This is preferred
        // as it emphasizes the alert state.
    }
    
    @objc private func handleInterruption(notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        if type == .ended {
            guard let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                try? audioEngine.start()
                DebugLogger.shared.log("AudioEngine RESUMED after interruption")
            }
        }
    }
}
