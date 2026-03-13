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
    
    // Navigation state
    @Published public var isNavigating: Bool = false
    @Published public var currentRoute: MKRoute? = nil
    @Published public var destination: MKMapItem? = nil
    @Published public var searchResults: [MKMapItem] = []
    @Published public var searchCompletions: [MKLocalSearchCompletion] = []
    @Published public var isSearching: Bool = false
    
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

        super.init()

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
            }
    }
    
    public func endSession() {
        _ = sessionRecorder.endSession()
        
        sessionTimer?.cancel()
        sessionTimer = nil
        sessionDuration = 0
        sessionStartTime = nil
    }
    
    // Navigation controls  
    public func startNavigation(to destination: MKMapItem) async {
        self.destination = destination
        self.isNavigating = true
        // If there's a specific route calculation needed locally, perform it.
        // Or proxy it to CarPlay navigation delegate if active:
        await navigationDelegate?.startNavigationTrigger(to: destination)
    }
    
    public func endNavigation() async {
        self.isNavigating = false
        self.destination = nil
        self.currentRoute = nil
        await navigationDelegate?.endNavigationTrigger()
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
    func startNavigationTrigger(to destination: MKMapItem) async
    func endNavigationTrigger() async
    func searchDestinationTrigger(_ query: String) async -> [MKMapItem]
}
