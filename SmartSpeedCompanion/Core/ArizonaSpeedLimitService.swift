import Foundation
import CoreLocation
import SQLite3

/// Service that queries an Esri File Geodatabase for Arizona speed limits.
public class ArizonaSpeedLimitService {
    public static let shared = ArizonaSpeedLimitService()
    
    private var db: OpaquePointer?
    private var isLoaded = false
    
    // Grid precision for caching: 0.01 degree ~1km
    private let gridPrecision = 0.01
    private var spatialCache: [String: [(CLLocationCoordinate2D, CLLocationCoordinate2D, Int)]] = [:]
    
    private init() {}
    
    /// Opens the geodatabase (SQLite-based) once
    public func loadDatabase(at path: String) -> Bool {
        if isLoaded { return true }
        let dbPath = path
        if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            isLoaded = true
            print("[AZ DB] Opened geodatabase at \(path)")
            return true
        } else {
            print("[AZ DB] Failed to open geodatabase at \(path)")
            return false
        }
    }
    
    /// Fetches the speed limit at a given coordinate
    public func fetchSpeedLimit(at coordinate: CLLocationCoordinate2D) async throws -> Int {
        guard isLoaded, let db = db else {
            throw URLError(.cannotOpenFile)
        }
        
        // Compute 3x3 grid around target
        let latKey = round(coordinate.latitude / gridPrecision) * gridPrecision
        let lonKey = round(coordinate.longitude / gridPrecision) * gridPrecision
        let offsets = [-gridPrecision, 0.0, gridPrecision]
        
        var closestLimit: Int?
        var minDistance: CLLocationDistance = 60 // meters
        
        for latOffset in offsets {
            for lonOffset in offsets {
                let keyLat = latKey + latOffset
                let keyLon = lonKey + lonOffset
                let cacheKey = "\(keyLat)_\(keyLon)"
                
                var segments: [(CLLocationCoordinate2D, CLLocationCoordinate2D, Int)] = []
                
                // Check cache first
                if let cached = spatialCache[cacheKey] {
                    segments = cached
                } else {
                    // Query the geodatabase table: adjust table/field names based on your .gdb schema
                    let sql = """
                    SELECT SHAPE, SpeedLimit
                    FROM ArizonaSpeedLimits
                    WHERE MBRIntersects(SHAPE,
                        BuildMBR(\(keyLon), \(keyLat), \(keyLon + gridPrecision), \(keyLat + gridPrecision))
                    );
                    """
                    var stmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                        while sqlite3_step(stmt) == SQLITE_ROW {
                            // SHAPE is stored as WKB (Binary)
                            if let shapeBlob = sqlite3_column_blob(stmt, 0) {
                                let shapeSize = sqlite3_column_bytes(stmt, 0)
                                let data = Data(bytes: shapeBlob, count: Int(shapeSize))
                                
                                // Parse line segments from WKB (simplified: LineString only)
                                let lineSegments = parseLineSegments(fromWKB: data)
                                
                                // Speed limit
                                let limit = Int(sqlite3_column_int(stmt, 1))
                                for seg in lineSegments {
                                    segments.append((seg.0, seg.1, limit))
                                }
                            }
                        }
                        sqlite3_finalize(stmt)
                    }
                    spatialCache[cacheKey] = segments
                }
                
                let targetLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                for (p1, p2, limit) in segments {
                    let d = distanceToSegment(target: targetLoc.coordinate, p1: p1, p2: p2)
                    if d < minDistance {
                        minDistance = d
                        closestLimit = limit
                    }
                }
            }
        }
        
        if let best = closestLimit {
            return best
        }
        
        throw URLError(.resourceUnavailable)
    }
    
    // MARK: - Helpers
    
    private func distanceToSegment(target: CLLocationCoordinate2D,
                                   p1: CLLocationCoordinate2D,
                                   p2: CLLocationCoordinate2D) -> CLLocationDistance {
        // Same equirectangular approximation as before
        let latMid = (p1.latitude + p2.latitude) / 2.0 * .pi / 180.0
        let m_per_deg_lat = 111132.92 - 559.82 * cos(2 * latMid) + 1.175 * cos(4 * latMid)
        let m_per_deg_lon = 111412.84 * cos(latMid) - 93.5 * cos(3 * latMid)
        
        let x0 = target.longitude * m_per_deg_lon
        let y0 = target.latitude * m_per_deg_lat
        let x1 = p1.longitude * m_per_deg_lon
        let y1 = p1.latitude * m_per_deg_lat
        let x2 = p2.longitude * m_per_deg_lon
        let y2 = p2.latitude * m_per_deg_lat
        
        let A = x0 - x1
        let B = y0 - y1
        let C = x2 - x1
        let D = y2 - y1
        
        let dot = A * C + B * D
        let len_sq = C * C + D * D
        let param = len_sq != 0 ? dot / len_sq : -1
        
        let xx: Double
        let yy: Double
        
        if param < 0 {
            xx = x1; yy = y1
        } else if param > 1 {
            xx = x2; yy = y2
        } else {
            xx = x1 + param * C
            yy = y1 + param * D
        }
        
        let dx = x0 - xx
        let dy = y0 - yy
        return sqrt(dx*dx + dy*dy)
    }
    
    /// Parse LineString WKB into array of segment tuples (simplified)
    private func parseLineSegments(fromWKB data: Data) -> [(CLLocationCoordinate2D, CLLocationCoordinate2D)] {
        // Implement proper WKB parsing for your geodatabase; placeholder:
        return []
    }
}