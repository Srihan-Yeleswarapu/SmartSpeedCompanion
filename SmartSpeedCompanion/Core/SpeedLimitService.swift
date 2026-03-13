// SpeedLimitService.swift
import Foundation
import CoreLocation
import Combine

struct TimeoutError: Error {}

public protocol SpeedLimitProviding {
    func fetchSpeedLimit(at coordinate: CLLocationCoordinate2D) async throws -> Int
}

public class OpenStreetMapSpeedLimitService {
    private let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    private var lastQueryTime: Date = .distantPast
    private var cachedLimit: Int?
    private var lastCoordinate: CLLocationCoordinate2D?
    
    public init() {}
    
    public func fetchSpeedLimit(at coordinate: CLLocationCoordinate2D) async throws -> Int {
        // Cache invalidation logic
        if let lastCoord = lastCoordinate, let limit = cachedLimit {
            let location1 = CLLocation(latitude: lastCoord.latitude, longitude: lastCoord.longitude)
            let location2 = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if location1.distance(from: location2) < 25.0 && Date().timeIntervalSince(lastQueryTime) < 10 {
                return limit
            }
        }
        
        let query = """
        [out:json][timeout:5];
        way(around:25,\(coordinate.latitude),\(coordinate.longitude))[maxspeed];
        out tags;
        """
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = query.data(using: .utf8)
        request.timeoutInterval = 5.0
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        if let responseString = String(data: data, encoding: .utf8) {
            print("[OSM] Raw response: \(responseString)")
        }
        
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let elements = json["elements"] as? [[String: Any]],
               let firstWay = elements.first,
               let tags = firstWay["tags"] as? [String: String],
               let maxSpeedStr = tags["maxspeed"] {
                
                if let limit = parseMaxSpeed(maxSpeedStr) {
                    print("[OSM] Parsed limit: \(limit) from tag: \(maxSpeedStr)")
                    
                    cachedLimit = limit
                    lastCoordinate = coordinate
                    lastQueryTime = Date()
                    
                    return limit
                }
            }
        } catch {
            print("[OSM] Parse error: \(error)")
        }
        
        throw URLError(.cannotParseResponse)
    }
    
    private func parseMaxSpeed(_ speedStr: String) -> Int? {
        let lower = speedStr.lowercased().trimmingCharacters(in: .whitespaces)
        if lower == "national" || lower == "urban" { return nil }
        
        if lower.hasSuffix("mph") {
            let numStr = lower.replacingOccurrences(of: "mph", with: "").trimmingCharacters(in: .whitespaces)
            return Int(numStr)
        } else if lower.hasSuffix("km/h") || lower.hasSuffix("kph") {
            let numStr = lower.replacingOccurrences(of: "km/h", with: "").replacingOccurrences(of: "kph", with: "").trimmingCharacters(in: .whitespaces)
            if let kph = Double(numStr) { return Int(kph * 0.621371) }
        } else {
            return Int(lower)
        }
        return nil
    }
}

public class PrototypeSpeedLimitService {
    public init() {}
    public func estimateLimit(for currentMph: Double) -> Int {
        if currentMph < 30 {
            return 25 // 25 mph zone
        } else if currentMph <= 55 {
            return 45 // 45 mph zone
        } else {
            return 65 // 65 mph zone
        }
    }
}

@MainActor
public class SmartSpeedLimitService: ObservableObject {
    public static let shared = SmartSpeedLimitService()
    
    @Published public var currentLimit: Int = 25
    @Published public var dataSource: String = "Estimating..."
    
    private let osmService = OpenStreetMapSpeedLimitService()
    private let fallbackService = PrototypeSpeedLimitService()
    
    private init() {}
    
    public func updateSpeedLimit(at coordinate: CLLocationCoordinate2D, currentSpeedMph: Double) async -> Int {
        // 1. Try Local Arizona GeoJSON Data First
        do {
            let localLimit = try await ArizonaSpeedLimitService.shared.fetchSpeedLimit(at: coordinate)
            self.currentLimit = localLimit
            self.dataSource = "Local Map"
            return localLimit
        } catch {
            // Local AZ file didn't have it or isn't loaded yet. Proceed to OSM.
        }
        
        // 2. Fallback to OpenStreetMap Overpass API
        do {
            let limit = try await withThrowingTaskGroup(of: Int.self) { group in
                group.addTask {
                    try await self.osmService.fetchSpeedLimit(at: coordinate)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    throw TimeoutError()
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            
            self.currentLimit = limit
            self.dataSource = "OpenStreetMap"
            return limit
            
        } catch {
            print("[OSM] Fetch failed or timed out: \(error), falling back to prototype.")
            // 3. Fallback to Generic Estimation
            let limit = fallbackService.estimateLimit(for: currentSpeedMph)
            self.currentLimit = limit
            self.dataSource = "Estimated"
            return limit
        }
    }
}
