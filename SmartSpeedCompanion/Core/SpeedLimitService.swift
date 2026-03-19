// SpeedLimitService.swift
import Foundation
import CoreLocation
import Combine

public protocol SpeedLimitProviding {
    func fetchSpeedLimit(at coordinate: CLLocationCoordinate2D) async throws -> Int
}

@MainActor
public class SmartSpeedLimitService: ObservableObject {
    public static let shared = SmartSpeedLimitService()
    
    @Published public var currentLimit: Int = 0
    @Published public var dataSource: String = "No Data"
    
    private var lastValidLimit: Int = 0
    private var consecutiveMissCount: Int = 0
    // After 20 consecutive misses, auto-clear the spatial cache so stale
    // bounding boxes can't pin us to the wrong road.
    private let missThresholdBeforeClear: Int = 20
    
    private init() {}
    
    public func updateSpeedLimit(at coordinate: CLLocationCoordinate2D, heading: Double?, currentSpeedMph: Double) async -> Int {
        do {
            // Updated to pass heading: filters out cross-streets and prevents accidental snapping
            let localLimit = try await ArizonaSpeedLimitService.shared.updateSpeedLimit(at: coordinate, heading: heading, currentSpeedMph: currentSpeedMph)
            
            self.lastValidLimit = localLimit
            self.currentLimit = localLimit
            self.consecutiveMissCount = 0
            self.dataSource = "DB"
            return localLimit
            
        } catch {
            consecutiveMissCount += 1
            
            // Recovery search also uses heading
            if let recoveryLimit = try? await ArizonaSpeedLimitService.shared.updateSpeedLimit(at: coordinate, heading: heading, currentSpeedMph: currentSpeedMph, expandedSearch: true) {
                self.lastValidLimit = recoveryLimit
                self.currentLimit = recoveryLimit
                self.consecutiveMissCount = 0
                self.dataSource = "DB (Recovered)"
                return recoveryLimit
            }
            
            if consecutiveMissCount < missThresholdBeforeClear && lastValidLimit > 0 {
                self.currentLimit = lastValidLimit
                return lastValidLimit
            } else if consecutiveMissCount >= missThresholdBeforeClear {
                // Bust the spatial cache so we get fresh data on the next update.
                // This auto-fixes the "stuck speed limit" issue without a manual trigger.
                await ArizonaSpeedLimitService.shared.clearCache()
                self.lastValidLimit = 0
                self.currentLimit = 0
                self.dataSource = "No Data"
                self.consecutiveMissCount = 0
            }
            
            return self.currentLimit
        }
    }
}