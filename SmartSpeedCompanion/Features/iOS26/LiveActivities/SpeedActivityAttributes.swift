// Path: Features/iOS26/LiveActivities/SpeedActivityAttributes.swift
import ActivityKit
import Foundation

public struct SpeedActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var speed: Double
        public var speedLimit: Int
        public var status: String          // "safe" | "warning" | "over"
        public var isRecording: Bool
        public var consecutiveOverSeconds: Int
        public var sessionDuration: TimeInterval
        
        // Navigation metadata
        public var nextManeuver: String?
        public var nextManeuverImageName: String?
        public var distanceToNextTurn: Double?
        public var eta: Date?
    }
    
    public var sessionStartDate: Date
    public init(sessionStartDate: Date) {
        self.sessionStartDate = sessionStartDate
    }
}
