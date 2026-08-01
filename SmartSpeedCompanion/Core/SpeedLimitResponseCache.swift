// SpeedLimitResponseCache.swift
// Spatial-grid keyed cache for SpeedLimitResponse. Shared by SmartSpeedLimitService.
//
// IMPORTANT — the orchestrator MUST be able to answer cache lookups BEFORE a network
// roundtrip, otherwise the offline fallback can't serve fresh-enough data when the
// user is on a road we've already visited.
//
// Used to key by "\(provider)|\(roadKey)" but that would require a previous network
// response to know the roadKey — defeating the purpose when going offline.
// Instead the key is a spatial grid cell (~50m at 0.0005 degrees ≈ 55m at the equator).
// When the orchestrator re-asks with a coord in the same cell, the cached response
// is returned. The cell also stores the recorded coord so a 80m distance sanity check
// avoids stale cross-cell hits.
//
// Storage:
//   - In-memory: bounded Dictionary[gridKey -> Entry], LRU-evicted above 500 entries.
//   - On-disk: JSON array at /Library/Caches/speedLimitResponses.json, written atomically.
//   - TTL: 30 days for both memory and disk.

import Foundation
import CoreLocation

public actor SpeedLimitResponseCache {
    public static let shared = SpeedLimitResponseCache()

    // MARK: - Types

    private struct Entry: Codable, Sendable {
        let response: SpeedLimitResponse
        let gridKey: String
        let lat: Double
        let lon: Double
        /// Mutable so `lookup()` can touch it to mark recency without
        /// re-creating the entire struct.
        var cachedAt: Date
        let roadName: String?
    }

    // MARK: - State

    /// ~50m cells at the equator (~55m at mid-latitudes). Smaller = more cache fragmentation;
    /// larger = more stale cross-cell hits. 0.0005° ≈ 55m.
    private let gridPrecision: Double = 0.0005
    /// Max cached entries before eviction kicks in.
    /// Eviction scans all values (O(n), ~500 entries) which is a much cheaper
    /// tradeoff than the O(n) `firstIndex(of:)` on every single lookup/store
    /// that the old `lruOrder` array required.
    private let maxMemoryEntries: Int = 500

    private var memory: [String: Entry] = [:]
    /// Revisions are kept separately from the persisted entry format so older
    /// disk snapshots remain decodable.
    private var memoryRevisionByKey: [String: UInt64] = [:]
    /// Per-cell revisions prevent a slow prefetch/commit from overwriting a
    /// newer response for the same spatial cell without blocking independent
    /// cells. The global floor rejects stores that were already in flight when
    /// a clear began.
    private var latestStoreRevisionByKey: [String: UInt64] = [:]
    private var minimumAcceptedRevision: UInt64 = 0
    /// Prevents an asynchronous startup load from overwriting a live store or
    /// resurrecting entries after an explicit clear.
    private var didLoadFromDisk = false
    private let diskURL: URL

    /// Memory cache TTL: 30 minutes (Phase 2 polish). Long enough to absorb a typical
    /// 5-min re-query loop around a road; short enough that a recently-installed
    /// sign change is picked up after a single loop around the area. Was 30 days;
    /// that was too lax for in-driver scenarios that pulse coords every few seconds.
    private let memoryTtl: TimeInterval = 30 * 60
    /// Disk cache TTL: 30 days. A returning user on previously-visited roads gets
    /// an offline-fast hit even if their first query of the session is offline.
    private let diskTtl: TimeInterval = 30 * 86_400

    private init() {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.diskURL = cachesDir.appendingPathComponent("speedLimitResponses.json")
    }

    // MARK: - API

    /// Compute the spatial grid key for a coord (cheap; no network roundtrip).
    /// `roadName` is folded into the key hash so a cross-street snap within the
    /// same 50m cell properly invalidates the cache.
    public func gridKey(for coordinate: CLLocationCoordinate2D, roadName: String? = nil) -> String {
        guard isValidCoordinate(coordinate) else { return "invalid" }
        // `String.hashValue` is intentionally randomized per process. Integer
        // bucket coordinates and FNV-1a keep the key deterministic without
        // locale-sensitive formatting.
        let latBucket = Int64((coordinate.latitude / gridPrecision).rounded())
        let lonBucket = Int64((coordinate.longitude / gridPrecision).rounded())
        let nameHash = stableNameHash(roadName)
        return "g:\(latBucket),\(lonBucket)_\(nameHash)"
    }

    /// Look up a cached entry. Returns nil if missing, expired, or recorded coord is
    /// > 50m from the requested coord.
    public func lookup(at coordinate: CLLocationCoordinate2D, roadName: String? = nil) -> SpeedLimitResponse? {
        guard isValidCoordinate(coordinate) else { return nil }
        let canonicalName = canonicalRoadName(roadName)
        let key = gridKey(for: coordinate, roadName: canonicalName)
        guard var entry = memory[key], isFresh(entry), entry.roadName == canonicalName else { return nil }
        let recordedLoc = CLLocation(latitude: entry.lat, longitude: entry.lon)
        let queriedLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if recordedLoc.distance(from: queriedLoc) > 50 { return nil }

        // Touch cachedAt to mark as recently used.
        entry.cachedAt = Date()
        memory[key] = entry
        return entry.response
    }

    /// Persist a response. Revisions are optional for compatibility with existing callers.
    public func store(
        _ response: SpeedLimitResponse,
        at coordinate: CLLocationCoordinate2D,
        roadName: String? = nil,
        revision: UInt64? = nil
    ) async {
        // Initialization starts disk loading in a separate Task. Complete that
        // merge before accepting the first live store so an older snapshot
        // cannot overwrite a fresh response.
        if !didLoadFromDisk {
            await loadFromDisk()
        }
        guard isValidCoordinate(coordinate) else { return }

        let canonicalName = canonicalRoadName(roadName)
        let key = gridKey(for: coordinate, roadName: canonicalName)
        if let revision {
            guard revision > minimumAcceptedRevision,
                  revision > (latestStoreRevisionByKey[key] ?? 0) else { return }
            latestStoreRevisionByKey[key] = revision
        }
        memory[key] = Entry(
            response: response,
            gridKey: key,
            lat: coordinate.latitude,
            lon: coordinate.longitude,
            cachedAt: Date(),
            roadName: canonicalName
        )
        if let revision {
            memoryRevisionByKey[key] = revision
        } else {
            memoryRevisionByKey.removeValue(forKey: key)
        }

        if memory.count > maxMemoryEntries,
           let oldestKey = memory.min(by: { $0.value.cachedAt < $1.value.cachedAt })?.key {
            memory.removeValue(forKey: oldestKey)
            memoryRevisionByKey.removeValue(forKey: oldestKey)
        }
        persistToDisk()
    }

    /// Drop everything in memory + on disk. When a caller supplies the latest
    /// revision it has issued, stores already queued before this clear are
    /// rejected even if they have not reached this actor yet.
    public func clear(rejectingRevisionsThrough revision: UInt64? = nil) async {
        // A clear is an explicit lifecycle decision; a queued startup load must
        // not repopulate the cache after it completes.
        didLoadFromDisk = true
        if let revision {
            let keysToRemove = memory.keys.filter {
                (memoryRevisionByKey[$0] ?? 0) <= revision
            }
            for key in keysToRemove {
                memory.removeValue(forKey: key)
                memoryRevisionByKey.removeValue(forKey: key)
            }
            latestStoreRevisionByKey = latestStoreRevisionByKey.filter { $0.value > revision }
            minimumAcceptedRevision = max(minimumAcceptedRevision, revision)
            // Persist the preserved newer entries so a stale clear cannot
            // resurrect old disk data on the next launch.
            persistToDisk()
        } else {
            memory.removeAll()
            memoryRevisionByKey.removeAll()
            latestStoreRevisionByKey.removeAll()
            try? FileManager.default.removeItem(at: diskURL)
        }
    }

    /// Load persisted entries from disk (called once on startup).
    ///
    /// This method intentionally performs the small bounded disk read without
    /// an internal suspension point. Actor reentrancy would otherwise let a
    /// live `store()` run after `didLoadFromDisk` was set but before the disk
    /// merge completed, allowing the older snapshot to overwrite fresh data.
    public func loadFromDisk() async {
        guard !didLoadFromDisk else { return }
        didLoadFromDisk = true
        guard let data = try? Data(contentsOf: diskURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entries = try? decoder.decode([Entry].self, from: data) else { return }
        let cutoff = Date().addingTimeInterval(-diskTtl)

        for entry in entries where entry.cachedAt > cutoff {
            let coordinate = CLLocationCoordinate2D(latitude: entry.lat, longitude: entry.lon)
            guard isValidCoordinate(coordinate) else { continue }
            let canonicalName = canonicalRoadName(entry.roadName)
            let migrated = Entry(
                response: entry.response,
                gridKey: gridKey(for: coordinate, roadName: canonicalName),
                lat: entry.lat,
                lon: entry.lon,
                cachedAt: entry.cachedAt,
                roadName: canonicalName
            )
            // A live store can race startup loading; never replace newer memory.
            if let existing = memory[migrated.gridKey], existing.cachedAt >= migrated.cachedAt {
                continue
            }
            memory[migrated.gridKey] = migrated
            memoryRevisionByKey[migrated.gridKey] = 0
        }

        if memory.count > maxMemoryEntries {
            let newest = memory.values.sorted { $0.cachedAt > $1.cachedAt }.prefix(maxMemoryEntries)
            memory = Dictionary(uniqueKeysWithValues: newest.map { ($0.gridKey, $0) })
            memoryRevisionByKey = memoryRevisionByKey.filter { memory[$0.key] != nil }
        }
        DebugLogger.shared.log("SpeedLimitResponseCache: loaded \(entries.count) entries from disk")
    }

    // MARK: - Private

    private func isValidCoordinate(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude.isFinite && coordinate.longitude.isFinite &&
        (-90.0...90.0).contains(coordinate.latitude) &&
        (-180.0...180.0).contains(coordinate.longitude)
    }

    private func canonicalRoadName(_ roadName: String?) -> String? {
        guard let roadName else { return nil }
        let canonical = roadName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .uppercased()
        return canonical.isEmpty ? nil : canonical
    }

    private func stableNameHash(_ roadName: String?) -> UInt64 {
        guard let roadName = canonicalRoadName(roadName) else { return 0 }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in roadName.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private func isFresh(_ entry: Entry) -> Bool {
        Date().timeIntervalSince(entry.cachedAt) < memoryTtl
    }

    private func persistToDisk() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            // Keep writes serialized with actor mutations. Detached writes could
            // finish out of order and put an older snapshot back on disk.
            let data = try encoder.encode(Array(memory.values))
            try data.write(to: diskURL, options: [.atomic])
        } catch {
            DebugLogger.shared.log("SpeedLimitResponseCache: disk write failed: \(error)")
        }
    }
}
