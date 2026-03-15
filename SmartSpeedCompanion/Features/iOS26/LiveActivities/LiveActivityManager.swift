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
            // Push updates efficiently. (DriveViewModel should throttle this call to ~5s)
            await currentActivity?.update(ActivityContent(state: state, staleDate: nil))
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
