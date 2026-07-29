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
        Task {
            // Set a short staleDate (2 seconds) so the system treats this as
            // time-sensitive content. On the Always-On Display, a nil staleDate
            // tells the system the content never goes stale, which can cause
            // the system to deprioritize UI refresh cadence to 3+ seconds to
            // save battery. A 2-second staleDate signals that fresh data is
            // arriving regularly and the display should update more frequently.
            await currentActivity?.update(ActivityContent(
                state: state,
                staleDate: Date().addingTimeInterval(2)
            ))
        }
    }
    
    public func endActivity() {
        Task {
            guard let activity = currentActivity else { return }
            
            // Wait shortly then dismiss the activity immediately
            await activity.end(ActivityContent(state: activity.content.state, staleDate: nil), dismissalPolicy: .immediate)
            currentActivity = nil
        }
    }
}