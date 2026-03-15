import Foundation
import CoreLocation
import SQLite3

/// A thread-safe actor service that queries Arizona speed limit data.
/// Updated for Swift 6 Concurrency and Xcode 16 compatibility.
public actor ArizonaSpeedLimitService {
    public static let shared = ArizonaSpeedLimitService()
    
    private var db: OpaquePointer?
    private var isLoaded = false
    
    // Grid precision: 0.01 degree is roughly 1.1km.
    private let gridPrecision = 0.01
    private var spatialCache: [String: [RoadSegment]] = [:]
    
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
            for url in contents {
                let ext = url.pathExtension.lowercased()
                if ["sqlite", "db", "geodatabase", "gpkg"].contains(ext) {
                    DebugLogger.shared.log("Found \(ext) file: \(url.lastPathComponent)")
                    if loadDatabase(at: url.path) {
                        return
                    }
                }
            }
        }
        
        DebugLogger.shared.log("DB NOT FOUND in bundle root - trying recursive search...")
        
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
        isLoaded = true 
    }

    /// Finds the legal speed limit for a given coordinate.
    public func fetchSpeedLimit(at coordinate: CLLocationCoordinate2D) async throws -> Int {
        if !isLoaded {
            loadDataIfNeeded()
        }
        if db == nil {
            throw URLError(.resourceUnavailable)
        }

        let segments = getSegmentsForGrid(lat: coordinate.latitude, lon: coordinate.longitude)
        
        if segments.isEmpty {
            DebugLogger.shared.log("NO SEGMENTS at [\(String(format: "%.3f", coordinate.latitude)), \(String(format: "%.3f", coordinate.longitude))]")
        }

        var closestLimit: Int?
        var minDistance: CLLocationDistance = 200.0 // Increased to 200m for better coverage in wide junctions
        var smallestArea: Double = Double.infinity
        
        for segment in segments {
            guard segment.limit > 0 else { continue }
            
            let distance = segment.distance(to: coordinate)
            
            if distance <= minDistance {
                if distance < minDistance - 0.1 {
                    minDistance = distance
                    closestLimit = segment.limit
                    smallestArea = segment.area
                } else if distance <= 0.1 { 
                    if segment.area < smallestArea {
                        closestLimit = segment.limit
                        smallestArea = segment.area
                    }
                }
            }
        }
        
        if let limit = closestLimit, limit > 0 { 
            DebugLogger.shared.log("MATCH: \(limit) mph (\(Int(minDistance))m)")
            return limit 
        }
        
        throw URLError(.resourceUnavailable)
    }

    // MARK: - Private Logic
    
    private func getSegmentsForGrid(lat: Double, lon: Double) -> [RoadSegment] {
        let latK = round(lat / gridPrecision) * gridPrecision
        let lonK = round(lon / gridPrecision) * gridPrecision
        let key = String(format: "%.2f_%.2f", latK, lonK)
        
        if let cached = spatialCache[key] {
            return cached
        }
        
        // Query database using the deterministic grid center, 
        // to ensure cache results are always consistent regardless of the exact 
        // coordinate that triggered the cache miss.
        let segments = queryDatabase(lat: latK, lon: lonK)
        spatialCache[key] = segments
        return segments
    }

    // Helper method gridKey removed - logic moved inline for clarity


    private func queryDatabase(lat: Double, lon: Double) -> [RoadSegment] {
        guard let db = db else { return [] }
        var segments: [RoadSegment] = []
        
        let sql = """
            SELECT a.SpeedLimit, b.minx, b.maxx, b.miny, b.maxy
            FROM SpeedLimit_2024 a
            JOIN st_spindex__SpeedLimit_2024_SHAPE b ON a.OBJECTID = b.pkid
            WHERE ? <= b.maxx AND ? >= b.minx
              AND ? <= b.maxy AND ? >= b.miny
        """
        
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            let searchBuffer = gridPrecision
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
                
                segments.append(RoadSegment(minx: minx, maxx: maxx, miny: miny, maxy: maxy, limit: limit))
            }
            sqlite3_finalize(stmt)
        } else {
            let errmsg = String(cString: sqlite3_errmsg(db)!)
            DebugLogger.shared.log("DB QUERY ERR: \(errmsg)")
            print("[AZ Data] Query preparation failed: \(errmsg)")
            sqlite3_finalize(stmt)
        }
        
        return segments
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