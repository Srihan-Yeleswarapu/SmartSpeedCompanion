import Foundation
import SwiftData

/// Represents a complete recorded drive session containing multiple SpeedReadings.
@Model
public final class DriveSession {
    @Attribute(.unique) public var id: UUID
    public var startTime: Date
    public var endTime: Date?
    
    @Relationship(deleteRule: .cascade)
    public var readings: [SpeedReading]
    
    public init(id: UUID = UUID(), startTime: Date = .now, readings: [SpeedReading] = []) {
        self.id = id
        self.startTime = startTime
        self.readings = readings
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
    
    /// Computes the driving score based on the prototype's formula: max(0, min(100, 100 - (percentTimeOver * 1.5)))
    public var drivingScore: Int {
        let percentTimeOver = (1.0 - percentWithinLimit) * 100.0
        let score = 100.0 - (percentTimeOver * 1.5)
        return Int(max(0, min(100, score)))
    }
}
