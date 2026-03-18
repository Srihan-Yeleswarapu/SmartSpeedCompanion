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
    
    public init(speedEngine: SpeedEngine) {
        statusCancellable = speedEngine.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] newStatus in
                self?.handleStatusChange(newStatus)
            }
    }
    
    deinit {
        cancelTimer()
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
                stopMonitoringState()
            }
        }
    }
    
    // Track the last time a beep was played to enforce a 5-second cooldown
    private var lastBeepTime: Date = .distantPast

    private func startMonitoring() {
        consecutiveSeconds = 0
        timerCancellable = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                
                // Re-check setting in case it changed mid-drive
                guard UserDefaults.standard.bool(forKey: "audioAlertsEnabled") else {
                    self.stopMonitoringState()
                    return
                }
                
                self.consecutiveSeconds += 1
                // Trigger after 3s, then every 5s to avoid spam
                if self.consecutiveSeconds >= 3 {
                    self.audioAlertActive = true
                    let now = Date()
                    if now.timeIntervalSince(self.lastBeepTime) >= 5.0 {
                        self.lastBeepTime = now
                        self.playBeep()
                    }
                }
            }
    }
    
    private func stopMonitoringState() {
        cancelTimer()
        self.consecutiveSeconds = 0
        self.audioAlertActive = false
        self.timerCancellable = nil
    }
    
    nonisolated private func cancelTimer() {
        timerCancellable?.cancel()
    }
    
    
    private func playBeep() {
        // Must activate an audio session BEFORE playing a system sound so that
        // the sound routes through CarPlay and isn't silenced by the ringer switch.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            DebugLogger.shared.log("AlertEngine: Audio session error: \(error.localizedDescription)")
        }
        // 1052 = "Tock" — a short, piercing alert that cuts through car noise
        AudioServicesPlayAlertSound(1052)
        DebugLogger.shared.log("AlertEngine: BEEP played.")
    }
}