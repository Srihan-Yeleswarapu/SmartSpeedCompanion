// Path: Core/AlertEngine.swift
import Foundation
import Combine
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
        stopMonitoring()
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
    }
    
    private func playBeep() {
        // Play the standard iOS alert sound. 1320 is a crisp "tink" perfect for notifications.
        // It plays through the active audio route (including CarPlay) and handles its own lifecycle.
        AudioServicesPlayAlertSound(1320)
    }
}