// iOS 26+ App Intents & Siri Shortcuts
import AppIntents
import Foundation

struct StartDriveSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Drive Session"
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppDelegate.sharedDriveViewModel.startSession()
        return .result(dialog: "I've started your drive session recording.")
    }
}

struct EndDriveSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "End Drive Session"
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppDelegate.sharedDriveViewModel.endSession()
        return .result(dialog: "Drive session ended and saved.")
    }
}

struct GetCurrentSpeedIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Current Speed"
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let speed = Int(AppDelegate.sharedDriveViewModel.speed)
        return .result(dialog: "Your current speed is \(speed) miles per hour.")
    }
}

struct SmartSpeedShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDriveSessionIntent(),
            phrases: ["Start my drive in \(.applicationName)"]
        )
        AppShortcut(
            intent: EndDriveSessionIntent(),
            phrases: ["End my drive in \(.applicationName)"]
        )
        AppShortcut(
            intent: GetCurrentSpeedIntent(),
            phrases: ["What's my speed in \(.applicationName)"]
        )
    }
}
