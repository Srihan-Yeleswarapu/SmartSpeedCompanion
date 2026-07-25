import Foundation
import SwiftData

/// Represents a user-saved named location (e.g. "Mom's House", "My Favorite Trailhead").
/// Persisted with SwiftData, same pattern as `DriveSession` and `SpeedReading`.
@Model
public final class NamedLocation {
    @Attribute(.unique) public var id: UUID
    public var name: String           // e.g. "Mom's House"
    public var latitude: Double
    public var longitude: Double
    public var address: String?       // reverse-geocoded address string
    public var createdAt: Date
    
    public init(name: String, latitude: Double, longitude: Double, address: String?) {
        self.id = UUID()
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.address = address
        self.createdAt = Date()
    }
}
