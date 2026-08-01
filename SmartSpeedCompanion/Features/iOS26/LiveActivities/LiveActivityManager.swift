// Path: Features/iOS26/LiveActivities/LiveActivityManager.swift
import Foundation
import ActivityKit

@available(iOS 16.1, *)
public class LiveActivityManager {
    public static let shared = LiveActivityManager()
    
    private var currentActivity: Activity<SpeedActivityAttributes>?
    
    private init() {
        // Only resume if the activity is actually active.
        currentActivity = Activity<SpeedActivityAttributes>.activities.first(where: { $0.activityState == .active })
    }
    
    public func startActivity(sessionStartDate: Date) {
        // If we have an existing activity that isn't active, clear it.
        if let existing = currentActivity, existing.activityState != .active {
            currentActivity = nil
        }
        
        guard currentActivity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        
        let attributes = SpeedActivityAttributes(sessionStartDate: sessionStartDate)
        let initialState = SpeedActivityAttributes.ContentState(
            speed: 0,
            speedLimit: 0,
            status: "safe",
            isRecording: true,
            consecutiveOverSeconds: 0,
            sessionDuration: 0,
            nextManeuver: nil,
            nextManeuverImageName: nil,
            distanceToNextTurn: nil,
            eta: nil
        )
        
        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: initialState, staleDate: nil)
            )
        } catch {
            print("Failed to start Live Activity: \(error)")
        }
    }
    
    public func updateActivity(with state: SpeedActivityAttributes.ContentState) {
        // Capture the activity synchronously so a concurrent endActivity()
        // (which clears the reference) can't make this task no-op or update
        // a *new* activity that started in the meantime.
        guard let activity = currentActivity, activity.activityState == .active else { return }
        Task {
            // Set a short staleDate (2 seconds) so the system treats this as
            // time-sensitive content. On the Always-On Display, a nil staleDate
            // tells the system the content never goes stale, which can cause
            // the system to deprioritize UI refresh cadence to 3+ seconds to
            // save battery. A 2-second staleDate signals that fresh data is
            // arriving regularly and the display should update more frequently.
            guard activity.activityState == .active else { return }
            await activity.update(ActivityContent(
                state: state,
                staleDate: Date().addingTimeInterval(2)
            ))
        }
    }
    
    /// Ends the activity tracked by this manager (if any). Idempotent.
    /// Captures the activity reference synchronously so the reference can be
    /// cleared immediately; the dismissal still happens in the background.
    public func endActivity() {
        guard let activity = currentActivity else { return }
        currentActivity = nil
        Task {
            guard activity.activityState != .ended else { return }
            await activity.end(ActivityContent(state: activity.content.state, staleDate: nil), dismissalPolicy: .immediate)
        }
    }
    
    /// Ends EVERY live activity of this type — including ones created by a
    /// previous app process. Live Activity instances are owned by the system
    /// and survive app termination, so a stale activity (e.g. from a drive
    /// that was discarded, or an app that was force-quit) can keep a frozen
    /// Dynamic Island card alive even though no session is running.
    ///
    /// Called at launch whenever we can prove no real session exists. The
    /// DriveViewModel owns the proof (SessionRecorder state), so this method
    /// intentionally takes no session argument.
    public func endAllActivities() {
        currentActivity = nil
        let all = Activity<SpeedActivityAttributes>.activities.filter { $0.activityState != .ended }
        for activity in all {
            Task {
                guard activity.activityState != .ended else { return }
                await activity.end(ActivityContent(state: activity.content.state, staleDate: nil), dismissalPolicy: .immediate)
            }
        }
    }
    
    /// Returns true when the system currently has an *active* (non-ended)
    /// live activity of this type. Useful for diagnosing stale state.
    public func hasActiveActivity() -> Bool {
        Activity<SpeedActivityAttributes>.activities.contains { $0.activityState == .active }
    }
}