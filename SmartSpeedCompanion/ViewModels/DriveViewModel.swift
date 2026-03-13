import Foundation
import Combine
import SwiftData
import MapKit

/// Main observable view model that combines LocationManager, SpeedEngine, AlertEngine, and SessionRecorder.
@MainActor
public final class DriveViewModel: NSObject, ObservableObject {
    public let locationManager: LocationManager
    public let speedEngine: SpeedEngine
    public let alertEngine: AlertEngine
    public let sessionRecorder: SessionRecorder
    
    // Core driving state
    @Published public var speed: Double = 0.0
    @Published public var limit: Int = 25
    @Published public var status: SpeedStatus = .safe
    @Published public var isRecording: Bool = false
    @Published public var sessionDuration: TimeInterval = 0
    @Published public var alertActive: Bool = false
    @Published public var speedLimitSource: String = "Estimating..."
    @Published public var nearbyCameras: [SpeedCamera] = []
    @Published public var activeCameraAlert: SpeedCamera? = nil
    // Navigation state
    @Published public var isNavigating: Bool = false
    @Published public var currentRoute: MKRoute? = nil
    @Published public var destination: MKMapItem? = nil
    @Published public var searchResults: [MKMapItem] = []
    @Published public var searchCompletions: [MKLocalSearchCompletion] = []
    @Published public var isSearching: Bool = false
    @Published public var recentSearches: [String] = []
    
    // Route Selection State
    @Published public var isSelectingRoute: Bool = false
    @Published public var availableRoutes: [MKRoute] = []

    
    // Guidance details
    @Published public var nextManeuverInstruction: String = ""
    @Published var nextManeuverImageName: String = "arrow.up"
    @Published public var distanceToNextTurn: CLLocationDistance = 0
    @Published public var eta: Date? = nil
    
    // Search Completer
    private let completer = MKLocalSearchCompleter()
    
    // Timer properties
    private var sessionStartTime: Date? = nil
    private var sessionTimer: AnyCancellable? = nil
    
    private var cancellables = Set<AnyCancellable>()
    // A weak reference or delegate will handle actual logic in CarPlay layer
    public var navigationDelegate: NavigationActionDelegate?
    
    public init(modelContext: ModelContext? = nil) {
        let locManager = LocationManager()
        let spdEngine = SpeedEngine(locationManager: locManager)
        let alrtEngine = AlertEngine(speedEngine: spdEngine)
        let rec = SessionRecorder(speedEngine: spdEngine, locationManager: locManager)
        
        if let ctx = modelContext {
            rec.setModelContext(ctx)
        }
        
        self.locationManager = locManager
        self.speedEngine = spdEngine
        self.alertEngine = alrtEngine
        self.sessionRecorder = rec
        self.recentSearches = UserDefaults.standard.stringArray(forKey: "recentSearches") ?? []

        super.init()

        // Fetch cameras
        Task {
            await SpeedCameraService.shared.fetchCameras()
        }

        // Setup Completer

        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
        
        // Bind UI state
        spdEngine.$speed.assign(to: &$speed)
        SmartSpeedLimitService.shared.$currentLimit.assign(to: &$limit)
        spdEngine.$status.assign(to: &$status)
        alrtEngine.$audioAlertActive.assign(to: &$alertActive)
        rec.$isRecording.assign(to: &$isRecording)
        
        // Bind Data Source
        SmartSpeedLimitService.shared.$dataSource
            .receive(on: RunLoop.main)
            .assign(to: &$speedLimitSource)
        
        // Request Location Authorization
        locManager.requestAuthorization()
        locManager.startUpdatingLocation()
        
        // Listen to location updates for nearby cameras
        locManager.$latestLocation
            .compactMap { $0 }
            .sink { [weak self] location in
                if let self = self {
                    let cameras = SpeedCameraService.shared.getNearbyCameras(to: location)
                    self.nearbyCameras = cameras
                    
                    // Alert if a camera is within 1000 meters
                    self.activeCameraAlert = cameras.first { camera in
                        let camLoc = CLLocation(latitude: camera.latitude, longitude: camera.longitude)
                        return location.distance(from: camLoc) <= 1000
                    }
                    
                    if self.isNavigating {
                        self.updateNavigationProgress(at: location)
                        self.updateLiveActivity()
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    public func startSession() {
        sessionRecorder.startSession()
        
        // Timer tracking
        sessionStartTime = Date()
        sessionTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let start = self?.sessionStartTime else { return }
                self?.sessionDuration = Date().timeIntervalSince(start)
                self?.updateLiveActivity()
            }
        
        LiveActivityManager.shared.startActivity(sessionStartDate: sessionStartTime ?? Date())
    }
    
    private func updateLiveActivity() {
        if #available(iOS 16.1, *) {
            let state = SpeedActivityAttributes.ContentState(
                speed: speed,
                speedLimit: limit,
                status: status.rawValue,
                isRecording: isRecording,
                consecutiveOverSeconds: 0, // Should be tracked in SpeedEngine
                sessionDuration: sessionDuration,
                nextManeuver: isNavigating ? nextManeuverInstruction : nil,
                nextManeuverImageName: isNavigating ? nextManeuverImageName : nil,
                distanceToNextTurn: isNavigating ? distanceToNextTurn : nil,
                eta: isNavigating ? eta : nil
            )
            LiveActivityManager.shared.updateActivity(with: state)
        }
    }
    
    public func endSession() {
        _ = sessionRecorder.endSession()
        
        sessionTimer?.cancel()
        sessionTimer = nil
        sessionStartTime = nil
        
        if !isNavigating {
            LiveActivityManager.shared.endActivity()
        }
    }
    
    public func selectDestinationAndCalculateRoutes(to destination: MKMapItem) async {
        self.destination = destination
        saveRecentSearch(destination.name ?? "Unknown Location")
        
        let request = MKDirections.Request()
        request.source = MKMapItem.forCurrentLocation()
        request.destination = destination
        request.transportType = .automobile
        request.requestsAlternateRoutes = true
        
        if UserDefaults.standard.bool(forKey: "avoidHighways") {
            request.highwayPreference = .avoid
        }
        
        do {
            let directions = MKDirections(request: request)
            let response = try await directions.calculate()
            self.availableRoutes = response.routes
            self.isSelectingRoute = true
        } catch {
            print("Route error: \(error)")
        }
    }
    
    public func startNavigation(with route: MKRoute) async {
        self.isSelectingRoute = false
        self.isNavigating = true
        self.currentRoute = route
        if let dest = self.destination {
            await navigationDelegate?.startNavigationTrigger(to: dest, route: route)
        }
        
        if #available(iOS 16.1, *) {
            LiveActivityManager.shared.startActivity(sessionStartDate: Date())
            updateLiveActivity()
        }
    }
    
    public func startNavigation(to destination: MKMapItem) async {
        self.destination = destination
        self.isNavigating = true
        await navigationDelegate?.startNavigationTrigger(to: destination, route: nil)
    }
    
    public func saveRecentSearch(_ title: String) {
        if !recentSearches.contains(title) {
            recentSearches.insert(title, at: 0)
            if recentSearches.count > 10 {
                recentSearches.removeLast()
            }
            UserDefaults.standard.set(recentSearches, forKey: "recentSearches")
        }
    }

    
    public func endNavigation() async {
        self.isNavigating = false
        self.currentRoute = nil
        await navigationDelegate?.endNavigationTrigger()
        
        if !isRecording {
            LiveActivityManager.shared.endActivity()
        }
    }
    
    // Search completions update
    public func updateSearchQuery(_ query: String) {
        if query.isEmpty {
            searchCompletions = []
            searchResults = []
            return
        }
        
        if let userLocation = locationManager.latestLocation {
            completer.region = MKCoordinateRegion(
                center: userLocation.coordinate,
                latitudinalMeters: 50000,
                longitudinalMeters: 50000
            )
        }
        completer.queryFragment = query
    }
    
    // Resolve completion to MKMapItem
    public func selectCompletion(_ completion: MKLocalSearchCompletion) async {
        let searchRequest = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: searchRequest)
        
        do {
            let response = try await search.start()
            if let first = response.mapItems.first {
                searchResults = [first]
                // Typically would auto-start navigation or show detail
            }
        } catch {
            print("Failed to resolve completion: \(error)")
        }
    }
    
    public func searchDestination(query: String) async {
        guard !query.isEmpty else { searchResults = []; return }
        isSearching = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let userLocation = locationManager.latestLocation {
            request.region = MKCoordinateRegion(
                center: userLocation.coordinate,
                latitudinalMeters: 50000,
                longitudinalMeters: 50000
            )
        }
        let search = MKLocalSearch(request: request)
        do {
            let response = try await search.start()
            searchResults = Array(response.mapItems.prefix(5))
        } catch {
            searchResults = []
        }
        isSearching = false
    }
    
    public func searchDestinationTrigger(_ query: String) async -> [MKMapItem] {
        return await navigationDelegate?.searchDestinationTrigger(query) ?? []
    }
    
    private func updateNavigationProgress(at location: CLLocation) {
        guard let route = currentRoute else { return }
        
        // Find the next step
        // A simple logic: find the first step whose distance from current location is 'ahead' or just use the steps in order
        // For a real app, we'd use a more robust map-matching algorithm
        
        let steps = route.steps
        var upcomingStep: MKRoute.Step?
        
        for step in steps {
            let stepLocation = CLLocation(latitude: step.polyline.coordinate.latitude, longitude: step.polyline.coordinate.longitude)
            let distanceToStep = location.distance(from: stepLocation)
            
            // If we are more than 50 meters from the step, it's likely upcoming
            if distanceToStep > 50 {
                upcomingStep = step
                self.distanceToNextTurn = distanceToStep
                break
            }
        }
        
        if let step = upcomingStep {
            self.nextManeuverInstruction = step.instructions
            self.nextManeuverImageName = getImageForManeuver(step.instructions)
        }
        
        // Simple ETA calculation: distance / speed (or just use route.expectedTravelTime)
        // For simulation, we'll just subtract some time from the initial ETA
        if self.eta == nil {
            self.eta = Date().addingTimeInterval(route.expectedTravelTime)
        }
    }
    
    private func getImageForManeuver(_ instruction: String) -> String {
        let lower = instruction.lowercased()
        if lower.contains("right") { return "arrow.turn.up.right" }
        if lower.contains("left") { return "arrow.turn.up.left" }
        if lower.contains("slight right") { return "arrow.up.right" }
        if lower.contains("slight left") { return "arrow.up.left" }
        if lower.contains("keep right") { return "arrow.up.right" }
        if lower.contains("keep left") { return "arrow.up.left" }
        if lower.contains("u-turn") { return "arrow.uturn.left" }
        if lower.contains("exit") { return "arrow.up.right.square" }
        if lower.contains("merge") { return "arrow.merge" }
        return "arrow.up"
    }
}

extension DriveViewModel: @preconcurrency MKLocalSearchCompleterDelegate {
    public func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        self.searchCompletions = completer.results
    }
    
    public func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        print("Completer error: \(error)")
    }
}

public protocol NavigationActionDelegate: AnyObject {
    func startNavigationTrigger(to destination: MKMapItem, route: MKRoute?) async
    func endNavigationTrigger() async
    func searchDestinationTrigger(_ query: String) async -> [MKMapItem]
}
