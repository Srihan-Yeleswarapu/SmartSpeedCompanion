import Foundation
import UIKit
import SwiftUI

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
        // The DEFAULT was previously `circle.fill` rendered as a "Default
        // Blue Dot" — TestFlight 29-tester feedback called this out as
        // "looks like straight garbage". `car.fill` is a real vehicle
        // symbol so even the un-customized new install looks intentional
        // instead of a glowing system dot. Catalog ordering kept `default`
        // first so existing userDefaults-migrated installs continue to
        // resolve to a known icon id.
        VehicleIcon(id: "default_blue", displayName: "Default", systemImageName: "car.fill"),
        // Vehicle symbol names follow Apple's SF Symbols catalog so they
        // render predictably across the picker preview AND on the map's
        // MKAnnotationView (was previously gated to non-default icons
        // only — read LiveMapView.Coordinator.mapView(_:viewFor:) for the
        // rendering path).
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

    /// Returns the icon for a given id, or the default vehicle icon if not found.
    public static func icon(for id: String) -> VehicleIcon {
        catalog.first(where: { $0.id == id }) ?? catalog[0]
    }

    /// The tint used when rendering this icon on the map and inside the
    /// picker preview header. Centralized here so the picker and the
    /// MKAnnotationView agree (TestFlight 29-tester feedback: switching
    /// icon left a "garbage" view — the tint was inconsistent across
    /// the two surfaces).
    public var tintColor: VehicleIconTint {
        switch id {
        case "sports_car_red":      return .red
        case "sports_car_blue":     return .cyan
        case "pickup_truck":        return .brown
        case "suv":                 return .green
        case "motorcycle":          return .orange
        case "scooter":             return .purple
        case "convertible":         return .gold
        case "truck_monster":       return .lime
        case "ev_car":              return .cyan
        case "bicycle":             return .skyBlue
        case "airplane":            return .lavender
        default:                    return .cyan   // Default Blue — keep cyan to avoid regressions.
        }
    }
}

/// Typed tint palette for the vehicle icon renderer. SwiftUI and UIKit
/// each have their own color types so we expose both via properties so
/// picker + map + any future SwiftUI/UIKit consumer share one source
/// of truth (was previously duplicated across `LiveMapView.swiftUIColor`
/// and `VehicleIconPickerSheet.tintUIColor` — code review flagged the
/// duplication).
public enum VehicleIconTint {
    case red, cyan, brown, green, orange, purple, gold, lime, skyBlue, lavender

    /// UIKit color — used by the live `MKAnnotationView.image` rendered
    /// on the map.
    public var uiColor: UIColor {
        switch self {
        case .red:      return UIColor(red: 1.00, green: 0.20, blue: 0.20, alpha: 1)
        case .cyan:     return UIColor(DesignSystem.cyan)
        case .brown:    return UIColor(red: 0.80, green: 0.50, blue: 0.20, alpha: 1)
        case .green:    return UIColor(DesignSystem.neonGreen)
        case .orange:   return UIColor(red: 1.00, green: 0.60, blue: 0.00, alpha: 1)
        case .purple:   return UIColor(red: 0.80, green: 0.30, blue: 0.80, alpha: 1)
        case .gold:     return UIColor(red: 1.00, green: 0.80, blue: 0.00, alpha: 1)
        case .lime:     return UIColor(red: 0.40, green: 0.80, blue: 0.20, alpha: 1)
        case .skyBlue:  return UIColor(red: 0.60, green: 0.80, blue: 1.00, alpha: 1)
        case .lavender: return UIColor(red: 0.70, green: 0.70, blue: 0.90, alpha: 1)
        }
    }

    /// SwiftUI color — used by the picker preview header + grid cells.
    public var color: Color {
        Color(uiColor)
    }
}
