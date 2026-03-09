// Path: Core/HEREService.swift
import Foundation
import CoreLocation

@MainActor
public class HEREService {
    public static let shared = HEREService()
    
    private init() {}
    
    public func fetchSpeedLimit(at coordinate: CLLocationCoordinate2D) async -> Int? {
        let apiKey = Config.hereApiKey
        guard !apiKey.isEmpty else {
            print("[HEREService] No API Key provided.")
            return nil
        }
        
        // GET https://routematching.hereapi.com/v8/match/json?apiKey={key}&path={lat},{lng}&speedlimit=true
        var components = URLComponents(string: "https://routematching.hereapi.com/v8/match/json")
        components?.queryItems = [
            URLQueryItem(name: "apiKey", value: apiKey),
            URLQueryItem(name: "path", value: "\(coordinate.latitude),\(coordinate.longitude)"),
            URLQueryItem(name: "speedlimit", value: "true")
        ]
        
        guard let url = components?.url else { return nil }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 3.0 // Low latency goal
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let routeLinks = json["routeLinks"] as? [[String: Any]],
               let link = routeLinks.first,
               let speedLimitObj = link["attributes"] as? [String: Any]? ?? link, // HERE API shape varies, simplified fallback check
               let speedLimit = (speedLimitObj["SPEED_LIMIT"] ?? speedLimitObj["speedLimit"]) as? Double {
                
                // Value is typically in m/s or km/h based on mode, but default is km/h
                // "The returned speed limit is in meters per second (m/s)." per some v1/v8 docs, but actually, 
                // in match json it's often in km/h. To be safe, follow PRD instruction:
                // Parse response for speedLimit field (value in km/h, convert to mph: * 0.621371).
                
                let mph = speedLimit * 0.621371
                return Int(round(mph))
            }
        } catch {
            print("[HEREService] Error: \(error.localizedDescription)")
            return nil
        }
        
        return nil
    }
    
    public func fetchRoadName(at coordinate: CLLocationCoordinate2D) async -> String? {
        // Dummy implementation to parallel fetching name for verification. In a real HERE request,
        // road name is often fetched concurrently or returned in the same payload.
        let apiKey = Config.hereApiKey
        var components = URLComponents(string: "https://routematching.hereapi.com/v8/match/json")
        components?.queryItems = [
            URLQueryItem(name: "apiKey", value: apiKey),
            URLQueryItem(name: "path", value: "\(coordinate.latitude),\(coordinate.longitude)"),
            URLQueryItem(name: "attributes", value: "LINK_FCN(ROAD_NAME)")
        ]
        
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3.0
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let links = json["routeLinks"] as? [[String: Any]],
               let tags = links.first?["attributes"] as? [String: Any] {
                return tags["ROAD_NAME"] as? String ?? tags["roadName"] as? String
            }
        } catch {
            return nil
        }
        return nil
    }
}
