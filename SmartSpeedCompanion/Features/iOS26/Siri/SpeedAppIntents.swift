// Path: Features/iOS26/Siri/SpeedAppIntents.swift
import AppIntents
import Foundation

struct StartDriveSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Drive Session"
    static var description = IntentDescription("Begin recording a new drive session in Speed Sense")
    
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

struct NavigateToDestinationIntent: AppIntent {
    static var title: LocalizedStringResource = "Navigate to Destination"
    static var description = IntentDescription("Start navigation to a specific place")
    
    @Parameter(title: "Destination")
    var destinationName: String
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let items = await AppDelegate.sharedDriveViewModel.searchDestinationTrigger(destinationName)
        if let first = items.first {
            await AppDelegate.sharedDriveViewModel.startNavigation(to: first)
            return .result(dialog: "Navigating to \(first.name ?? "destination").")
        } else {
            return .result(dialog: "I couldn't find \(destinationName).")
        }
    }
}

struct SpeedAppShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDriveSessionIntent(),
            phrases: [
                "Start my drive in \(.applicationName)",
                "Begin recording in \(.applicationName)",
                "Start \(.applicationName)"
            ],
            shortTitle: "Start Drive",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: EndDriveSessionIntent(),
            phrases: [
                "End my drive in \(.applicationName)",
                "Stop recording in \(.applicationName)"
            ],
            shortTitle: "End Drive",
            systemImageName: "stop.fill"
        )
        AppShortcut(
            intent: GetCurrentSpeedIntent(),
            phrases: [
                "What's my speed in \(.applicationName)",
                "How fast am I going in \(.applicationName)"
            ],
            shortTitle: "Check Speed",
            systemImageName: "speedometer"
        )
        AppShortcut(
            intent: NavigateToDestinationIntent(),
            phrases: [
                "Navigate to \(\.$destinationName) in \(.applicationName)",
                "Take me to \(\.$destinationName) in \(.applicationName)"
            ],
            shortTitle: "Navigate",
            systemImageName: "arrow.turn.up.right"
        )
    }
}