import Foundation
import CoreLocation

public struct SpeedCamera: Codable, Identifiable, Sendable {
    public let id: Int
    public let source: String?
    public let sourceId: String?
    public let roadway: String?
    public let direction: String?
    public let latitude: Double
    public let longitude: Double
    public let location: String?
    public let sortOrder: Int?
    
    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case source = "Source"
        case sourceId = "SourceId"
        case roadway = "Roadway"
        case direction = "Direction"
        case latitude = "Latitude"
        case longitude = "Longitude"
        case location = "Location"
        case sortOrder = "SortOrder"
    }
}

@MainActor
public class SpeedCameraService: ObservableObject {
    public static let shared = SpeedCameraService()
    
    @Published public var cameras: [SpeedCamera] = []
    
    private let apiKey = "329a6edfe2f7439f9dd57dcf69c6d872"
    private let baseURL = "https://az511.com/api/v2/get/cameras"
    
    private init() {}
    
    public func fetchCameras() async {
        guard let url = URL(string: "\(baseURL)?key=\(apiKey)&format=json") else {
            print("Invalid URL")
            return
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("Invalid response")
                return
            }
            
            let decoder = JSONDecoder()
            let fetchedCameras = try decoder.decode([SpeedCamera].self, from: data)
            
            DispatchQueue.main.async {
                self.cameras = fetchedCameras
            }
        } catch {
            print("Error fetching cameras: \(error)")
        }
    }
    
    public func getNearbyCameras(to location: CLLocation, radiusInMeters: Double = 5000) -> [SpeedCamera] {
        return cameras.filter { camera in
            let cameraLocation = CLLocation(latitude: camera.latitude, longitude: camera.longitude)
            let distance = location.distance(from: cameraLocation)
            return distance <= radiusInMeters
        }
    }
}
