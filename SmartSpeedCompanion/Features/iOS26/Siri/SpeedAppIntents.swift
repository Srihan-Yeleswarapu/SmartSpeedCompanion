// Path: Features/iOS26/Siri/SpeedAppIntents.swift
import AppIntents
import Foundation

struct StartDriveSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Drive Session"
    static var description = IntentDescription("Begin recording a new drive session in Smart Speed Companion")
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppDelegate.sharedDriveViewModel.startSession()
        return .result(dialog: "Drive session started. Stay safe!")
    }
}

struct EndDriveSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "End Drive Session"
    static var description = IntentDescription("Stop recording the current drive session")
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppDelegate.sharedDriveViewModel.endSession()
        
        // Pull latest session data from recorder if available
        if let session = AppDelegate.sharedDriveViewModel.sessionRecorder.currentSession {
            let mins = Int(session.durationSeconds) / 60
            let score = session.drivingScore
            return .result(dialog: "Session ended. You drove for \(mins) minutes with a score of \(score).")
        }
        
        return .result(dialog: "Session ended and saved successfully.")
    }
}

struct GetCurrentSpeedIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Current Speed"
    static var description = IntentDescription("Check your current speed and limit")
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let speed = Int(AppDelegate.sharedDriveViewModel.speed)
        let limit = AppDelegate.sharedDriveViewModel.limit
        
        if speed == 0 {
            return .result(dialog: "You're not currently moving.")
        } else {
            return .result(dialog: "You're currently doing \(speed) miles per hour in a \(limit) zone.")
        }
    }
}

struct SpeedAppShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartDriveSessionIntent(), phrases: [
            "Start my drive in \(.applicationName)",
            "Begin recording in \(.applicationName)",
            "Start \(.applicationName)"
        ])
        AppShortcut(intent: EndDriveSessionIntent(), phrases: [
            "End my drive in \(.applicationName)",
            "Stop recording in \(.applicationName)"
        ])
        AppShortcut(intent: GetCurrentSpeedIntent(), phrases: [
            "What's my speed in \(.applicationName)",
            "How fast am I going in \(.applicationName)"
        ])
    }
}
