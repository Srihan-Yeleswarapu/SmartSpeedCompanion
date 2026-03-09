// Path: Core/FirebaseSyncService.swift
import Foundation
import FirebaseDatabase
import CoreLocation
import SwiftData

@MainActor
public class FirebaseSyncService {
    public static let shared = FirebaseSyncService()
    private let db = Database.database().reference()
    
    private init() {}
    
    public func fetchADOT(latKey: Int, lngKey: Int) async -> Int? {
        let key = "\(latKey)_\(lngKey)"
        do {
            let snapshot = try await db.child("adot_segments").child(key).getData()
            if let dict = snapshot.value as? [String: Any],
               let limit = dict["limit"] as? Int {
                return limit
            }
        } catch {
            print("[Firebase] ADOT fetch error for \(key): \(error.localizedDescription)")
        }
        return nil
    }
    
    public func pushVerifiedSegment(latKey: Int, lngKey: Int, limit: Int, osmWayID: String, source: String = "HERE+OSM") async {
        let key = "\(latKey)_\(lngKey)"
        let data: [String: Any] = [
            "limit": limit,
            "osmWayID": osmWayID,
            "verifiedAt": Int(Date().timeIntervalSince1970),
            "source": source,
            "flagCount": 0,
            "verifiedCount": 1
        ]
        do {
            try await db.child("verified_segments").child(key).setValue(data)
        } catch {
            print("[Firebase] Push error: \(error.localizedDescription)")
        }
    }
    
    public func incrementVerifiedCount(latKey: Int, lngKey: Int) async {
        let key = "\(latKey)_\(lngKey)"
        let ref = db.child("verified_segments").child(key).child("verifiedCount")
        ref.runTransactionBlock({ (currentData) -> TransactionResult in
            var count = currentData.value as? Int ?? 0
            count += 1
            currentData.value = count
            return TransactionResult.success(withValue: currentData)
        })
    }
    
    public func incrementFlagCount(latKey: Int, lngKey: Int) async {
        let key = "\(latKey)_\(lngKey)"
        let ref = db.child("verified_segments").child(key).child("flagCount")
        ref.runTransactionBlock({ (currentData) -> TransactionResult in
            var count = currentData.value as? Int ?? 0
            count += 1
            currentData.value = count
            return TransactionResult.success(withValue: currentData)
        })
    }
    
    public func syncVerified(context: ModelContext, center: CLLocationCoordinate2D) async {
        // In a real app we'd use GeoFire to pull segments within 50km.
        // For this MVP, we will pull recent verified segments broadly and cache locally if not present.
        do {
            let snapshot = try await db.child("verified_segments")
                .queryOrdered(byChild: "verifiedAt")
                .queryLimited(toLast: 500)
                .getData()
            
            guard let dict = snapshot.value as? [String: [String: Any]] else { return }
            
            for (key, val) in dict {
                let parts = key.components(separatedBy: "_")
                guard parts.count == 2,
                      let latK = Int(parts[0]),
                      let lngK = Int(parts[1]),
                      let limit = val["limit"] as? Int else { continue }
                
                let source = val["source"] as? String ?? "Firebase"
                let osmWayID = val["osmWayID"] as? String
                let verifiedAtRaw = val["verifiedAt"] as? TimeInterval ?? Date().timeIntervalSince1970
                
                let segment = RoadSegment(
                    latKey: latK,
                    lngKey: lngK,
                    speedLimit: limit,
                    status: .verifiedPermanent,
                    osmWayID: osmWayID,
                    source: source,
                    verifiedAt: Date(timeIntervalSince1970: verifiedAtRaw)
                )
                
                // SwiftData simple upsert/insert logic:
                // Only insert if it doesn't already exist
                let descriptor = FetchDescriptor<RoadSegment>(predicate: #Predicate { $0.id == key })
                if let existing = try? context.fetch(descriptor), existing.isEmpty {
                    context.insert(segment)
                }
            }
            try? context.save()
        } catch {
            print("[Firebase] Sync error: \(error.localizedDescription)")
        }
    }
}
