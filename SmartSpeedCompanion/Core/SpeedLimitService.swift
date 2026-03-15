// SpeedLimitService.swift
import Foundation
import CoreLocation
import Combine

struct TimeoutError: Error {}

public protocol SpeedLimitProviding {
    func fetchSpeedLimit(at coordinate: CLLocationCoordinate2D) async throws -> Int
}

// OpenStreetMap service removed per strict requirement to use database only.


@MainActor
public class SmartSpeedLimitService: ObservableObject {
    public static let shared = SmartSpeedLimitService()
    
    @Published public var currentLimit: Int = 0
    @Published public var dataSource: String = "No Data"
    
    private init() {}
    
    public func updateSpeedLimit(at coordinate: CLLocationCoordinate2D, currentSpeedMph: Double) async -> Int {
        do {
            let localLimit = try await ArizonaSpeedLimitService.shared.fetchSpeedLimit(at: coordinate)
            self.currentLimit = localLimit
            self.dataSource = "DB"
            return localLimit
        } catch {
            // Only set to 0 if it was genuinely not found, to avoid flashing --
            if self.currentLimit != 0 {
                self.currentLimit = 0
                self.dataSource = "No Data"
                DebugLogger.shared.log("LIMIT MISS at [\(coordinate.latitude), \(coordinate.longitude)]")
            }
            return 0
        }
    }
}
