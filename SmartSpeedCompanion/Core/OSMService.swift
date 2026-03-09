// Path: Core/OSMService.swift
import Foundation
import CoreLocation

public struct OSMResult {
    public let speedLimit: Int?
    public let roadName: String
    public let wayID: String
}

@MainActor
public class OSMService {
    public static let shared = OSMService()
    
    private let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    
    private init() {}
    
    public func fetchOSMData(at coordinate: CLLocationCoordinate2D) async -> OSMResult? {
        // [out:json][timeout:5];way(around:25,LAT,LNG)[maxspeed];out tags;
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
               let id = firstWay["id"] as? Int,
               let tags = firstWay["tags"] as? [String: String] {
                
                let wayID = String(id)
                let name = tags["name"] ?? ""
                let rawMaxSpeed = tags["maxspeed"]
                
                let speedLimit = parseMaxSpeed(rawMaxSpeed)
                
                return OSMResult(speedLimit: speedLimit, roadName: name, wayID: wayID)
            }
        } catch {
            print("[OSMService] Error: \(error.localizedDescription)")
            return nil
        }
        return nil
    }
    
    public func fuzzyMatchNames(_ name1: String?, _ name2: String?) -> Bool {
        guard let n1 = name1, let n2 = name2, !n1.isEmpty, !n2.isEmpty else { return false }
        let stripped1 = stripCommonWords(from: n1)
        let stripped2 = stripCommonWords(from: n2)
        return stripped1.contains(stripped2) || stripped2.contains(stripped1)
    }
    
    private func stripCommonWords(from name: String) -> String {
        var n = name.lowercased()
        n = n.replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
        let removals = ["st", "street", "ave", "avenue", "blvd", "boulevard", "dr", "drive", "rd", "road"]
        for word in removals {
            if n.hasSuffix(word) {
                n.removeLast(word.count)
            } else if n.hasPrefix(word) {
                n.removeFirst(word.count)
            }
        }
        return n
    }
    
    private func parseMaxSpeed(_ speedStr: String?) -> Int? {
        guard let speedStr = speedStr else { return nil }
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
