import Foundation
import CoreLocation

/// Service that parses the local ArizonaSpeedLimits.geojson and provides rapid
/// spatial lookups using a memory-based grid spatial index.
public class ArizonaSpeedLimitService {
    public static let shared = ArizonaSpeedLimitService()
    
    private var isLoaded = false
    private var isLoading = false
    
    // Grid: Key is "lat_lon" (rounded to 2 decimals, ~1km precision), Value is array of segments.
    private var spatialGrid: [String: [(CLLocationCoordinate2D, CLLocationCoordinate2D, Int)]] = [:]
    
    private init() { }
    
    public func loadDataIfNeeded() async {
        if isLoaded || isLoading { return }
        isLoading = true
        
        defer { isLoading = false }
        
        guard let url = Bundle.main.url(forResource: "ArizonaSpeedLimits", withExtension: "geojson") else {
            print("[AZ Data] ArizonaSpeedLimits.geojson not found in bundle.")
            return
        }
        
        do {
            let data = try Data(contentsOf: url)
            
            // Dispatch parsing to a background thread to prevent UI hangs (57MB file)
            let resultGrid = try await Task.detached(priority: .background) { () -> [String: [(CLLocationCoordinate2D, CLLocationCoordinate2D, Int)]] in
                var grid = [String: [(CLLocationCoordinate2D, CLLocationCoordinate2D, Int)]]()
                
                guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let features = json["features"] as? [[String: Any]] else {
                    return [:]
                }
                
                for feature in features {
                    guard let properties = feature["properties"] as? [String: Any],
                          let limitStr = properties["SpeedLimit"] else { continue }
                    
                    // Parse limit
                    let limit: Int
                    if let lInt = limitStr as? Int {
                        limit = lInt
                    } else if let lStr = limitStr as? String, let parsed = Int(lStr) {
                        limit = parsed
                    } else {
                        continue
                    }
                    
                    guard let geometry = feature["geometry"] as? [String: Any],
                          let coordinates = geometry["coordinates"] as? [Any] else { continue }
                    
                    let type = geometry["type"] as? String ?? ""
                    
                    if type == "LineString", let coords = coordinates as? [[Double]] {
                        ArizonaSpeedLimitService.addSegments(coords: coords, limit: limit, grid: &grid)
                    } else if type == "MultiLineString", let lines = coordinates as? [[[Double]]] {
                        for line in lines {
                            ArizonaSpeedLimitService.addSegments(coords: line, limit: limit, grid: &grid)
                        }
                    }
                }
                
                return grid
            }.value
            
            self.spatialGrid = resultGrid
            self.isLoaded = true
            print("[AZ Data] Successfully loaded and indexed \(resultGrid.count) spatial grid cells.")
            
        } catch {
            print("[AZ Data] Error loading geojson: \(error)")
        }
    }
    
    private static func addSegments(coords: [[Double]], limit: Int, grid: inout [String: [(CLLocationCoordinate2D, CLLocationCoordinate2D, Int)]]) {
        guard coords.count >= 2 else { return }
        
        for i in 0..<(coords.count - 1) {
            let c1 = coords[i]
            let c2 = coords[i+1]
            guard c1.count >= 2, c2.count >= 2 else { continue }
            
            let p1 = CLLocationCoordinate2D(latitude: c1[1], longitude: c1[0]) // Lat is [1], Lon is [0]
            let p2 = CLLocationCoordinate2D(latitude: c2[1], longitude: c2[0])
            
            let midLat = (p1.latitude + p2.latitude) / 2.0
            let midLon = (p1.longitude + p2.longitude) / 2.0
            
            let key = String(format: "%.2f_%.2f", midLat, midLon)
            grid[key, default: []].append((p1, p2, limit))
        }
    }
    
    public func fetchSpeedLimit(at coordinate: CLLocationCoordinate2D) async throws -> Int {
        if !isLoaded {
            throw URLError(.cannotDecodeContentData) // Or custom error
        }
        
        let searchLat = coordinate.latitude
        let searchLon = coordinate.longitude
        
        // Search current 2-decimal grid cell and the 8 neighbors
        let offsets = [-0.01, 0.0, 0.01]
        
        var closestLimit: Int?
        var minDistance: CLLocationDistance = 100 // Max 100 meters snap distance
        
        let targetLoc = CLLocation(latitude: searchLat, longitude: searchLon)
        
        for latOffset in offsets {
            for lonOffset in offsets {
                let cellLat = searchLat + latOffset
                let cellLon = searchLon + lonOffset
                let key = String(format: "%.2f_%.2f", cellLat, cellLon)
                
                guard let segments = spatialGrid[key] else { continue }
                
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
    
    // Cross-track distance point-to-line segment in meters (approximate)
    private func distanceToSegment(target: CLLocationCoordinate2D, p1: CLLocationCoordinate2D, p2: CLLocationCoordinate2D) -> CLLocationDistance {
        // Convert to meters using equirectangular approximation
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
            xx = x1
            yy = y1
        } else if param > 1 {
            xx = x2
            yy = y2
        } else {
            xx = x1 + param * C
            yy = y1 + param * D
        }
        
        let dx = x0 - xx
        let dy = y0 - yy
        return sqrt(dx * dx + dy * dy)
    }
}
