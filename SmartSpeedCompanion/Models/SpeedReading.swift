import Foundation
import SwiftData

/// Represents a single GPS and speed data point collected during a drive session.
@Model
public final class SpeedReading {
    public var timestamp: Date
    public var latitude: Double
    public var longitude: Double
    public var speed: Double
    public var speedLimit: Int
    public var overLimit: Bool
    public var limitSource: String
    
    public init(timestamp: Date = .now,
                latitude: Double,
                longitude: Double,
                speed: Double,
                speedLimit: Int,
                overLimit: Bool,
                limitSource: String) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.speed = speed
        self.speedLimit = speedLimit
        self.overLimit = overLimit
        self.limitSource = limitSource
    }
}
