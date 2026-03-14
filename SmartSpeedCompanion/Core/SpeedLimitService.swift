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
    
    @Published public var currentLimit: Int = 25
    @Published public var dataSource: String = "No Data"
    
    private init() {}
    
    public func updateSpeedLimit(at coordinate: CLLocationCoordinate2D, currentSpeedMph: Double) async -> Int {
        do {
            let localLimit = try await ArizonaSpeedLimitService.shared.fetchSpeedLimit(at: coordinate)
            self.currentLimit = localLimit
            self.dataSource = "Local Map"
            return localLimit
        } catch {
            self.currentLimit = 0
            self.dataSource = "Unknown"
            return 0
        }
    }
}
