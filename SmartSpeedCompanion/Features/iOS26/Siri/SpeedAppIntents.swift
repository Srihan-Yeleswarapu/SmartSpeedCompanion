// Path: Features/iOS26/Siri/SpeedAppIntents.swift
import AppIntents
import Foundation

struct StartDriveSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Drive Session"
    static var description = IntentDescription("Begin recording a new drive session in Speedio")
    
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

// MARK: - Read-only Siri intents (v2.2.0+)
//
// These four Intents expose live view-model state to Siri without taking a
// `@Parameter`. They mirror the data the in-app HUD already shows: posted
// speed limit, distance to the upcoming turn, ETA, and remaining distance
// to the destination. Each Intent is @MainActor because every read goes
// through `AppDelegate.sharedDriveViewModel` (`@MainActor` final class).

struct GetSpeedLimitIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Speed Limit"
    static var description = IntentDescription("Check the current posted speed limit for the road you're on")
    // Read-only intent — Siri runs in the background and speaks the dialog
    // without pulling Speedoio's UI to the front.
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let viewModel = AppDelegate.sharedDriveViewModel
        let limitMph = viewModel.limit
        let system = SpeedFormatting.measurementSystem()

        // `limit == 0` is the engine's "no posted limit yet" sentinel
        // (SpeedEngine only writes non-zero after a successful provider
        // fetch). Drive a bit before asking again so we have something to
        // speak back.
        if limitMph <= 0 {
            return .result(dialog: "I don't have a speed limit for here yet. Drive a bit further and I'll fetch one.")
        }

        let display = SpeedFormatting.limitDisplay(forMph: limitMph, measurementSystem: system)
        let unitLong = SpeedFormatting.unitLabelLong(measurementSystem: system)
        return .result(dialog: "The speed limit here is \(display.value) \(unitLong).")
    }
}

struct GetNextManeuverDistanceIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Distance to Next Turn"
    static var description = IntentDescription("Check how far until your next turn")
    // Read-only intent — Siri runs in the background and speaks the dialog
    // without pulling Speedoio's UI to the front.
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let viewModel = AppDelegate.sharedDriveViewModel
        let system = SpeedFormatting.measurementSystem()

        // Both gates are needed: `isNavigating` flips OFF the moment
        // `endNavigation` runs, but `currentRoute` may also be nil when the
        // user has a destination picked but no route computed yet.
        guard viewModel.isNavigating, viewModel.currentRoute != nil else {
            return .result(dialog: "You're not navigating right now. Start a route, then I'll tell you how far to your next turn.")
        }

        let meters = viewModel.distanceToNextTurn
        // Within ~8 m the step is essentially "right here"; don't speak back
        // a noise-value like "0 feet". Encourage the driver instead.
        if meters < 8 {
            return .result(dialog: "Your next turn is right here. Get ready to turn!")
        }

        let disp = SpeedFormatting.distanceDisplay(forMeters: meters, measurementSystem: system)
        let rounded = Int(disp.value.rounded())
        return .result(dialog: "Your next turn is in \(rounded) \(disp.unit).")
    }
}

struct GetETAIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Arrival Time"
    static var description = IntentDescription("Check what time you will arrive at your destination")
    // Read-only intent — Siri runs in the background and speaks the dialog
    // without pulling Speedoio's UI to the front.
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let viewModel = AppDelegate.sharedDriveViewModel

        guard viewModel.isNavigating else {
            return .result(dialog: "Start a route first and I'll tell you when you'll arrive.")
        }

        // `eta` can briefly be nil right after `startNavigation` runs and
        // before the next `updateNavigationProgress` tick writes a value.
        guard let eta = viewModel.eta else {
            return .result(dialog: "I'm still calculating your arrival time. Try again in a few seconds.")
        }

        // `.short` time style returns e.g. "5:47 PM" using the user's locale.
        // Using `DateFormatter` here instead of `Date.FormatStyle` because
        // AppIntents' `.result(dialog:)` only accepts `LocalizedStringResource`
        // interpolation strings, which `Foundation.Date.FormatStyle` cannot
        // format without going through a formatter.
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.locale = .current
        let timeStr = formatter.string(from: eta)

        // For ETAs that cross midnight, the bare time-of-day is ambiguous
        // — "12:20 AM" reads as "in 20 min" rather than "tomorrow morning".
        // Append "tomorrow" / "on <date>" only when the day actually
        // differs from now. This matters most for late-night drivers
        // (TestFlight feedback context: someone gets in at 11:55 PM with
        // a 30 min ETA — Siri used to say just "12:20 AM").
        let cal = Calendar.current
        var daySuffix = ""
        if cal.isDateInTomorrow(eta) {
            daySuffix = " tomorrow"
        } else if !cal.isDate(eta, inSameDayAs: Date()) {
            let dayFormatter = DateFormatter()
            dayFormatter.dateStyle = .medium
            dayFormatter.timeStyle = .none
            dayFormatter.locale = .current
            daySuffix = " on \(dayFormatter.string(from: eta))"
        }

        return .result(dialog: "You'll arrive around \(timeStr)\(daySuffix).")
    }
}

struct GetDistanceToDestinationIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Distance to Destination"
    static var description = IntentDescription("How far away your final destination is")
    // Read-only intent — Siri runs in the background and speaks the dialog
    // without pulling Speedoio's UI to the front.
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let viewModel = AppDelegate.sharedDriveViewModel
        let system = SpeedFormatting.measurementSystem()

        guard viewModel.isNavigating else {
            return .result(dialog: "Pick a destination first and I'll tell you how far.")
        }

        let meters = viewModel.distanceToDestination
        let disp = SpeedFormatting.distanceDisplay(forMeters: meters, measurementSystem: system)
        let rounded = Int(disp.value.rounded())

        // Sub-100 m is treated as "almost there" to give the driver an
        // arrival-mode voice prompt, which matches the in-app
        // "PROACTIVE ARRIVAL" announce threshold (10 m, but voice can be
        // triggered slightly earlier without being annoying).
        if meters < 100 {
            return .result(dialog: "You're almost there — about \(rounded) \(disp.unit) to your destination.")
        }
        return .result(dialog: "You have \(rounded) \(disp.unit) to go until your destination.")
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
            intent: GetSpeedLimitIntent(),
            phrases: [
                "What is my speed limit in \(.applicationName)",
                "What's my speed limit in \(.applicationName)",
                "What is the speed limit in \(.applicationName)",
                "How fast can I go in \(.applicationName)",
                "What's the limit here in \(.applicationName)"
            ],
            shortTitle: "Speed Limit",
            systemImageName: "speedometer"
        )
        AppShortcut(
            intent: GetNextManeuverDistanceIntent(),
            phrases: [
                "How far is my next turn in \(.applicationName)",
                "How much further until my next turn in \(.applicationName)",
                "How much more distance until I turn in \(.applicationName)",
                "Distance to my next turn in \(.applicationName)",
                "When is my next turn in \(.applicationName)"
            ],
            shortTitle: "Next Turn",
            systemImageName: "arrow.turn.up.right"
        )
        AppShortcut(
            intent: GetETAIntent(),
            phrases: [
                "When will I arrive in \(.applicationName)",
                "What time will I arrive in \(.applicationName)",
                "What time is my arrival in \(.applicationName)",
                "When do I arrive in \(.applicationName)",
                "What is my ETA in \(.applicationName)"
            ],
            shortTitle: "Arrival Time",
            systemImageName: "clock.fill"
        )
        AppShortcut(
            intent: GetDistanceToDestinationIntent(),
            phrases: [
                "How far away is my destination in \(.applicationName)",
                "How far to my destination in \(.applicationName)",
                "How far to my final destination in \(.applicationName)",
                "Distance to my destination in \(.applicationName)",
                "How much further until I arrive in \(.applicationName)"
            ],
            shortTitle: "Distance Left",
            systemImageName: "mappin.and.ellipse"
        )
        // Note: NavigateToDestinationIntent is not included in AppShortcuts
        // because String parameters cannot be used in parameterized shortcut phrases.
        // The intent can still be triggered via Siri by name.
    }
}