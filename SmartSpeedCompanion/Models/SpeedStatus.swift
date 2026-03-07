import Foundation

/// Represents the current speed status relative to the speed limit and user buffer.
public enum SpeedStatus: String, Codable, Equatable {
    /// Speed is strictly within the limit + buffer.
    case safe
    /// Speed is within 2 mph of exceeding the limit + buffer.
    case warning
    /// Speed has exceeded the limit + buffer.
    case over
}
