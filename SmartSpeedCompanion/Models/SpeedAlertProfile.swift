import Foundation
import SwiftData

/// A speed alert profile with per-road-type buffer thresholds.
/// Users can create multiple profiles (e.g. "Daily Commute", "Weekend Cruise")
/// and switch between them. Follows the same @Model pattern as DriveSession.
@Model
final public class SpeedAlertProfile {
    @Attribute(.unique) public var id: UUID
    public var name: String                      // "Daily Commute", "Weekend Cruise"
    public var isActive: Bool                    // currently selected profile
    public var createdAt: Date
    
    // Per-road-type buffers (in mph — converted to display unit when shown)
    public var highwayBuffer: Int               // e.g. +5
    public var residentialBuffer: Int           // e.g. +3
    public var schoolZoneBuffer: Int            // e.g. 0 (exactly at limit)
    public var workZoneBuffer: Int              // e.g. 0
    public var arterialBuffer: Int              // e.g. +5
    public var defaultBuffer: Int               // fallback for unknown road types
    
    public init(
        name: String,
        isActive: Bool = false,
        createdAt: Date = Date(),
        highwayBuffer: Int = 5,
        residentialBuffer: Int = 3,
        schoolZoneBuffer: Int = 0,
        workZoneBuffer: Int = 0,
        arterialBuffer: Int = 5,
        defaultBuffer: Int = 5
    ) {
        self.id = UUID()
        self.name = name
        self.isActive = isActive
        self.createdAt = createdAt
        self.highwayBuffer = highwayBuffer
        self.residentialBuffer = residentialBuffer
        self.schoolZoneBuffer = schoolZoneBuffer
        self.workZoneBuffer = workZoneBuffer
        self.arterialBuffer = arterialBuffer
        self.defaultBuffer = defaultBuffer
    }
    
    /// Returns the buffer value for a given road type string.
    /// Road types: "highway", "residential", "schoolZone", "workZone", "arterial"
    /// Falls back to `defaultBuffer` for unknown types.
    public func buffer(for roadType: String) -> Int {
        switch roadType.lowercased() {
        case "highway":     return highwayBuffer
        case "residential": return residentialBuffer
        case "schoolzone":  return schoolZoneBuffer
        case "workzone":    return workZoneBuffer
        case "arterial":    return arterialBuffer
        default:            return defaultBuffer
        }
    }
}
