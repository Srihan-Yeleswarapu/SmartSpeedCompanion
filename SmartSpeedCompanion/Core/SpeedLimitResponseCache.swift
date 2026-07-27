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
    /// same 50m cell properly invalidates the cache (the West Frye → 07 PECOS
    /// case: both cells cover the same lat/lon, but different roadName means
    /// a different speed limit and the cache MUST miss).
    public func gridKey(for coordinate: CLLocationCoordinate2D, roadName: String? = nil) -> String {
        let latKey = (coordinate.latitude / gridPrecision).rounded() * gridPrecision
        let lonKey = (coordinate.longitude / gridPrecision).rounded() * gridPrecision
        let nameHash = roadName?.hashValue ?? 0
        return String(format: "g:%.4f,%.4f_%d", latKey, lonKey, nameHash)
    }

    /// Look up a cached entry. Returns nil if missing, expired, or recorded coord is
    /// > 50m from the requested coord (Phase 2 dedupe tightening, was 80m).
    /// On hit, touches `entry.cachedAt` to `Date()` so the eviction policy retains
    /// recently-looked-up entries. This is an O(1) dictionary lookup plus a cache
    /// bump — much faster than the old O(n) `lruOrder.firstIndex(of:)` scan.
    public func lookup(at coordinate: CLLocationCoordinate2D, roadName: String? = nil) -> SpeedLimitResponse? {
        let key = gridKey(for: coordinate, roadName: roadName)
        guard var entry = memory[key], isFresh(entry), entry.roadName == roadName else { return nil }
        let recordedLoc = CLLocation(latitude: entry.lat, longitude: entry.lon)
        let queriedLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        // Phase 2 -- tighten from 80m to 50m so adjacent grid cells with mildly
        // different speeds don't flicker the answer under typical driving.
        if recordedLoc.distance(from: queriedLoc) > 50 { return nil }

        // Touch cachedAt to mark as recently used (no O(n) LRU list to update).
        entry.cachedAt = Date()
        memory[key] = entry
        return entry.response
    }

    /// Persist a response. Updates in-memory cache + writes the whole memory table to disk.
    /// Disk write is debounced: we collapse rapid stores via an async task.
    /// Eviction uses a timestamp scan (O(n) on evict only) instead of the old
    /// O(n) LRU list on EVERY lookup/store.
    public func store(_ response: SpeedLimitResponse, at coordinate: CLLocationCoordinate2D, roadName: String? = nil) async {
        let key = gridKey(for: coordinate, roadName: roadName)
        let entry = Entry(
            response: response,
            gridKey: key,
            lat: coordinate.latitude,
            lon: coordinate.longitude,
            cachedAt: Date(),
            roadName: roadName
        )
        memory[key] = entry

        // Evict oldest entries when over capacity.
        // O(n) scan of ~500 entries, but only runs when cache exceeds limit
        // (~once per 500 stores, or ~every 8 minutes of driving).
        if memory.count > maxMemoryEntries {
            // Find the oldest entry by cachedAt and remove it.
            // `min(by:)` is O(n) but we only call it when over capacity.
            if let oldestKey = memory.min(by: { $0.value.cachedAt < $1.value.cachedAt })?.key {
                memory.removeValue(forKey: oldestKey)
            }
        }

        await persistToDisk()
    }

    /// Drop everything in memory + on disk. Used by SmartSpeedLimitService after 20
    /// consecutive misses.
    public func clear() async {
        memory.removeAll()
        try? FileManager.default.removeItem(at: diskURL)
    }

    /// Load persisted entries from disk (called once on startup by SmartSpeedLimitService.init).
    public func loadFromDisk() async {
        guard let data = try? Data(contentsOf: diskURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entries = try? decoder.decode([Entry].self, from: data) else { return }
        let cutoff = Date().addingTimeInterval(-diskTtl)
        for entry in entries where entry.cachedAt > cutoff {
            memory[entry.gridKey] = entry
        }
        DebugLogger.shared.log("SpeedLimitResponseCache: loaded \(entries.count) entries from disk")
    }

    // MARK: - Private

    private func isFresh(_ entry: Entry) -> Bool {
        Date().timeIntervalSince(entry.cachedAt) < memoryTtl
    }

    private func persistToDisk() async {
        let snapshot = Array(memory.values)
        let url = self.diskURL
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Hop off the actor so the disk write can't deadlock any awaits on `shared`.
        await Task.detached(priority: .utility) {
            do {
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: [.atomic])
            } catch {
                DebugLogger.shared.log("SpeedLimitResponseCache: disk write failed: \(error)")
            }
        }.value
    }
}
