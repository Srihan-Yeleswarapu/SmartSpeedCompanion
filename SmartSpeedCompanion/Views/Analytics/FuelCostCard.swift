import SwiftUI

/// Reusable card showing estimated fuel usage, cost, and CO₂ emissions for a trip.
/// Respects the user's measurement system and fuel settings.
public struct FuelCostCard: View {
    let distanceMiles: Double
    let distanceKm: Double
    let efficiencyMpg: Double      // MPG
    let efficiencyLPer100km: Double // L/100km
    let pricePerGallon: Double
    let pricePerLiter: Double
    let measurementSystem: String
    
    private var isMetric: Bool { measurementSystem == "Metric" }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "fuelpump.fill")
                    .font(.system(size: 14))
                    .foregroundColor(DesignSystem.cyan)
                Text("FUEL COST ESTIMATE")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundColor(DesignSystem.cyan)
            }
            
            if isMetric {
                metricContent
            } else {
                imperialContent
            }
            
            // Disclaimer
            Text("Based on your vehicle's efficiency setting in Settings")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.35))
                .padding(.top, 4)
        }
        .padding(16)
        .background(DesignSystem.bgCard)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(red: 0, green: 212/255, blue: 255/255, opacity: 0.12), lineWidth: 1))
    }
    
    @ViewBuilder
    private var imperialContent: some View {
        let fuelUsed = FuelEstimator.estimateFuelUsed(distanceMiles: distanceMiles, mpg: efficiencyMpg)
        let cost = FuelEstimator.estimateFuelCost(fuelUsedGallons: fuelUsed, pricePerGallon: pricePerGallon)
        let co2 = FuelEstimator.estimateCO2(fuelUsedGallons: fuelUsed)
        
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
            metricChip(title: "DISTANCE", value: String(format: "%.1f mi", distanceMiles), color: .white)
            metricChip(title: "FUEL USED", value: String(format: "%.2f gal", fuelUsed), color: DesignSystem.amber)
            metricChip(title: "EST. COST", value: String(format: "$%.2f", cost), color: DesignSystem.neonGreen)
            metricChip(title: "CO₂ EMITTED", value: String(format: "%.1f lbs", co2), color: .gray)
        }
    }
    
    @ViewBuilder
    private var metricContent: some View {
        let fuelUsed = FuelEstimator.estimateFuelUsedMetric(distanceKm: distanceKm, lPer100km: efficiencyLPer100km)
        let cost = FuelEstimator.estimateCostMetric(fuelUsedLiters: fuelUsed, pricePerLiter: pricePerLiter)
        let co2 = FuelEstimator.estimateCO2Metric(fuelUsedLiters: fuelUsed)
        
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
            metricChip(title: "DISTANCE", value: String(format: "%.1f km", distanceKm), color: .white)
            metricChip(title: "FUEL USED", value: String(format: "%.2f L", fuelUsed), color: DesignSystem.amber)
            metricChip(title: "EST. COST", value: String(format: "$%.2f", cost), color: DesignSystem.neonGreen)
            metricChip(title: "CO₂ EMITTED", value: String(format: "%.1f kg", co2), color: .gray)
        }
    }
    
    private func metricChip(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.gray)
            Text(value)
                .font(.system(size: 16, weight: .black, design: .rounded))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(DesignSystem.bgPanel)
        .cornerRadius(8)
    }
}
