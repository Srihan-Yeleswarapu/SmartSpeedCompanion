// iOS 26+ Crash Detection (CoreMotion)
import Foundation
import CoreMotion
import UserNotifications

@MainActor
public final class CrashDetectionManager: ObservableObject {
    private let motionManager = CMMotionManager()
    private let brain: SpeedLimitBrain
    private let sessionRecorder: SessionRecorder
    
    public init(brain: SpeedLimitBrain, sessionRecorder: SessionRecorder) {
        self.brain = brain
        self.sessionRecorder = sessionRecorder
        startCrashDetection()
    }
    
//   private init(speedEngine: startEngine, sessionRecorder: SessionRecorder) {
//       self.speedEngine = speedEngine
//       self.sessionRecorder = sessionRecorder
//       startCrashDetection()
    
    private func startCrashDetection() {
        guard motionManager.isAccelerometerAvailable else { return }
        
        motionManager.accelerometerUpdateInterval = 0.1
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, error in
            guard let self = self, let acceleration = data?.acceleration else { return }
            
            // Calculate total G-force magnitude vector
            let gForce = sqrt(pow(acceleration.x, 2) + pow(acceleration.y, 2) + pow(acceleration.z, 2))
            
            // Simple threshold: > 4G sudden deceleration
            if gForce > 4.0 {
                self.handlePotentialCrash()
            }
        }
    }
    
    private func handlePotentialCrash() {
        // Stop session if running
        if sessionRecorder.isRecording {
            _ = sessionRecorder.endSession()
        }
        
        // Trigger generic local notification alert
        triggerEmergencyAlert()
    }
    
    private func triggerEmergencyAlert() {
        let content = UNMutableNotificationContent()
        content.title = "Possible Crash Detected"
        content.body = "Are you okay? We detected a sudden stop."
        content.sound = .defaultCritical
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}