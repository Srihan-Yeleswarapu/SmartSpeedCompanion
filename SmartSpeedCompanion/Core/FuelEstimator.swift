import Foundation
import CoreLocation

/// Helper for estimating fuel usage, cost, and CO₂ emissions for a trip.
/// Supports both Imperial (MPG, gallons, $/gal) and Metric (L/100km, liters, $/L) units.
public struct FuelEstimator {
    
    // MARK: - Imperial (MPG / gallons)
    
    /// Gallons of fuel used = distance (miles) / fuel efficiency (MPG).
    public static func estimateFuelUsed(distanceMiles: Double, mpg: Double) -> Double {
        guard mpg > 0 else { return 0 }
        return distanceMiles / mpg
    }
    
    /// Cost = fuel used (gallons) × price per gallon.
    public static func estimateFuelCost(fuelUsedGallons: Double, pricePerGallon: Double) -> Double {
        return fuelUsedGallons * pricePerGallon
    }
    
    /// CO₂ emissions in lbs = fuel used (gallons) × 19.6 lbs CO₂ per gallon (gasoline).
    public static func estimateCO2(fuelUsedGallons: Double) -> Double {
        return fuelUsedGallons * 19.6
    }
    
    // MARK: - Metric (L/100km / liters)
    
    /// Liters of fuel used = (L/100km / 100) × distance (km).
    public static func estimateFuelUsedMetric(distanceKm: Double, lPer100km: Double) -> Double {
        guard lPer100km > 0 else { return 0 }
        return (lPer100km / 100.0) * distanceKm
    }
    
    /// Cost = fuel used (liters) × price per liter.
    public static func estimateCostMetric(fuelUsedLiters: Double, pricePerLiter: Double) -> Double {
        return fuelUsedLiters * pricePerLiter
    }
    
    /// CO₂ emissions in kg = fuel used (liters) × 2.31 kg CO₂ per liter (gasoline).
    public static func estimateCO2Metric(fuelUsedLiters: Double) -> Double {
        return fuelUsedLiters * 2.31
    }
    
    // MARK: - Session distance helpers
    
    /// Computes the total distance of a drive session in miles from its SpeedReadings.
    public static func totalDistanceMiles(from readings: [SpeedReading]) -> Double {
        guard readings.count > 1 else { return 0 }
        var total: Double = 0
        for i in 1..<readings.count {
            let prev = readings[i - 1]
            let curr = readings[i]
            let a = CLLocationCoordinate2D(latitude: prev.latitude, longitude: prev.longitude)
            let b = CLLocationCoordinate2D(latitude: curr.latitude, longitude: curr.longitude)
            let dist = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            total += dist
        }
        return total / 1609.344 // meters to miles
    }
    
    /// Computes the total distance of a drive session in km.
    public static func totalDistanceKm(from readings: [SpeedReading]) -> Double {
        return totalDistanceMiles(from: readings) * 1.60934
    }
}
