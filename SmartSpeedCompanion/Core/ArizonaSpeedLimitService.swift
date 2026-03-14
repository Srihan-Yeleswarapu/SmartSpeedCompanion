import Foundation
import CoreLocation
import SQLite3

/// Service that queries an Esri File Geodatabase for Arizona speed limits.
public class ArizonaSpeedLimitService {
    public static let shared = ArizonaSpeedLimitService()
    
    private var db: OpaquePointer?
    private var isLoaded = false
    
    /// Grid precision for caching: 0.01 degree ~1 km
    private let gridPrecision = 0.01
    private var spatialCache: [String: [(CLLocationCoordinate2D, CLLocationCoordinate2D, Int)]] = [:]
    
    private init() {}
    
    // MARK: - Public
    
    /// Open the geodatabase (SQLite-based)
    public func loadDatabase(at path: String) -> Bool {
        if isLoaded { return true }
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            isLoaded = true
            print("[AZ DB] Opened geodatabase at \(path)")
            return true
        } else {
            print("[AZ DB] Failed to open geodatabase at \(path)")
            return false
        }
    }
    
    /// Fetch speed limit at a coordinate
    public func fetchSpeedLimit(at coordinate: CLLocationCoordinate2D) async throws -> Int {
        guard isLoaded, let db = db else { throw URLError(.cannotOpenFile) }
        
        let targetLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let offsets = [-gridPrecision, 0.0, gridPrecision]
        var closestLimit: Int?
        var minDistance: CLLocationDistance = 1000 // 1 km default
        
        for latOffset in offsets {
            for lonOffset in offsets {
                let keyLat = coordinate.latitude + latOffset
                let keyLon = coordinate.longitude + lonOffset
                let cacheKey = gridKey(lat: keyLat, lon: keyLon)
                
                var segments: [(CLLocationCoordinate2D, CLLocationCoordinate2D, Int)] = []
                
                // Check cache first
                if let cached = spatialCache[cacheKey] {
                    segments = cached
                } else {
                    segments = querySegments(db: db, lat: keyLat, lon: keyLon)
                    spatialCache[cacheKey] = segments
                }
                
                // Find closest segment
                for (p1, p2, limit) in segments {
                    let d = distanceToSegment(target: targetLoc.coordinate, p1: p1, p2: p2)
                    if d < minDistance {
                        minDistance = d
                        closestLimit = limit
                    }
                }
            }
        }
        
        if let limit = closestLimit { return limit }
        throw URLError(.resourceUnavailable)
    }
    
    // MARK: - Helpers
    
    /// Create a unique key for caching a grid cell
    private func gridKey(lat: Double, lon: Double) -> String {
        let latK = round(lat / gridPrecision) * gridPrecision
        let lonK = round(lon / gridPrecision) * gridPrecision
        return "\(latK)_\(lonK)"
    }
    
    /// Query segments from the geodatabase for a grid cell
    private func querySegments(db: OpaquePointer, lat: Double, lon: Double) -> [(CLLocationCoordinate2D, CLLocationCoordinate2D, Int)] {
        var segments: [(CLLocationCoordinate2D, CLLocationCoordinate2D, Int)] = []
        
        let sql = """
        SELECT SHAPE, SpeedLimit
        FROM ArizonaSpeedLimits
        WHERE MBRIntersects(SHAPE,
            BuildMBR(\(lon), \(lat), \(lon + gridPrecision), \(lat + gridPrecision))
        );
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let blob = sqlite3_column_blob(stmt, 0) {
                    let size = sqlite3_column_bytes(stmt, 0)
                    let data = Data(bytes: blob, count: Int(size))
                    let lines = parseLineSegments(fromWKB: data)
                    let limit = Int(sqlite3_column_int(stmt, 1))
                    for line in lines {
                        segments.append((line.0, line.1, limit))
                    }
                }
            }
            sqlite3_finalize(stmt)
        }
        
        return segments
    }
    
    /// Distance from a point to a segment (meters) using equirectangular approximation
    private func distanceToSegment(target: CLLocationCoordinate2D,
                                   p1: CLLocationCoordinate2D,
                                   p2: CLLocationCoordinate2D) -> CLLocationDistance {
        let latMid = (p1.latitude + p2.latitude) / 2.0 * .pi / 180.0
        let mPerDegLat = 111132.92 - 559.82 * cos(2 * latMid) + 1.175 * cos(4 * latMid)
        let mPerDegLon = 111412.84 * cos(latMid) - 93.5 * cos(3 * latMid)
        
        let x0 = target.longitude * mPerDegLon
        let y0 = target.latitude * mPerDegLat
        let x1 = p1.longitude * mPerDegLon
        let y1 = p1.latitude * mPerDegLat
        let x2 = p2.longitude * mPerDegLon
        let y2 = p2.latitude * mPerDegLat
        
        let dx = x2 - x1
        let dy = y2 - y1
        let t = max(0, min(1, ((x0 - x1) * dx + (y0 - y1) * dy) / (dx*dx + dy*dy)))
        let xx = x1 + t * dx
        let yy = y1 + t * dy
        let dist = sqrt((x0 - xx)*(x0 - xx) + (y0 - yy)*(y0 - yy))
        return dist
    }
    
    /// Parse WKB LineString into line segments
    private func parseLineSegments(fromWKB data: Data) -> [(CLLocationCoordinate2D, CLLocationCoordinate2D)] {
        var segments: [(CLLocationCoordinate2D, CLLocationCoordinate2D)] = []
        guard data.count > 9 else { return [] }
        
        var cursor = 0
        let byteOrder = data[cursor]
        cursor += 1
        let isLittleEndian = byteOrder == 1
        cursor += 4 // Skip geometry type (LineString)
        
        func readUInt32() -> UInt32 {
            let sub = data[cursor..<cursor+4]
            cursor += 4
            return isLittleEndian ? sub.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
                                  : sub.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
        }
        
        func readDouble() -> Double {
            let sub = data[cursor..<cursor+8]
            cursor += 8
            return isLittleEndian ? sub.withUnsafeBytes { $0.load(as: Double.self) }.littleEndian
                                  : sub.withUnsafeBytes { $0.load(as: Double.self) }.bigEndian
        }
        
        let numPoints = Int(readUInt32())
        guard numPoints >= 2 else { return [] }
        
        var points: [CLLocationCoordinate2D] = []
        for _ in 0..<numPoints {
            let lon = readDouble()
            let lat = readDouble()
            points.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        
        for i in 0..<(points.count-1) {
            segments.append((points[i], points[i+1]))
        }
        
        return segments
    }
}