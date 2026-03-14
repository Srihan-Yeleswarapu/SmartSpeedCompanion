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
        let p1: CLLocationCoordinate2D
        let p2: CLLocationCoordinate2D
        let limit: Int
    }

    // MARK: - Public API
    
    /// Opens the SQLite-based geodatabase at the specified file path.
    public func loadDatabase(at path: String) -> Bool {
        guard !isLoaded else { return true }
        
        // Open with Multi-thread mode for safety with Actors
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK {
            isLoaded = true
            return true
        }
        return false
    }
    
    /// Opens the geodatabase from the app bundle.
    public func loadDataIfNeeded() {
        // Try both possible filenames
        let possibleNames = [
            ("HPMS_2024_Data_-2111065798425599378", "geodatabase"),
            ("ArizonaSpeedLimits", "sqlite"),
            ("ArizonaSpeedLimits", "db")
        ]
        
        for (name, ext) in possibleNames {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                if loadDatabase(at: url.path) {
                    print("[AZ Data] Successfully loaded geodatabase: \(name).\(ext)")
                    return
                }
            }
        }
        print("[AZ Data] No supported geodatabase file found in bundle.")
    }

    /// Finds the legal speed limit for a given coordinate.
    public func fetchSpeedLimit(at coordinate: CLLocationCoordinate2D) async throws -> Int {
        guard isLoaded else {
            throw URLError(.noPermissionsToReadFile)
        }

        let searchOffsets = [-gridPrecision, 0.0, gridPrecision]
        var closestLimit: Int?
        var minDistance: CLLocationDistance = 50.0 // 50 meters threshold
        
        for latOff in searchOffsets {
            for lonOff in searchOffsets {
                // We call the local private function to check cache/db
                let segments = getSegmentsForGrid(lat: coordinate.latitude + latOff, 
                                                lon: coordinate.longitude + lonOff)
                
                for segment in segments {
                    let distance = distanceToSegment(target: coordinate, p1: segment.p1, p2: segment.p2)
                    if distance < minDistance {
                        minDistance = distance
                        closestLimit = segment.limit
                    }
                }
            }
        }
        
        if let limit = closestLimit { return limit }
        throw URLError(.resourceUnavailable)
    }

    // MARK: - Private Logic
    
    private func getSegmentsForGrid(lat: Double, lon: Double) -> [RoadSegment] {
        let key = gridKey(lat: lat, lon: lon)
        
        if let cached = spatialCache[key] {
            return cached
        }
        
        let segments = queryDatabase(lat: lat, lon: lon)
        spatialCache[key] = segments
        return segments
    }

    private func gridKey(lat: Double, lon: Double) -> String {
        let latK = round(lat / gridPrecision) * gridPrecision
        let lonK = round(lon / gridPrecision) * gridPrecision
        return String(format: "%.2f_%.2f", latK, lonK)
    }

    private func queryDatabase(lat: Double, lon: Double) -> [RoadSegment] {
        guard let db = db else { return [] }
        var segments: [RoadSegment] = []
        
        // Ensure your SQLite table name matches "ArizonaSpeedLimits"
        let sql = "SELECT SHAPE, SpeedLimit FROM ArizonaSpeedLimits WHERE MBRIntersects(SHAPE, BuildMBR(?, ?, ?, ?));"
        
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, lon - gridPrecision)
            sqlite3_bind_double(stmt, 2, lat - gridPrecision)
            sqlite3_bind_double(stmt, 3, lon + gridPrecision)
            sqlite3_bind_double(stmt, 4, lat + gridPrecision)
            
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let blob = sqlite3_column_blob(stmt, 0) {
                    let size = sqlite3_column_bytes(stmt, 0)
                    let data = Data(bytes: blob, count: Int(size))
                    let limit = Int(sqlite3_column_int(stmt, 1))
                    
                    let points = parseWKBLineString(data)
                    for i in 0..<(points.count - 1) {
                        segments.append(RoadSegment(p1: points[i], p2: points[i+1], limit: limit))
                    }
                }
            }
        }
        sqlite3_finalize(stmt)
        return segments
    }

    private func distanceToSegment(target: CLLocationCoordinate2D, 
                                   p1: CLLocationCoordinate2D, 
                                   p2: CLLocationCoordinate2D) -> CLLocationDistance {
        let dx = p2.longitude - p1.longitude
        let dy = p2.latitude - p1.latitude
        
        if dx == 0 && dy == 0 { return target.distance(from: p1) }
        
        let t = ((target.longitude - p1.longitude) * dx + (target.latitude - p1.latitude) * dy) / (dx * dx + dy * dy)
        let clampedT = max(0, min(1, t))
        
        let nearestPoint = CLLocationCoordinate2D(
            latitude: p1.latitude + clampedT * dy,
            longitude: p1.longitude + clampedT * dx
        )
        
        return target.distance(from: nearestPoint)
    }

    private func parseWKBLineString(_ data: Data) -> [CLLocationCoordinate2D] {
        guard data.count > 9 else { return [] }
        var points: [CLLocationCoordinate2D] = []
        
        let isLittleEndian = data[0] == 1
        let numPoints = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> UInt32 in
            let val = ptr.load(fromByteOffset: 5, as: UInt32.self)
            return isLittleEndian ? UInt32(littleEndian: val) : UInt32(bigEndian: val)
        }
        
        for i in 0..<Int(numPoints) {
            let offset = 9 + (i * 16)
            guard data.count >= offset + 16 else { break }
            
            let (lon, lat) = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> (Double, Double) in
                let loUInt = ptr.load(fromByteOffset: offset, as: UInt64.self)
                let laUInt = ptr.load(fromByteOffset: offset + 8, as: UInt64.self)
                
                let loBits = isLittleEndian ? UInt64(littleEndian: loUInt) : UInt64(bigEndian: loUInt)
                let laBits = isLittleEndian ? UInt64(littleEndian: laUInt) : UInt64(bigEndian: laUInt)
                
                return (Double(bitPattern: loBits), Double(bitPattern: laBits))
            }
            points.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        return points
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