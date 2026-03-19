import Foundation
import CoreLocation
import SQLite3

/// A thread-safe actor service that queries Arizona speed limit data.
/// Updated for Swift 6 Concurrency and Xcode 16 compatibility.
public actor ArizonaSpeedLimitService {
    
    private var db: OpaquePointer?
    private var isLoaded = false

    private var circularCache: [RoadSegment] = []
    private var lastCacheCenter: CLLocationCoordinate2D?
    private let cacheRadiusDegrees = 0.03 // Approx 2 miles
    private let triggerDistanceMeters = 1609.0 // 1 mile
    
    // Grid precision: 0.02 degrees is roughly 2.2km per cell.
    // Larger cells mean fewer DB queries per drive and better route pre-cache coverage.
    private let gridPrecision = 0.02
    private var spatialCache: [String: [RoadSegment]] = [:]
    private var lastSegmentId: String?
    
    private init() {}
    
    deinit {
        if let db = db {
            sqlite3_close_v2(db)
        }
    }

    // MARK: - Data Models
    
    struct RoadSegment: Sendable {
        let minx: Double
        let maxx: Double
        let miny: Double
        let maxy: Double
        let limit: Int
        let routeId: String?
        
        var area: Double {
            return (maxx - minx) * (maxy - miny)
        }
        
        func distance(to coord: CLLocationCoordinate2D) -> CLLocationDistance {
            let dx = max(0.0, minx - coord.longitude, coord.longitude - maxx)
            let dy = max(0.0, miny - coord.latitude, coord.latitude - maxy)
            
            if dx == 0 && dy == 0 { return 0 }
            
            // Geographic to meters approximation
            let latDist = dy * 111111.0
            let lonDist = dx * 111111.0 * cos(coord.latitude * .pi / 180.0)
            return sqrt(latDist * latDist + lonDist * lonDist)
        }
    }

    // MARK: - Public API
    
    /// Opens the SQLite-based geodatabase at the specified file path.
    public func loadDatabase(at path: String) -> Bool {
        guard !isLoaded else { return true }
        
        let result = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        if result == SQLITE_OK {
            isLoaded = true
            DebugLogger.shared.log("DB OPENED: \(URL(fileURLWithPath: path).lastPathComponent)")
            print("[AZ Data] Geodatabase OPENED at \(path)")
            return true
        } else {
            let errmsg = db != nil ? String(cString: sqlite3_errmsg(db)!) : "Unknown error"
            DebugLogger.shared.log("DB OPEN FAILED: \(errmsg)")
            print("[AZ Data] FAILED to open geodatabase: \(result) - \(errmsg)")
            return false
        }
    }
    
    /// Opens the geodatabase from the app bundle.
    public func loadDataIfNeeded() {
        guard !isLoaded else { return }
        
        // First try the prioritized name
        let possibleNames = [
            ("ArizonaSpeedLimits", "sqlite"),
            ("ArizonaSpeedLimits", "db"),
            ("HPMS_2024_Data_-2111065798425599378", "geodatabase")
        ]
        
        DebugLogger.shared.log("Searching for DB...")
        
        for (name, ext) in possibleNames {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                DebugLogger.shared.log("Found DB candidate: \(name).\(ext)")
                if loadDatabase(at: url.path) {
                    return
                }
            }
        }
        
        // Search entire bundle one level deep
        let bundleURL = Bundle.main.bundleURL
        DebugLogger.shared.log("Scanning bundle: \(bundleURL.lastPathComponent)")
        
        if let contents = try? FileManager.default.contentsOfDirectory(at: bundleURL, includingPropertiesForKeys: nil) {
            let fileList = contents.map { $0.lastPathComponent }.joined(separator: ", ")
            DebugLogger.shared.log("Bundle Files: \(fileList)")
            
            for url in contents {
                // If it's a directory, list its contents too
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    if let subContents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                        let subList = subContents.map { $0.lastPathComponent }.joined(separator: ", ")
                        DebugLogger.shared.log("Inside \(url.lastPathComponent): \(subList)")
                        
                        for subUrl in subContents {
                            let ext = subUrl.pathExtension.lowercased()
                            if ["sqlite", "db", "geodatabase", "gpkg"].contains(ext) {
                                DebugLogger.shared.log("Found \(ext) in subfolder: \(subUrl.lastPathComponent)")
                                if loadDatabase(at: subUrl.path) {
                                    return
                                }
                            }
                        }
                    }
                }
                
                let ext = url.pathExtension.lowercased()
                if ["sqlite", "db", "geodatabase", "gpkg"].contains(ext) {
                    DebugLogger.shared.log("Found \(ext) file: \(url.lastPathComponent)")
                    if loadDatabase(at: url.path) {
                        return
                    }
                }
            }
        }
        
        DebugLogger.shared.log("DB NOT FOUND in initial scan - trying recursive search...")
        
        // Final recursive attempt
        if let enumerator = FileManager.default.enumerator(at: bundleURL, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                if ["sqlite", "db", "geodatabase", "gpkg"].contains(url.pathExtension.lowercased()) {
                    if loadDatabase(at: url.path) {
                        return
                    }
                }
            }
        }
        
        DebugLogger.shared.log("FATAL: DB NOT FOUND anywhere.")
        print("[AZ Data] No supported geodatabase file found in bundle.")
        isLoaded = true // Stop trying
    }

    /// Finds the legal speed limit for a given coordinate.
    /// Added heading awareness to prevent snapping to cross-streets or nearby parallel roads.
    public func updateSpeedLimit(at coordinate: CLLocationCoordinate2D, heading: Double? = nil, currentSpeedMph: Double? = nil, expandedSearch: Bool = false) async throws -> Int {
        if !isLoaded {
            loadDataIfNeeded()
        }
        if db == nil {
            throw URLError(.resourceUnavailable)
        }

        // Trigger recache if first run or if moved > 1 mile from previous cache center
        let shouldRefresh = lastCacheCenter == nil || 
                           coordinate.distance(from: lastCacheCenter!) > triggerDistanceMeters
        
        if shouldRefresh {
            refreshCircularCache(at: coordinate)
        }

        let segments = circularCache // Use the high-speed memory cache
        
        var closestLimit: Int?
        var closestRouteId: String?
        var minScore: Double = Double.infinity 
        
        // Extremely tight snapping radius for high precision, expanding only if lost
        let maxSnappingDistance: CLLocationDistance = expandedSearch ? 60.0 : 25.0 
        
        for segment in segments {
            guard segment.limit > 0 else { continue }
            
            // Check bounding box size (ignore generic county-wide polygons)
            let dx = segment.maxx - segment.minx
            let dy = segment.maxy - segment.miny
            let diagonalDegrees = sqrt(dx*dx + dy*dy)
            
            // RELAXED: Highway segments in AZ can be very long (50+ miles). 
            // 0.1 was ~7 miles. 1.0 (~70 miles) is safer for interstates.
            if diagonalDegrees > 1.0 { continue }
            
            let distance = segment.distance(to: coordinate)
            guard distance <= maxSnappingDistance else { continue }
            
            // --- HEADING AWARENESS LOGIC ---
            var scoreMultiplier: Double = 1.0
            
            if let carHeading = heading {
                let isNorthSouth = dy > dx
                let simplifiedRoadHeading = isNorthSouth ? 0.0 : 90.0
                
                let diff = abs(carHeading.truncatingRemainder(dividingBy: 180) - simplifiedRoadHeading)
                let normalizedDiff = min(diff, 180 - diff)
                
                if normalizedDiff > 40 {
                    scoreMultiplier *= 8.0 // Heavy penalty for cross-streets
                } else if normalizedDiff > 20 {
                    scoreMultiplier *= 2.5 // Moderate penalty for diagonal misalignment
                }
            }

            // --- VELOCITY MATCHING (EXIT RAMP PROTECTION) ---
            // If we are driving 65mph, and one segment says 65 and another says 35,
            // we strongly prefer the 65 even if the 35 is slightly closer (like a ramp).
            if let currentSpdMph = currentSpeedMph, currentSpdMph > 30 {
                let speedDiff = abs(Double(segment.limit) - currentSpdMph)
                if speedDiff > 25 {
                    scoreMultiplier *= 3.0 // Road limit is very different from current speed
                }
            }
            
            // Score = Distance * Multiplier
            var score = distance * scoreMultiplier
            if let lastId = self.lastSegmentId, segment.routeId == lastId {
                score *= 0.40 // 60% bias towards staying on the same road segment
            }
            
            // TIE-BREAKER: If multiple bounding boxes contain the user (distance == 0),
            // prefer the one with the smaller area (e.g., a specific exit ramp vs a huge highway).
            score += (segment.area * 1000.0) // small enough not to override real distance, big enough to break ties
            
            if score < minScore {
                minScore = score
                closestLimit = segment.limit
                closestRouteId = segment.routeId
            }
        }
        
        if let limit = closestLimit, limit > 0 { 
            self.lastSegmentId = closestRouteId
            DebugLogger.shared.log("AZ Data: Found limit \(limit) on \(closestRouteId ?? "unknown road")")
            return limit 
        }
        
        DebugLogger.shared.log("AZ Data: No segment found within \(Int(maxSnappingDistance))m of [\(coordinate.latitude), \(coordinate.longitude)]")
        throw URLError(.resourceUnavailable)
    }

    // MARK: - Private Logic
    
    private func getSegmentsForGrid(lat: Double, lon: Double) -> [RoadSegment] {
        // Use floor() for stable, non-overlapping tile boundaries.
        // round() caused the same real-world point to map to different keys depending
        // on minor floating-point drift, breaking the cache hit rate.
        let latK = floor(lat / gridPrecision) * gridPrecision
        let lonK = floor(lon / gridPrecision) * gridPrecision
        let key = String(format: "%.4f_%.4f", latK, lonK)
        
        if let cached = spatialCache[key] {
            return cached
        }
        
        let segments = queryDatabase(lat: latK, lon: lonK)
        DebugLogger.shared.log("CACHE MISS: Loaded \(segments.count) road segments for grid \(key)")
        spatialCache[key] = segments
        return segments
    }

    // Helper method gridKey removed - logic moved inline for clarity


    private func queryDatabase(lat: Double, lon: Double) -> [RoadSegment] {
        guard let db = db else { return [] }
        let searchBuffer = gridPrecision
        var segments: [RoadSegment] = []
        
        let sql = """
            SELECT a.SpeedLimit, b.minx, b.maxx, b.miny, b.maxy, a.RouteId
            FROM SpeedLimit_2024 a
            JOIN st_spindex__SpeedLimit_2024_SHAPE b ON a.OBJECTID = b.pkid
            WHERE ? <= b.maxx AND ? >= b.minx
              AND ? <= b.maxy AND ? >= b.miny
        """
        
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, lon - searchBuffer)
            sqlite3_bind_double(stmt, 2, lon + searchBuffer)
            sqlite3_bind_double(stmt, 3, lat - searchBuffer)
            sqlite3_bind_double(stmt, 4, lat + searchBuffer)
            
            while sqlite3_step(stmt) == SQLITE_ROW {
                let limit = Int(sqlite3_column_int(stmt, 0))
                let minx = sqlite3_column_double(stmt, 1)
                let maxx = sqlite3_column_double(stmt, 2)
                let miny = sqlite3_column_double(stmt, 3)
                let maxy = sqlite3_column_double(stmt, 4)
                let routeId = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                
                segments.append(RoadSegment(minx: minx, maxx: maxx, miny: miny, maxy: maxy, limit: limit, routeId: routeId))
            }
            sqlite3_finalize(stmt)
        } else {
            let errmsg = String(cString: sqlite3_errmsg(db)!)
            DebugLogger.shared.log("DB QUERY ERR: \(errmsg)")
            print("[AZ Data] Query preparation failed: \(errmsg)")
            sqlite3_finalize(stmt)
        }
        
        if segments.isEmpty {
            DebugLogger.shared.log("DB: Zero matches in grid cell. Check if you are in Arizona.")
        }
        
        return segments
    }

    // MARK : Circular Cache

    private func refreshCircularCache(at center: CLLocationCoordinate2D) {
        guard let db = db else { return }
        var segments: [RoadSegment] = []
        
        let sql = """
            SELECT a.SpeedLimit, b.minx, b.maxx, b.miny, b.maxy, a.RouteId
            FROM SpeedLimit_2024 a
            JOIN st_spindex__SpeedLimit_2024_SHAPE b ON a.OBJECTID = b.pkid
            WHERE ? <= b.maxx AND ? >= b.minx
              AND ? <= b.maxy AND ? >= b.miny
        """
        
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            // Bind a box covering the 2-mile radius
            sqlite3_bind_double(stmt, 1, center.longitude - cacheRadiusDegrees)
            sqlite3_bind_double(stmt, 2, center.longitude + cacheRadiusDegrees)
            sqlite3_bind_double(stmt, 3, center.latitude - cacheRadiusDegrees)
            sqlite3_bind_double(stmt, 4, center.latitude + cacheRadiusDegrees)
            
            while sqlite3_step(stmt) == SQLITE_ROW {
                segments.append(RoadSegment(
                    minx: sqlite3_column_double(stmt, 1),
                    maxx: sqlite3_column_double(stmt, 2),
                    miny: sqlite3_column_double(stmt, 3),
                    maxy: sqlite3_column_double(stmt, 4),
                    limit: Int(sqlite3_column_int(stmt, 0)),
                    routeId: sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                ))
            }
            sqlite3_finalize(stmt)
        }
        
        self.circularCache = segments
        self.lastCacheCenter = center
        DebugLogger.shared.log("Cache: Refreshed 2-mile radius with \(segments.count) segments.")
    }

    private func boundingBox(for center: CLLocationCoordinate2D, radius: Double) -> (minx: Double, maxx: Double, miny: Double, maxy: Double) {
        return (
            center.longitude - radius,
            center.longitude + radius,
            center.latitude - radius,
            center.latitude + radius
        )
    }

    private func intersects(_ segment: RoadSegment, _ bounds: (minx: Double, maxx: Double, miny: Double, maxy: Double)) -> Bool {
        return segment.maxx >= bounds.minx && segment.minx <= bounds.maxx &&
               segment.maxy >= bounds.miny && segment.miny <= bounds.maxy
    }

    // Distance logic moved into RoadSegment struct.

    
    // parseWKBLineString is removed as Esri geodatabases use proprietary 
    // Compressed Geometry. We use spatial index bounding boxes instead natively.

    /// Clears the spatial cache.
    public func clearCache() {
        spatialCache.removeAll()
    }
    
    /// Pre-caches speed limits along a planned route.
    public func preCacheRoute(coordinates: [CLLocationCoordinate2D]) async {
        for coord in coordinates {
            // We search in 3x3 grid around each point to ensure coverage
            let searchOffsets = [-gridPrecision, 0.0, gridPrecision]
            for latOff in searchOffsets {
                for lonOff in searchOffsets {
                    _ = getSegmentsForGrid(lat: coord.latitude + latOff, 
                                         lon: coord.longitude + lonOff)
                }
            }
        }
    }
}

// MARK: - Extensions
extension CLLocationCoordinate2D {
    func distance(from other: CLLocationCoordinate2D) -> CLLocationDistance {
        let locA = CLLocation(latitude: self.latitude, longitude: self.longitude)
        let locB = CLLocation(latitude: other.latitude, longitude: other.longitude)
        return locA.distance(from: locB)
    }
}