import Foundation
import SwiftData

/// Represents a complete recorded drive session containing multiple SpeedReadings.
@Model
public final class DriveSession {
    @Attribute(.unique) public var id: UUID
    public var startTime: Date
    public var endTime: Date?
    public var startLocationName: String?
    public var endLocationName: String?
    public var destinationPlaceID: String?
    
    @Relationship(deleteRule: .cascade)
    public var readings: [SpeedReading]
    
    public init(id: UUID = UUID(), startTime: Date = .now, readings: [SpeedReading] = []) {
        self.id = id
        self.startTime = startTime
        self.readings = readings
    }
    
    public var title: String {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "MMM d"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        
        let dayStr = dayFormatter.string(from: startTime)
        let timeStr = timeFormatter.string(from: startTime)
        
        let suffix = "at \(timeStr) on \(dayStr)"
        
        if let start = startLocationName, let end = endLocationName, start != "Unknown Location", end != "Unknown Location" {
            return "\(start) to \(end) \(suffix)"
        } else if let start = startLocationName, start != "Unknown Location" {
            return "\(start) \(suffix)"
        } else {
            return "Drive Session \(suffix)"
        }
    }
    
    /// Computes the duration of the drive session in seconds.
    public var durationSeconds: TimeInterval {
        let end = endTime ?? .now
        return end.timeIntervalSince(startTime)
    }
    
    /// Computes the percentage of time spent within the safe speed limit (0.0 to 1.0).
    public var percentWithinLimit: Double {
        guard !readings.isEmpty else { return 1.0 }
        let safeReadings = readings.filter { !$0.overLimit }.count
        return Double(safeReadings) / Double(readings.count)
    }
    
    /// Computes the longest continuous period (in seconds) the user was over the limit.
    public var longestOverstreak: Int {
        var longest = 0
        var current = 0
        for reading in readings {
            if reading.overLimit {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }
    
    /// Computes the average speed over the limit for only the intervals where the user was speeding.
    public var avgMphOverLimit: Double {
        let overReadings = readings.filter { $0.overLimit }
        guard !overReadings.isEmpty else { return 0.0 }
        let totalOver = overReadings.reduce(0.0) { $0 + ($1.speed - Double($1.speedLimit)) }
        return totalOver / Double(overReadings.count)
    }
    
    /// Computes the driving score based on a comprehensive penalty formula.
    public var drivingScore: Int {
        guard !readings.isEmpty else { return 100 }
        
        let percentTimeOver = (1.0 - percentWithinLimit) * 100.0
        let avgOver = avgMphOverLimit
        
        // Severity multiplier: increases if the driver sped heavily when they were over the limit
        let severityMultiplier = 1.0 + (avgOver / 8.0)
        
        // Streak penalty: penalizes long continuous stretches of speeding
        let streakPenalty = min(20.0, Double(longestOverstreak) / 5.0)
        
        let score = 100.0 - (percentTimeOver * severityMultiplier) - streakPenalty
        return Int(max(0, min(100, score)))
    }
}
