// HERELocalBatchCache.swift
// SQLite-backed cache for road segment speed limits returned by the HERE Route
// Matching API batch requests.
//
// SCHEMA
// ──────
//   cached_roads (
//     id          INTEGER PRIMARY KEY AUTOINCREMENT,
//     road_name   TEXT NOT NULL,
//     direction   TEXT NOT NULL DEFAULT '',
//     speed_limit INTEGER NOT NULL,
//     lat         REAL NOT NULL,
//     lon         REAL NOT NULL,
//     source      TEXT NOT NULL DEFAULT 'here',
//     cached_at   TEXT NOT NULL DEFAULT (datetime('now')),
//     pinned      INTEGER NOT NULL DEFAULT 0   -- 1 = never expires (Downloaded Limits)
//   )
//
// Indexes on (road_name, direction) for fast name-first lookups and on (lat, lon)
// for spatial nearest-neighbor queries.
//
// LOOKUP PATHS (in priority order)
// ─────────────────────────────────
//   1. By road name + direction — the fastest path. Requires the caller (typically
//      SpeedLimitService) to know the road name from reverse geocode.
//   2. By nearest spatial coordinate — fallback when no road name is available.
//      Finds the closest cached point within 50m of the user's GPS coordinate.
//
// WHY SQLITE INSTEAD OF JSON GRID
// ────────────────────────────────
// - No grid-key collisions: two roads at the same coordinate are separate rows.
// - Direction-aware: northbound vs southbound speed limits are distinct entries.
// - Scalable: indexed queries for millions of rows, not limited to 5000 LRU.
// - Name-first lookups: O(log n) instead of scanning a hash map.
// - ACID: safe concurrent writes, crash-safe with WAL mode.

import Foundation
import CoreLocation
import SQLite3

/// A cached road segment with its speed limit, direction, and location.
public struct CachedRoad: Sendable, Equatable {
    public let roadName: String
    public let direction: String     // "N", "S", "E", "W", or "" for undirected
    public let speedLimitMph: Int
    public let latitude: Double
    public let longitude: Double
    public let source: String        // "here"
    /// When true, this row is exempt from the 30-day TTL cleanup (Downloaded
    /// Limits zones that the user pinned to "keep forever").
    public let pinned: Bool

    public init(roadName: String, direction: String = "", speedLimitMph: Int, latitude: Double, longitude: Double, source: String = "here", pinned: Bool = false) {
        self.roadName = roadName
        self.direction = direction
        self.speedLimitMph = speedLimitMph
        self.latitude = latitude
        self.longitude = longitude
        self.source = source
        self.pinned = pinned
    }
}

/// SQLite-backed cache for HERE Route Matching batch results.
///
/// Thread safety: SQLite in WAL mode handles concurrent reads safely.
/// Writes are serialized via the serial dispatch queue.
public final class HERELocalBatchCache: @unchecked Sendable {
    public static let shared = HERELocalBatchCache()

    private var db: OpaquePointer?
    /// Disabled for this process if a legacy-cache migration cannot prove that
    /// malformed rows were removed. Returning no batch data is safer than
    /// serving a stale road/limit answer.
    private var cacheDisabled = false
    /// Non-blocking readiness latch. Written `true` by
    /// `performOpenAndMigration()` on the `queue` thread once the SQLite open
    /// + migration has finished, and never reset. Read on any thread WITHOUT
    /// `queue.sync` deliberately: a stale `false` read only makes an early
    /// caller treat the cache as not-yet-open (return nil / 0) instead of
    /// blocking the calling thread while the open block (which may run a
    /// one-time VACUUM on the legacy-migration path) is still in flight —
    /// exactly the first-use stall this launch fix eliminates. Once visible as
    /// `true` the open work has completed, so the `queue.sync` bodies that
    /// follow are fast.
    private var isOpen = false
    private let dbURL: URL
    private let queue = DispatchQueue(label: "com.speedsense.hereBatchCache", qos: .utility)
    /// Bump whenever the persisted row interpretation changes. Version 2
    /// invalidates rows written by the old GeoJSON parser, which swapped HERE's
    /// `[longitude, latitude]` positions and could associate a valid road name
    /// with an unusable or misleading coordinate.

    /// 30-day TTL for cached entries.
    private let ttlDays: Int = 30

    // MARK: - Initialization

    private init() {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.dbURL = cachesDir.appendingPathComponent("hereBatchCache.sqlite")
        // ═══ LAUNCH-HANG FIX (2026-08-02 UIKit-runloop reports) ═════════════
        // SQLite open, schema creation, and the legacy-cache migration
        // (including a VACUUM) previously ran synchronously inside this
        // initializer. `HERELocalBatchCache.shared` is first touched from
        // `SmartSpeedLimitService` during `DriveViewModel` construction at
        // app launch, so that disk + VACUUM work blocked the main thread for
        // hundreds of ms — the three back-to-back launch hangs seen in
        // TestFlight build 549.
        //
        // All of it now runs on the serial cache queue. Every public method
        // serializes through the same queue, so a lookup/store issued before
        // the DB is open simply executes AFTER the open block completes —
        // callers never observe a half-initialized store.
        queue.async { [weak self] in
            self?.performOpenAndMigration()
        }
    }

    /// Thread-safe read of `cacheDisabled`. The flag is now written on the
    /// `queue` thread (by `performOpenAndMigration`), so callers on the main
    /// thread must not read the raw `Bool` directly (a cross-thread
    /// read/write data race under Swift 6 strict concurrency). Every read
    /// goes through the serial queue — cheap, and the flag is only ever
    /// mutated during the one-time open/migration block.
    private var isCacheDisabled: Bool {
        queue.sync { cacheDisabled }
    }

    /// Non-blocking readiness gate used at the top of every public method.
    /// The `isOpen` latch is read directly (no `queue.sync`) so callers
    /// issued before the async open completes return nil/0 immediately
    /// instead of blocking; once open, the serialized `isCacheDisabled`
    /// check below it is a fast queue round-trip.
    private var isReady: Bool {
        guard isOpen else { return false }
        return !isCacheDisabled
    }

    /// Open the SQLite store and run the legacy-cache migration. Runs once on
    /// the serial `queue` (never on the main thread), so app launch never
    /// blocks on disk I/O or `VACUUM`.
    private func performOpenAndMigration() {
        let migrationCompleted = resetPersistedStoreIfNeeded()
        openOrCreateDB()
        if !migrationCompleted {
            // If a locked file prevented deletion, clear its rows after the
            // connection opens. Do not mark the migration complete until the
            // malformed legacy data has actually been removed.
            guard db != nil else {
                cacheDisabled = true
                DebugLogger.shared.log("HERELocalBatchCache: disabling cache after failed legacy-data migration")
                isOpen = true
                return
            }
            let cleared = exec("DELETE FROM cached_roads") && exec("VACUUM")
            if cleared {
                UserDefaults.standard.set(2, forKey: "hereBatchCacheSchemaVersion")
            } else {
                cacheDisabled = true
                DebugLogger.shared.log("HERELocalBatchCache: disabling cache after failed legacy-data migration")
            }
        }
        // Mark the one-time open phase complete (also on the disabled path so
        // the latch semantics stay "the open phase has run"; `isReady` still
        // gates on `!isCacheDisabled`).
        isOpen = true
    }

    deinit {
        if let db = db {
            sqlite3_close_v2(db)
        }
    }

    @discardableResult
    private func resetPersistedStoreIfNeeded() -> Bool {
        let schemaKey = "hereBatchCacheSchemaVersion"
        let currentVersion = 2
        guard UserDefaults.standard.integer(forKey: schemaKey) != currentVersion else { return true }

        // The old cache may contain rows created with the incorrect HERE
        // GeoJSON coordinate order. Do not let those rows survive an app
        // upgrade and continue producing wrong road/limit answers.
        var removed = true
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let url = URL(fileURLWithPath: dbURL.path + suffix)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                removed = false
                DebugLogger.shared.log("HERELocalBatchCache: schema migration could not remove \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if removed {
            UserDefaults.standard.set(currentVersion, forKey: schemaKey)
        }
        return removed
    }

    private func openOrCreateDB() {
        let path = dbURL.path
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, db != nil else {
            DebugLogger.shared.log("HERELocalBatchCache: failed to open DB at \(path)")
            // Mark the cache disabled so `isReady` short-circuits every
            // lookup instead of paying a queue.sync round-trip per call
            // that then no-ops on `db == nil` (code-review hardening).
            cacheDisabled = true
            return
        }

        // Enable WAL mode for concurrent reads
        exec("PRAGMA journal_mode=WAL")
        // Performance pragmas
        exec("PRAGMA synchronous=NORMAL")
        exec("PRAGMA cache_size=-4000") // ~4MB cache

        createTables()
        DebugLogger.shared.log("HERELocalBatchCache: opened SQLite at \(dbURL.lastPathComponent)")
    }

    private func createTables() {
        exec("""
            CREATE TABLE IF NOT EXISTS cached_roads (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                road_name   TEXT NOT NULL,
                direction   TEXT NOT NULL DEFAULT '',
                speed_limit INTEGER NOT NULL,
                lat         REAL NOT NULL,
                lon         REAL NOT NULL,
                source      TEXT NOT NULL DEFAULT 'here',
                cached_at   TEXT NOT NULL DEFAULT (datetime('now')),
                pinned      INTEGER NOT NULL DEFAULT 0
            )
        """)
        // Migrate pre-`pinned` databases (schema version 2) in place: add the
        // column if it is missing. This preserves HERE batch rows the user
        // already cached instead of wiping the store like the old version-3
        // reset would have done.
        if !columnExists("pinned") {
            exec("ALTER TABLE cached_roads ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0")
        }
        exec("CREATE INDEX IF NOT EXISTS idx_roads_name_dir ON cached_roads(road_name, direction)")
        // Composite spatial index: SQLite can only use one index per table,
        // so separate (lat) + (lon) indexes meant the spatial query in
        // lookupNearest always did a partial scan on one dimension. A
        // composite (lat, lon) index lets the BETWEEN filter on both axes
        // use a single index seek for O(log n) performance.
        exec("CREATE INDEX IF NOT EXISTS idx_roads_lat_lon ON cached_roads(lat, lon)")
        // Keep a separate lon-first index as a query-plan alternative for
        // edge cases where the lon range is tighter than the lat range.
        exec("CREATE INDEX IF NOT EXISTS idx_roads_lon_lat ON cached_roads(lon, lat)")
        // Unique constraint: same road at the same coordinate = one row.
        // Across batch fetches, re-fetching an area REPLACES the old row
        // (updating cached_at) rather than inserting a duplicate.
        exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_roads_unique ON cached_roads(road_name, direction, lat, lon)")
        // Clean up expired entries on startup. Pinned rows (Downloaded Limits
        // zones the user chose to "keep forever") are exempt from the 30-day
        // TTL; unpinned rows follow the default cleanup.
        exec("DELETE FROM cached_roads WHERE cached_at < datetime('now', '-\(ttlDays) days') AND pinned = 0")
    }

    /// True when the `cached_roads` table already has the given column.
    /// Used by the in-place `pinned` migration so an upgrade never wipes the
    /// user's existing HERE batch rows.
    private func columnExists(_ name: String) -> Bool {
        guard let db = db else { return false }
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(cached_roads)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let col = sqlite3_column_text(stmt, 1) {
                if String(cString: col) == name { return true }
            }
        }
        return false
    }

    // MARK: - Public API

    /// Look up speed limit for a known road name.
    /// This is the PRIMARY lookup path — O(log n), fastest and most accurate.
    ///
    /// - Parameters:
    ///   - roadName: The road name (e.g., "I-10", "Baseline Rd").
    ///   - bearing: User's bearing in degrees. If non-nil, filters by direction.
    /// - Returns: The closest matching cached road, or nil if not found.
    public func lookup(roadName: String, bearing: Double? = nil) -> CachedRoad? {
        guard isReady else { return nil }
        let dir = directionFromBearing(bearing)
        var result: CachedRoad?

        queue.sync {
            guard let db = self.db else { return }
            // Try exact direction match first, then any direction
            let sql: String
            if dir.isEmpty {
                sql = """
                    SELECT road_name, direction, speed_limit, lat, lon, source
                    FROM cached_roads
                    WHERE road_name = ?
                    ORDER BY cached_at DESC
                    LIMIT 1
                """
            } else {
                sql = """
                    SELECT road_name, direction, speed_limit, lat, lon, source
                    FROM cached_roads
                    WHERE road_name = ? AND (direction = ? OR direction = '')
                    ORDER BY CASE WHEN direction = ? THEN 0 ELSE 1 END, cached_at DESC
                    LIMIT 1
                """
            }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                DebugLogger.shared.log("HERELocalBatchCache: lookup prepare failed: \(errmsg)")
                return
            }
            sqlite3_bind_text(stmt, 1, (roadName as NSString).utf8String, -1, nil)
            if !dir.isEmpty {
                sqlite3_bind_text(stmt, 2, (dir as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (dir as NSString).utf8String, -1, nil)
            }

            if sqlite3_step(stmt) == SQLITE_ROW {
                result = readRow(stmt)
            }
            sqlite3_finalize(stmt)
        }

        return result
    }

    /// Look up the nearest cached road segment to a coordinate (spatial fallback).
    ///
    /// - Parameters:
    ///   - coordinate: The user's GPS coordinate.
    ///   - radiusMeters: Search radius in meters. Default 50m.
    /// - Returns: The nearest cached road within the radius, or nil.
    public func lookupNearest(to coordinate: CLLocationCoordinate2D, radiusMeters: Double = 50) -> CachedRoad? {
        guard isReady else { return nil }
        var result: CachedRoad?

        queue.sync {
            guard let db = self.db else { return }

            // Convert radius to approximate lat/lon degrees
            let latDegree = radiusMeters / 111_111.0
            let lonDegree = radiusMeters / (111_111.0 * cos(coordinate.latitude * .pi / 180))

            let minLat = coordinate.latitude - latDegree
            let maxLat = coordinate.latitude + latDegree
            let minLon = coordinate.longitude - lonDegree
            let maxLon = coordinate.longitude + lonDegree

            // Use the bbox to filter rows, then find the closest within the bbox.
            // The squared-distance ordering is fast with the (lat, lon) indexes.
            let sql = """
                SELECT road_name, direction, speed_limit, lat, lon, source,
                       ((lat - ?) * (lat - ?) + (lon - ?) * (lon - ?) * ?) AS dist2
                FROM cached_roads
                WHERE lat BETWEEN ? AND ?
                  AND lon BETWEEN ? AND ?
                  AND (lat - ?) * (lat - ?) + (lon - ?) * (lon - ?) * ? <= ?
                ORDER BY dist2 ASC
                LIMIT 1
            """

            let lonCos = cos(coordinate.latitude * .pi / 180)
            let maxDist2 = latDegree * latDegree // squared degrees at lat scale
            let bearingScale = lonCos * lonCos

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            // Bind: source lat, source lon, lon scale, bbox, and distance check
            sqlite3_bind_double(stmt, 1, coordinate.latitude)
            sqlite3_bind_double(stmt, 2, coordinate.latitude)
            sqlite3_bind_double(stmt, 3, coordinate.longitude)
            sqlite3_bind_double(stmt, 4, bearingScale)
            sqlite3_bind_double(stmt, 5, minLat)
            sqlite3_bind_double(stmt, 6, maxLat)
            sqlite3_bind_double(stmt, 7, minLon)
            sqlite3_bind_double(stmt, 8, maxLon)
            sqlite3_bind_double(stmt, 9, coordinate.latitude)
            sqlite3_bind_double(stmt, 10, coordinate.latitude)
            sqlite3_bind_double(stmt, 11, coordinate.longitude)
            sqlite3_bind_double(stmt, 12, bearingScale)
            sqlite3_bind_double(stmt, 13, maxDist2)

            if sqlite3_step(stmt) == SQLITE_ROW {
                result = readRow(stmt)
            }
            sqlite3_finalize(stmt)
        }

        return result
    }

    /// Combined lookup: try road name first, fall back to spatial nearest-neighbor.
    ///
    /// This is the main API used by SpeedLimitService.
    /// - If `roadName` is non-nil and non-empty, name-first lookup runs.
    /// - If name-first misses (or no name available), spatial fallback runs.
    /// - When a road name IS available and the spatial fallback finds a match,
    ///   the result's road name is validated against the geocoded name via
    ///   `RoadNameMatcher.score()` to prevent returning data from a nearby
    ///   but completely different road.
    /// - Returns the best match, or nil if nothing is cached nearby.
    public func lookup(coordinate: CLLocationCoordinate2D, roadName: String?, bearing: Double?) -> CachedRoad? {
        guard isReady else { return nil }
        // Primary path: name-first. A road name can span many miles, so the
        // name-only result still needs a coordinate-distance check. This also
        // rejects legacy rows written by the old HERE GeoJSON parser, which
        // treated [longitude, latitude] as [latitude, longitude].
        if let name = roadName, !name.isEmpty,
           let cached = lookup(roadName: name, bearing: bearing) {
            let cachedLocation = CLLocation(latitude: cached.latitude, longitude: cached.longitude)
            let requestedLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if cachedLocation.distance(from: requestedLocation) <= 75 {
                return cached
            }
            DebugLogger.shared.log("HERELocalBatchCache: rejected distant name match '\(cached.roadName)' (\(Int(cachedLocation.distance(from: requestedLocation)))m)")
        }

        // Secondary path: spatial fallback
        if let spatial = lookupNearest(to: coordinate, radiusMeters: 50) {
            // When a road name was provided by the geocoder, validate the
            // spatial result's road name actually matches the geocoded name.
            // A nearby cached point from a completely different road would
            // be wrong to return (e.g. neighborhood road vs adjacent arterial).
            if let name = roadName, !name.isEmpty {
                let matchScore = RoadNameMatcher.score(
                    geocodedName: name,
                    sqliteRouteId: spatial.roadName
                )
                guard matchScore >= 0.5 else { return nil }
            }
            return spatial
        }

        return nil
    }

    /// Store multiple road segments from a batch API response.
    /// Each row occupies ~80 bytes; 5000 rows ≈ 400KB (trivially small).
    /// Rows written with `pinned: true` are exempt from the 30-day TTL cleanup.
    public func store(roads: [CachedRoad], pinned: Bool = false) {
        guard isReady, !roads.isEmpty else { return }

        queue.sync {
            guard let db = self.db else { return }

            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

            let sql = """
                INSERT OR REPLACE INTO cached_roads
                    (road_name, direction, speed_limit, lat, lon, source, pinned)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                DebugLogger.shared.log("HERELocalBatchCache: store prepare failed: \(errmsg)")
                return
            }

            for road in roads {
                sqlite3_bind_text(stmt, 1, (road.roadName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (road.direction as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 3, Int32(road.speedLimitMph))
                sqlite3_bind_double(stmt, 4, road.latitude)
                sqlite3_bind_double(stmt, 5, road.longitude)
                sqlite3_bind_text(stmt, 6, (road.source as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 7, road.pinned ? 1 : 0)

                if sqlite3_step(stmt) != SQLITE_DONE {
                    DebugLogger.shared.log("HERELocalBatchCache: insert failed: \(errmsg)")
                }
                sqlite3_reset(stmt)
            }

            sqlite3_finalize(stmt)
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        }
    }

    /// Check whether any cached road data exists within radius of a coordinate.
    public func isAreaCached(coordinate: CLLocationCoordinate2D, radiusMeters: Double = 100) -> Bool {
        guard isReady else { return false }
        return lookupNearest(to: coordinate, radiusMeters: radiusMeters) != nil
    }

    /// Estimate coverage as a fraction (0.0–1.0) by checking 4 concentric
    /// radii around the coordinate.
    public func estimatedCoverage(at coordinate: CLLocationCoordinate2D, radiusMeters: Double = 1500) -> Double {
        guard isReady else { return 0 }
        let checkRadiuses: [Double] = [50, 100, 200, 500]
        var hits = 0
        for r in checkRadiuses {
            if isAreaCached(coordinate: coordinate, radiusMeters: r) {
                hits += 1
            }
        }
        return Double(hits) / Double(checkRadiuses.count)
    }

    /// Total number of cached road entries.
    public var count: Int {
        guard isReady else { return 0 }
        var result = 0
        queue.sync {
            guard let db = self.db else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM cached_roads", -1, &stmt, nil) == SQLITE_OK else { return }
            if sqlite3_step(stmt) == SQLITE_ROW {
                result = Int(sqlite3_column_int(stmt, 0))
            }
            sqlite3_finalize(stmt)
        }
        return result
    }

    /// Number of cached road rows inside a circular zone (used for the
    /// Downloaded Limits size readout and delete confirmation).
    public func countInZone(center: CLLocationCoordinate2D, radiusMeters: Double) -> Int {
        guard isReady else { return 0 }
        var result = 0
        queue.sync {
            guard let db = self.db else { return }
            let latDegree = radiusMeters / 111_111.0
            let lonCos = cos(center.latitude * .pi / 180)
            let lonDegree = radiusMeters / (111_111.0 * max(0.000001, lonCos))
            let minLat = center.latitude - latDegree
            let maxLat = center.latitude + latDegree
            let minLon = center.longitude - lonDegree
            let maxLon = center.longitude + lonDegree
            let bearingScale = lonCos * lonCos
            let maxDist2 = latDegree * latDegree
            let sql = """
                SELECT COUNT(*) FROM cached_roads
                WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?
                  AND (lat - ?) * (lat - ?) + (lon - ?) * (lon - ?) * ? <= ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_double(stmt, 1, minLat)
            sqlite3_bind_double(stmt, 2, maxLat)
            sqlite3_bind_double(stmt, 3, minLon)
            sqlite3_bind_double(stmt, 4, maxLon)
            sqlite3_bind_double(stmt, 5, center.latitude)
            sqlite3_bind_double(stmt, 6, center.latitude)
            sqlite3_bind_double(stmt, 7, center.longitude)
            sqlite3_bind_double(stmt, 8, bearingScale)
            sqlite3_bind_double(stmt, 9, maxDist2)
            if sqlite3_step(stmt) == SQLITE_ROW {
                result = Int(sqlite3_column_int(stmt, 0))
            }
            sqlite3_finalize(stmt)
        }
        return result
    }

    /// Delete every cached row inside a circular zone. Used when the user
    /// deletes a Downloaded Limits zone from the Offline list.
    public func deleteZone(center: CLLocationCoordinate2D, radiusMeters: Double) {
        guard isReady else { return }
        queue.sync {
            guard let db = self.db else { return }
            let latDegree = radiusMeters / 111_111.0
            let lonCos = cos(center.latitude * .pi / 180)
            let lonDegree = radiusMeters / (111_111.0 * max(0.000001, lonCos))
            let minLat = center.latitude - latDegree
            let maxLat = center.latitude + latDegree
            let minLon = center.longitude - lonDegree
            let maxLon = center.longitude + lonDegree
            let bearingScale = lonCos * lonCos
            let maxDist2 = latDegree * latDegree
            let sql = """
                DELETE FROM cached_roads
                WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?
                  AND (lat - ?) * (lat - ?) + (lon - ?) * (lon - ?) * ? <= ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_double(stmt, 1, minLat)
            sqlite3_bind_double(stmt, 2, maxLat)
            sqlite3_bind_double(stmt, 3, minLon)
            sqlite3_bind_double(stmt, 4, maxLon)
            sqlite3_bind_double(stmt, 5, center.latitude)
            sqlite3_bind_double(stmt, 6, center.latitude)
            sqlite3_bind_double(stmt, 7, center.longitude)
            sqlite3_bind_double(stmt, 8, bearingScale)
            sqlite3_bind_double(stmt, 9, maxDist2)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        DebugLogger.shared.log("HERELocalBatchCache: deleted zone (r=\(Int(radiusMeters))m)")
    }

    /// Set the `pinned` flag on every row inside a zone (Downloaded Limits
    /// pin / unpin toggle in the Offline list). Pinned rows survive the
    /// 30-day TTL cleanup.
    public func setPinned(_ pinned: Bool, center: CLLocationCoordinate2D, radiusMeters: Double) {
        guard isReady else { return }
        queue.sync {
            guard let db = self.db else { return }
            let latDegree = radiusMeters / 111_111.0
            let lonCos = cos(center.latitude * .pi / 180)
            let lonDegree = radiusMeters / (111_111.0 * max(0.000001, lonCos))
            let minLat = center.latitude - latDegree
            let maxLat = center.latitude + latDegree
            let minLon = center.longitude - lonDegree
            let maxLon = center.longitude + lonDegree
            let bearingScale = lonCos * lonCos
            let maxDist2 = latDegree * latDegree
            let sql = """
                UPDATE cached_roads SET pinned = ?
                WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?
                  AND (lat - ?) * (lat - ?) + (lon - ?) * (lon - ?) * ? <= ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int(stmt, 1, pinned ? 1 : 0)
            sqlite3_bind_double(stmt, 2, minLat)
            sqlite3_bind_double(stmt, 3, maxLat)
            sqlite3_bind_double(stmt, 4, minLon)
            sqlite3_bind_double(stmt, 5, maxLon)
            sqlite3_bind_double(stmt, 6, center.latitude)
            sqlite3_bind_double(stmt, 7, center.latitude)
            sqlite3_bind_double(stmt, 8, center.longitude)
            sqlite3_bind_double(stmt, 9, bearingScale)
            sqlite3_bind_double(stmt, 10, maxDist2)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    /// Remove the cached road answer nearest to a manual refresh location.
    /// A road-name match is preferred; deletion is bounded to 150m so a
    /// refresh can never remove an unrelated distant segment.
    public func invalidate(at coordinate: CLLocationCoordinate2D, roadName: String?) {
        guard isReady else { return }
        queue.sync {
            guard let db = self.db else { return }
            let radiusMeters = 150.0
            let latRadius = radiusMeters / 111_111.0
            let maxDistanceSquared = latRadius * latRadius
            let lonScale = cos(coordinate.latitude * .pi / 180)
            let distanceExpression = "((lat - ?) * (lat - ?) + (lon - ?) * (lon - ?) * ?) <= ?"
            let sql: String
            if let roadName, !roadName.isEmpty {
                sql = """
                    DELETE FROM cached_roads
                    WHERE rowid IN (
                        SELECT rowid FROM cached_roads
                        WHERE road_name = ? COLLATE NOCASE
                          AND \(distanceExpression)
                        ORDER BY \(distanceExpression)
                        LIMIT 1
                    )
                """
            } else {
                sql = """
                    DELETE FROM cached_roads
                    WHERE rowid IN (
                        SELECT rowid FROM cached_roads
                        WHERE \(distanceExpression)
                        ORDER BY \(distanceExpression)
                        LIMIT 1
                    )
                """
            }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

            func bindDistance(_ start: Int32) {
                sqlite3_bind_double(stmt, start, coordinate.latitude)
                sqlite3_bind_double(stmt, start + 1, coordinate.latitude)
                sqlite3_bind_double(stmt, start + 2, coordinate.longitude)
                sqlite3_bind_double(stmt, start + 3, coordinate.longitude)
                sqlite3_bind_double(stmt, start + 4, lonScale * lonScale)
                sqlite3_bind_double(stmt, start + 5, maxDistanceSquared)
            }

            var nextBinding: Int32 = 1
            if let roadName, !roadName.isEmpty {
                sqlite3_bind_text(stmt, nextBinding, (roadName as NSString).utf8String, -1, nil)
                nextBinding += 1
            }
            bindDistance(nextBinding)
            nextBinding += 6
            bindDistance(nextBinding)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        DebugLogger.shared.log("HERELocalBatchCache: invalidated nearby manual-refresh answer")
    }

    /// Remove all cached data.
    public func clear() {
        queue.sync {
            guard let db = self.db else { return }
            sqlite3_exec(db, "DELETE FROM cached_roads", nil, nil, nil)
            sqlite3_exec(db, "VACUUM", nil, nil, nil) // reclaim disk space
        }
        DebugLogger.shared.log("HERELocalBatchCache: cleared all entries")
    }

    // MARK: - Private Helpers

    /// Convert a bearing in degrees to a cardinal direction.
    /// Returns empty string for bearing = nil.
    private func directionFromBearing(_ bearing: Double?) -> String {
        guard let bearing = bearing else { return "" }
        let normalized = ((bearing.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
        if normalized < 45 || normalized >= 315 { return "N" }
        if normalized < 135 { return "E" }
        if normalized < 225 { return "S" }
        return "W"
    }

    /// Read a CachedRoad from the current row of a prepared statement.
    /// Assumes columns are: road_name(0), direction(1), speed_limit(2), lat(3), lon(4), source(5)
    private func readRow(_ stmt: OpaquePointer?) -> CachedRoad {
        let name = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        let dir = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        let limit = Int(sqlite3_column_int(stmt, 2))
        let lat = sqlite3_column_double(stmt, 3)
        let lon = sqlite3_column_double(stmt, 4)
        let source = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "here"
        return CachedRoad(
            roadName: name,
            direction: dir,
            speedLimitMph: limit,
            latitude: lat,
            longitude: lon,
            source: source
        )
    }

    /// Execute an SQL statement (no results).
    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db = db else { return false }
        var errMsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if result != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown error"
            DebugLogger.shared.log("HERELocalBatchCache SQL exec error: \(msg)")
            sqlite3_free(errMsg)
            return false
        }
        return true
    }

    private var errmsg: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "no db"
    }
}
