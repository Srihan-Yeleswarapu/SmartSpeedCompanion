import Foundation
import SwiftData

/// A vehicle profile with its own buffer settings, alert preferences,
/// and vehicle icon. Users can create up to 5 profiles.
/// Follows the same @Model pattern as DriveSession and NamedLocation.
@Model
final public class VehicleProfile {
    @Attribute(.unique) public var id: UUID
    public var name: String                    // "Work Truck", "Family SUV"
    public var isActive: Bool
    public var createdAt: Date
    
    // Per-vehicle settings (mirrors @AppStorage keys)
    public var userBuffer: Int                 // replaces the global userBuffer
    public var audioAlertsEnabled: Bool
    public var hapticAlertsEnabled: Bool
    public var hapticAlertStyle: String
    public var avoidHighways: Bool
    public var vehicleIconId: String           // references VehicleIcon.id
    public var measurementSystem: String
    
    // Per-vehicle stats
    public var totalTrips: Int
    public var totalDistanceMiles: Double
    public var totalDurationSeconds: TimeInterval
    
    public init(
        name: String,
        isActive: Bool = false,
        createdAt: Date = Date(),
        userBuffer: Int = 5,
        audioAlertsEnabled: Bool = true,
        hapticAlertsEnabled: Bool = true,
        hapticAlertStyle: String = "strong",
        avoidHighways: Bool = false,
        vehicleIconId: String = "default_blue",
        measurementSystem: String = "Imperial",
        totalTrips: Int = 0,
        totalDistanceMiles: Double = 0,
        totalDurationSeconds: TimeInterval = 0
    ) {
        self.id = UUID()
        self.name = name
        self.isActive = isActive
        self.createdAt = createdAt
        self.userBuffer = userBuffer
        self.audioAlertsEnabled = audioAlertsEnabled
        self.hapticAlertsEnabled = hapticAlertsEnabled
        self.hapticAlertStyle = hapticAlertStyle
        self.avoidHighways = avoidHighways
        self.vehicleIconId = vehicleIconId
        self.measurementSystem = measurementSystem
        self.totalTrips = totalTrips
        self.totalDistanceMiles = totalDistanceMiles
        self.totalDurationSeconds = totalDurationSeconds
    }
}
