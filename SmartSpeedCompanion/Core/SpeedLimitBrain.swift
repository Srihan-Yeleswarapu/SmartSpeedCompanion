// Path: Core/SpeedLimitBrain.swift
import Foundation
import CoreLocation
import SwiftData
import SwiftUI

@MainActor
public class SpeedLimitBrain: ObservableObject {
    public static let shared = SpeedLimitBrain()
    
    @Published public var currentLimit: Int = 25
    @Published public var limitSource: LimitSource = .estimating
    @Published public var showVerifyPrompt: Bool = false
    
    private let hereService = HEREService.shared
    private let osmService = OSMService.shared
    private let firebaseService = FirebaseSyncService.shared
    
    public var modelContext: ModelContext?
    
    private init() {}
    
    public func onLocationUpdate(_ location: CLLocation) async {
        guard location.horizontalAccuracy > 0, location.horizontalAccuracy < 50 else { return }
        
        let (latKey, lngKey) = RoadSegment.keys(for: location.coordinate)
        
        // STEP 1 - Local DB
        if let cached = await fetchLocal(latKey: latKey, lngKey: lngKey) {
            if cached.status == .temporary {
                if let expires = cached.expiresAt, Date() > expires {
                    // Expired, delete and continue
                    modelContext?.delete(cached)
                    try? modelContext?.save()
                } else {
                    currentLimit = cached.speedLimit
                    limitSource = .localTemporary
                    return
                }
            } else if cached.status == .verifiedPermanent {
                currentLimit = cached.speedLimit
                limitSource = .localVerified
                return
            }
        }
        
        // STEP 2 - Fetch from HERE API
        if let hereLimit = await hereService.fetchSpeedLimit(at: location.coordinate) {
            currentLimit = hereLimit
            limitSource = .localTemporary
            
            // STEP 3 - Background Verification
            Task.detached(priority: .background) {
                await self.verifyWithOSM(coordinate: location.coordinate, hereLimit: hereLimit, latKey: latKey, lngKey: lngKey)
            }
            return
        }
        
        // STEP 4 - ADOT / Firebase Fallback
        if let adotLimit = await firebaseService.fetchADOT(latKey: latKey, lngKey: lngKey) {
            currentLimit = adotLimit
            limitSource = .adot
            return
        }
        
        // STEP 5 - Estimate
        currentLimit = estimateLimit(for: location)
        limitSource = .estimating
    }
    
    private func verifyWithOSM(coordinate: CLLocationCoordinate2D, hereLimit: Int, latKey: Int, lngKey: Int) async {
        guard let osmResult = await osmService.fetchOSMData(at: coordinate) else {
            await saveLocal(latKey: latKey, lngKey: lngKey, limit: hereLimit, status: .temporary, source: "HERE_ONLY")
            return
        }
        
        // Attempt fuzzy match on road names if we can fetch HERE's name
        let hereName = await hereService.fetchRoadName(at: coordinate)
        let namesMatch = osmService.fuzzyMatchNames(osmResult.roadName, hereName)
        
        if namesMatch, hereLimit == osmResult.speedLimit {
            await saveLocal(latKey: latKey, lngKey: lngKey, limit: hereLimit, status: .verifiedPermanent, osmWayID: osmResult.wayID, source: "HERE+OSM")
            await firebaseService.pushVerifiedSegment(latKey: latKey, lngKey: lngKey, limit: hereLimit, osmWayID: osmResult.wayID)
            print("[Brain] ✓ Verified permanently: \(hereLimit)mph")
        } else {
            let expires = Date().addingTimeInterval(30 * 24 * 3600) // 30 days
            await saveLocal(latKey: latKey, lngKey: lngKey, limit: hereLimit, status: .temporary, source: "HERE_ONLY", expiresAt: expires)
            print("[Brain] ⚠ Disagreement HERE=\(hereLimit) OSM=\(osmResult.speedLimit ?? -1)")
        }
    }
    
    // MARK: - SwiftData Helpers
    
    private func fetchLocal(latKey: Int, lngKey: Int) async -> RoadSegment? {
        guard let ctx = modelContext else { return nil }
        let id = "\(latKey)_\(lngKey)"
        let descriptor = FetchDescriptor<RoadSegment>(predicate: #Predicate { $0.id == id })
        do {
            let matches = try ctx.fetch(descriptor)
            return matches.first
        } catch {
            return nil
        }
    }
    
    private func saveLocal(latKey: Int, lngKey: Int, limit: Int, status: SegmentStatus, osmWayID: String? = nil, source: String, expiresAt: Date? = nil) async {
        guard let ctx = modelContext else { return }
        
        if let existing = await fetchLocal(latKey: latKey, lngKey: lngKey) {
            existing.speedLimit = limit
            existing.statusString = status.rawValue
            existing.source = source
            existing.osmWayID = osmWayID
            existing.expiresAt = expiresAt
            existing.verifiedAt = Date()
        } else {
            let segment = RoadSegment(latKey: latKey, lngKey: lngKey, speedLimit: limit, status: status, osmWayID: osmWayID, source: source, expiresAt: expiresAt)
            ctx.insert(segment)
        }
        try? ctx.save()
    }
    
    private func estimateLimit(for location: CLLocation) -> Int {
        // Convert m/s to mph:
        let mph = location.speed * 2.23694
        if mph > 55 { return 65 }
        if mph > 35 { return 45 }
        if mph > 25 { return 35 }
        return 25
    }
}
