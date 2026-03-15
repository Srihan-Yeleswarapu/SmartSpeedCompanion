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
        
        // Ensure phone audio, CarPlay, and background operation work seamlessly
        do {
            // Using .playback ensures audio plays even if the silent switch is on.
            // .spokenAudio mode is ideal for speech-centric apps and background alerts.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[AlertEngine] Failed to configure AVAudioSession: \(error)")
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: nil)
    }
    
    deinit {
        // Stop audio engine if it's running
        let engine = audioEngine
        Task { @MainActor in
            engine.stop()
        }
        NotificationCenter.default.removeObserver(self)
    }
    
    private func handleStatusChange(_ status: SpeedStatus) {
        if status == .over {
            if timerCancellable == nil {
                startMonitoring()
            }
        } else {
            stopMonitoring()
        }
    }
    
    private func startMonitoring() {
        timerCancellable = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.consecutiveSeconds += 1
                if self.consecutiveSeconds >= 5 {
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
    }
    
    private func setupAudio() {
        audioEngine.attach(playerNode)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 1)!
        audioEngine.connect(playerNode, to: audioEngine.outputNode, format: format)
        try? audioEngine.start()
    }
    
    private func playBeep() {
        let sampleRate = 44100.0
        let duration: TimeInterval = 0.35
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        
        buffer.frameLength = frameCount
        let channels = Int(format.channelCount)
        
        for frame in 0..<Int(frameCount) {
            let value = Float(0.15 * sin(2.0 * .pi * 1046.0 * Double(frame) / sampleRate))
            for channel in 0..<channels {
                buffer.floatChannelData?[channel][frame] = value
            }
        }
        
        // Interrupts active audio to play immediately without stacking
        playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        playerNode.play()
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
            }
        }
    }
}
