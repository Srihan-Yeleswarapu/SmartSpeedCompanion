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
//     cached_at   TEXT NOT NULL DEFAULT (datetime('now'))
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

    public init(roadName: String, direction: String = "", speedLimitMph: Int, latitude: Double, longitude: Double, source: String = "here") {
        self.roadName = roadName
        self.direction = direction
        self.speedLimitMph = speedLimitMph
        self.latitude = latitude
        self.longitude = longitude
        self.source = source
    }
}

/// SQLite-backed cache for HERE Route Matching batch results.
///
/// Thread safety: SQLite in WAL mode handles concurrent reads safely.
/// Writes are serialized via the serial dispatch queue.
public final class HERELocalBatchCache: @unchecked Sendable {
    public static let shared = HERELocalBatchCache()

    private var db: OpaquePointer?
    private let dbURL: URL
    private let queue = DispatchQueue(label: "com.speedsense.hereBatchCache", qos: .utility)

    /// 30-day TTL for cached entries.
    private let ttlDays: Int = 30

    // MARK: - Initialization

    private init() {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.dbURL = cachesDir.appendingPathComponent("hereBatchCache.sqlite")
        openOrCreateDB()
    }

    deinit {
        if let db = db {
            sqlite3_close_v2(db)
        }
    }

    private func openOrCreateDB() {
        let path = dbURL.path
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, db != nil else {
            DebugLogger.shared.log("HERELocalBatchCache: failed to open DB at \(path)")
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
                cached_at   TEXT NOT NULL DEFAULT (datetime('now'))
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_roads_name_dir ON cached_roads(road_name, direction)")
        exec("CREATE INDEX IF NOT EXISTS idx_roads_lat ON cached_roads(lat)")
        exec("CREATE INDEX IF NOT EXISTS idx_roads_lon ON cached_roads(lon)")
        // Unique constraint: same road at the same coordinate = one row.
        // Across batch fetches, re-fetching an area REPLACES the old row
        // (updating cached_at) rather than inserting a duplicate.
        exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_roads_unique ON cached_roads(road_name, direction, lat, lon)")
        // Clean up expired entries on startup
        exec("DELETE FROM cached_roads WHERE cached_at < datetime('now', '-\(ttlDays) days')")
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
    /// - Returns the best match, or nil if nothing is cached nearby.
    public func lookup(coordinate: CLLocationCoordinate2D, roadName: String?, bearing: Double?) -> CachedRoad? {
        // Primary path: name-first
        if let name = roadName, !name.isEmpty {
            if let cached = lookup(roadName: name, bearing: bearing) {
                return cached
            }
        }

        // Secondary path: spatial fallback
        return lookupNearest(to: coordinate, radiusMeters: 50)
    }

    /// Store multiple road segments from a batch API response.
    /// Each row occupies ~80 bytes; 5000 rows ≈ 400KB (trivially small).
    public func store(roads: [CachedRoad]) {
        guard !roads.isEmpty else { return }

        queue.sync {
            guard let db = self.db else { return }

            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

            let sql = """
                INSERT OR REPLACE INTO cached_roads
                    (road_name, direction, speed_limit, lat, lon, source)
                VALUES (?, ?, ?, ?, ?, ?)
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
        return lookupNearest(to: coordinate, radiusMeters: radiusMeters) != nil
    }

    /// Estimate coverage as a fraction (0.0–1.0) by checking 4 concentric
    /// radii around the coordinate.
    public func estimatedCoverage(at coordinate: CLLocationCoordinate2D, radiusMeters: Double = 1500) -> Double {
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
