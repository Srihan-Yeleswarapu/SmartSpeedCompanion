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
        try await ref.runTransactionBlock({ (currentData) -> TransactionResult in
            var count = currentData.value as? Int ?? 0
            count += 1
            currentData.value = count
            return TransactionResult.success(withValue: currentData)
        })
    }
    
    public func incrementFlagCount(latKey: Int, lngKey: Int) async {
        let key = "\(latKey)_\(lngKey)"
        let ref = db.child("verified_segments").child(key).child("flagCount")
        try await ref.runTransactionBlock({ (currentData) -> TransactionResult in
            var count = currentData.value as? Int ?? 0
            count += 1
            currentData.value = count
            return TransactionResult.success(withValue: currentData)
        })
    }
    
    public func syncVerified(context: ModelContext, center: CLLocationCoordinate2D) async {
        // Ensure this method is called on the Main Actor
        assert(Thread.isMainThread, "syncVerified must be called on the Main Actor")

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

                // Simplified predicate logic for iOS 17 compatibility
                let existingSegments = try? context.fetch(FetchDescriptor<RoadSegment>())
                if existingSegments?.contains(where: { $0.id == key }) == false {
                    context.insert(segment)
                }
            }
            try? context.save()
        } catch {
            print("[Firebase] Sync error: \(error.localizedDescription)")
        }
    }
}
