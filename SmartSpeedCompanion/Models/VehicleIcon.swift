import Foundation

/// Represents a selectable vehicle icon that replaces the default blue dot on the map.
/// All icons are free and unlocked by default. The `isPremium` flag is reserved for the
/// future ad-gated layer.
public struct VehicleIcon: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let systemImageName: String
    public let isPremium: Bool
    
    public init(id: String, displayName: String, systemImageName: String, isPremium: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.systemImageName = systemImageName
        self.isPremium = isPremium
    }
}

extension VehicleIcon {
    public static let catalog: [VehicleIcon] = [
        VehicleIcon(id: "default_blue", displayName: "Default Blue Dot", systemImageName: "circle.fill"),
        VehicleIcon(id: "sports_car_red", displayName: "Red Sportscar", systemImageName: "car.side.fill"),
        VehicleIcon(id: "sports_car_blue", displayName: "Blue Sportscar", systemImageName: "car.side.fill"),
        VehicleIcon(id: "pickup_truck", displayName: "Classic Pickup", systemImageName: "truck.pickup.side.fill"),
        VehicleIcon(id: "suv", displayName: "Electric SUV", systemImageName: "suv.side.fill"),
        VehicleIcon(id: "motorcycle", displayName: "Motorcycle", systemImageName: "motorcycle.fill"),
        VehicleIcon(id: "scooter", displayName: "Scooter", systemImageName: "scooter"),
        VehicleIcon(id: "convertible", displayName: "Retro Convertible", systemImageName: "car.side.fill"),
        VehicleIcon(id: "truck_monster", displayName: "Monster Truck", systemImageName: "truck.pickup.side.fill"),
        VehicleIcon(id: "ev_car", displayName: "Electric Car", systemImageName: "bolt.car.fill"),
        VehicleIcon(id: "bicycle", displayName: "Bicycle", systemImageName: "bicycle"),
        VehicleIcon(id: "airplane", displayName: "Airplane", systemImageName: "airplane.departure"),
    ]
    
    /// Returns the icon for a given id, or the default blue dot if not found.
    public static func icon(for id: String) -> VehicleIcon {
        catalog.first(where: { $0.id == id }) ?? catalog[0]
    }
}
