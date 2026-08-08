import SwiftUI
import Combine

public class AppState: ObservableObject {
    // ════════════════════════════════════════════════════════════════════
    // MARK: - Persisted state
    // ════════════════════════════════════════════════════════════════════
    //
    // The single source of truth for the first-run onboarding funnel.
    // Replaces the previous five separate `@AppStorage` Booleans
    // (`hasSelectedState`, `hasCompletedOnboarding`,
    // `hasSeenTutorialTransition`, `hasCompletedTutorial`,
    // `hasSeenLocationPermission`) — see `OnboardingStep.nextCase` for the
    // helper each "finish" handler uses to advance. `AppRootView` switches
    // directly on `onboardingStep`.
    @AppStorage("onboardingStep") public var onboardingStep: OnboardingStep = .questions

    @AppStorage("userState") public var userState: String = ""
    // Persisted so we can present Sign In (instead of Sign Up) when a returning user signs out.
    @AppStorage("hasEverAuthenticated") public var hasEverAuthenticated: Bool = false

    @Published public var authManager = AuthenticationManager.shared

    // Relay changes from authManager to appState so views can react
    private var cancellables = Set<AnyCancellable>()

    // ════════════════════════════════════════════════════════════════════
    // MARK: - Init
    // ════════════════════════════════════════════════════════════════════
    public init() {
        // One-time migration from the OLD five-boolean funnel to the new
        // `onboardingStep` enum. Runs on first launch after this build
        // ships, then self-cleans by removing the legacy keys so
        // subsequent launches skip the guard entirely.
        //
        // IMPORTANT — the OLD Booleans had INVERTED semantics from the new
        // enum. `has<X> == true` meant "user has PASSED this step"
        // (the gate was open past it), whereas `onboardingStep == .X`
        // means "user is AT this step". So the migration preserves funnel
        // POSITION by picking the first step whose OLD bool is FALSE
        // (i.e. the user has NOT yet passed it) and assigning the new enum
        // TO that step. A literal "if hasSelectedState==true -> .stateSelection"
        // mapping — which is what the spec sketch suggested — would
        // regress every fully-finished user back to step 1. The mapping
        // below is the inverted, position-preserving one.
        migrateFunnelBooleansIfNeeded()

        authManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Setup preferences syncing listeners
        setupSettingsSync()

        // Account-creation hook: when `AuthenticationManager` posts
        // `.userDidSignUp` (after a successful email/password sign-up OR
        // first-time Apple Sign In, both of which create a new Firebase
        // Auth account), reset the onboarding funnel so the new account
        // is routed through survey → privacy transition → feature
        // tutorial rather than dropped straight into the Drive tab.
        NotificationCenter.default.addObserver(
            forName: .userDidSignUp,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resetOnboardingFunnel()
        }
    }

    /// Drops the legacy five-boolean funnel and translates it (preserving
    /// current funnel position) into the new `onboardingStep` enum.
    /// Idempotent: after the first successful run, every legacy key has
    /// been removed so the guard short-circuits and the function returns
    /// without touching any state.
    ///
    /// "Preserving funnel position" means: pick the EARLIEST step whose
    /// OLD boolean is FALSE — that is the step the user is still
    /// sitting at — and set `onboardingStep` to that step. If all five
    /// old booleans are TRUE the user has completed the entire funnel,
    /// so we put them in `.complete` (matching the OLD code's `else
    /// { DriveRootView() }` branch).
    private func migrateFunnelBooleansIfNeeded() {
        let legacyKeys = [
            "hasSelectedState",
            "hasCompletedOnboarding",
            "hasSeenTutorialTransition",
            "hasCompletedTutorial",
            "hasSeenLocationPermission"
        ]
        guard legacyKeys.contains(where: { UserDefaults.standard.object(forKey: $0) != nil }) else {
            return
        }

        if !UserDefaults.standard.bool(forKey: "hasSelectedState") {
            // State selection was removed — users who hadn't picked a state
            // skip straight to the onboarding questions.
            onboardingStep = .questions
        } else if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            onboardingStep = .questions
        } else if !UserDefaults.standard.bool(forKey: "hasSeenTutorialTransition") {
            onboardingStep = .transition
        } else if !UserDefaults.standard.bool(forKey: "hasCompletedTutorial") {
            onboardingStep = .tutorial
        } else if !UserDefaults.standard.bool(forKey: "hasSeenLocationPermission") {
            onboardingStep = .locationPermission
        } else {
            onboardingStep = .complete
        }

        // Drop the old keys so subsequent launches skip this guard.
        legacyKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    // ════════════════════════════════════════════════════════════════════
    // MARK: - Funnel reset
    // ════════════════════════════════════════════════════════════════════

    /// Resets every onboarding-funnel flag back to its "fresh account"
    /// default. Call this right after a successful account-creation
    /// path (email/password sign-up, Apple Sign In first-time grant, etc.)
    /// so `AppRootView` routes the new account through the funnel (survey
    /// → privacy transition → feature tutorial) instead of dropping them
    /// straight into the Drive tab.
    ///
    /// `hasEverAuthenticated` is deliberately NOT reset — that flag is a
    /// device-level marker (used to default the post-funnel screen to
    /// Sign In vs Sign Up after sign-out) and must persist across
    /// accounts on the same device.
    ///
    /// Mutating `@AppStorage` properties (rather than writing to
    /// `UserDefaults` directly) causes SwiftUI to re-publish automatically
    /// on the next runloop — no manual observer wiring required, and no
    /// risk of the underlying key string drifting away from this
    /// declaration.
    @MainActor
    public func resetOnboardingFunnel() {
        userState = ""
        onboardingStep = .questions
    }

    private func setupSettingsSync() {
        // Observe all critical settings keys in UserDefaults and push updates to Firestore
        let settingsKeys = [
            "userBuffer", "audioAlertsEnabled",
            "voiceNavEnabled", "speedUnit", "avoidHighways", "measurementSystem",
            "backgroundVibrationAlertsEnabled"
        ]

        for _ in settingsKeys {
            UserDefaults.standard
                .publisher(for: \.self)
                .debounce(for: .seconds(2), scheduler: RunLoop.main) // Prevent spamming Firestore
                .sink { _ in
                    if AuthenticationManager.shared.isAuthenticated {
                        AuthenticationManager.shared.syncUserPreferences()
                    }
                }
                .store(in: &cancellables)
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - OnboardingStep
//
// Six stages the first-run funnel walks through. The previous design used a
// Boolean per stage (`hasSelectedState`, `hasCompletedOnboarding`, …) — those
// Booleans were INVERTED gates (`true` meant "past this step"), which made the
// `AppRootView` chain long, error-prone, and hard to reason about. A single
// enum replaces all of them: the value tells `AppRootView` which view to show
// next, and advancing the funnel is a single assignment
// (`appState.onboardingStep = appState.onboardingStep.nextCase`). Idempotent
// at `.complete` so it's safely callable from any finish handler.
// ═══════════════════════════════════════════════════════════════════════════════

public enum OnboardingStep: String, Codable, CaseIterable, Sendable {
    case stateSelection
    case questions
    case transition
    case tutorial
    case locationPermission
    case complete

    /// The funnel step immediately AFTER this one. Calling `.nextCase`
    /// on `.complete` returns `.complete` (loop guard) so handlers can
    /// fire unconditionally — the worst-case double-fire still leaves
    /// the funnel in `.complete`, not past it.
    public var nextCase: OnboardingStep {
        switch self {
        // `.stateSelection` is a legacy value — persisted users who finish
        // the onboarding questions should advance to `.transition`, not loop
        // back to `.questions` which would render the same view infinitely.
        case .stateSelection:    return .transition
        case .questions:         return .transition
        case .transition:        return .tutorial
        case .tutorial:          return .locationPermission
        case .locationPermission: return .complete
        case .complete:          return .complete
        }
    }
}

// Helper to make kvo observable standard keys if needed,
// though manual observation is often safer for UserDefaults.

extension UserDefaults {
    @objc var userBuffer: Double { double(forKey: "userBuffer") }
    @objc var audioAlertsEnabled: Bool { bool(forKey: "audioAlertsEnabled") }
    @objc var hapticsEnabled: Bool { bool(forKey: "hapticsEnabled") }
    @objc var voiceNavEnabled: Bool { bool(forKey: "voiceNavEnabled") }
    @objc var avoidHighways: Bool { bool(forKey: "avoidHighways") }
    @objc var speedUnit: String? { string(forKey: "speedUnit") }
    @objc var measurementSystem: String? { string(forKey: "measurementSystem") }
}

/// Posted by `AuthenticationManager` whenever a brand-new Firebase Auth
/// account is created (success branch of `signUp(...)` and the first-time
/// grant in `signInWithApple(...)`). `AppState` observes this on the main
/// queue and resets the onboarding funnel so the new account walks it
/// instead of landing directly in the Drive tab.
extension Notification.Name {
    static let userDidSignUp = Notification.Name("userDidSignUp")
}
