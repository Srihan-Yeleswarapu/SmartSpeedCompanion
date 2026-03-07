// SpeedLimitService.swift
// Fetches real speed limit data from OpenStreetMap Overpass API.
// Falls back to prototype estimation if no data found within 5 seconds.

import Foundation
import CoreLocation
import Combine

public protocol SpeedLimitProviding {
    func fetchSpeedLimit(at coordinate: CLLocationCoordinate2D) async -> Int?
}

public class OpenStreetMapSpeedLimitService: SpeedLimitProviding {
    private let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    private var lastQueryTime: Date = .distantPast
    private var cachedLimit: Int?
    private var cachedCoordinateString: String = ""
    
    public init() {}
    
    public func fetchSpeedLimit(at coordinate: CLLocationCoordinate2D) async -> Int? {
        let latStr = String(format: "%.4f", coordinate.latitude)
        let lonStr = String(format: "%.4f", coordinate.longitude)
        let coordHash = "\(latStr),\(lonStr)"
        
        // Cache for 10 seconds or if coordinate is identical at 4 decimal places (~11m precision)
        if coordHash == cachedCoordinateString && Date().timeIntervalSince(lastQueryTime) < 10 {
            return cachedLimit
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
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let elements = json["elements"] as? [[String: Any]],
               let firstWay = elements.first,
               let tags = firstWay["tags"] as? [String: String],
               let maxSpeedStr = tags["maxspeed"] {
                
                let limit = parseMaxSpeed(maxSpeedStr)
                
                cachedLimit = limit
                cachedCoordinateString = coordHash
                lastQueryTime = Date()
                
                return limit
            }
        } catch {
            print("OSM Overpass API Error: \(error)")
        }
        
        return nil
    }
    
    private func parseMaxSpeed(_ speedStr: String) -> Int? {
        let lower = speedStr.lowercased().trimmingCharacters(in: .whitespaces)
        
        if lower == "national" || lower == "urban" {
            return nil
        }
        
        if lower.hasSuffix("mph") {
            let numStr = lower.replacingOccurrences(of: "mph", with: "").trimmingCharacters(in: .whitespaces)
            return Int(numStr)
        } else if lower.hasSuffix("km/h") || lower.hasSuffix("kph") {
            let numStr = lower.replacingOccurrences(of: "km/h", with: "").replacingOccurrences(of: "kph", with: "").trimmingCharacters(in: .whitespaces)
            if let kph = Double(numStr) {
                return Int(kph * 0.621371)
            }
        } else {
            // Assume plain number is mph per US norms, or just pare it directly
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
        if let limit = await osmService.fetchSpeedLimit(at: coordinate) {
            self.currentLimit = limit
            self.dataSource = "OpenStreetMap"
            return limit
        } else {
            let limit = fallbackService.estimateLimit(for: currentSpeedMph)
            self.currentLimit = limit
            self.dataSource = "Estimated"
            return limit
        }
    }
}
