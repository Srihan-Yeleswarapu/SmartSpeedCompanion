// Path: ViewModels/DriveViewModel.swift
import Foundation
import Combine
import SwiftData
import MapKit

@MainActor
public final class DriveViewModel: ObservableObject {
    // Speed
    @Published public var speed: Double = 0.0
    @Published public var limit: Int = 25
    @Published public var status: SpeedStatus = .safe
    @Published public var limitSource: LimitSource = .estimating

    // Session
    @Published public var isRecording: Bool = false
    @Published public var sessionDuration: TimeInterval = 0
    @Published public var currentSession: DriveSession? = nil

    // Navigation
    @Published public var isNavigating: Bool = false
    @Published public var currentRoute: MKRoute? = nil
    @Published public var alternativeRoutes: [MKRoute] = []
    @Published public var destination: MKMapItem? = nil
    @Published public var nextManeuverInstruction: String = ""
    @Published public var eta: Date? = nil
    @Published public var remainingDistance: CLLocationDistance = 0
    @Published public var isRerouting: Bool = false
    @Published public var nextManeuverDistance: String = "" 
    @Published public var distanceToNextTurn: String = ""

    // Search
    @Published public var searchResults: [MKMapItem] = []
    @Published public var isSearching: Bool = false

    // Premium
    @Published public var isPremium: Bool = false

    // Verify prompt
    @Published public var showVerifyPrompt: Bool = false
    
    // Core Dependencies
    public let locationManager: LocationManager
    public let sessionRecorder: SessionRecorder
    public let alertEngine: AlertEngine
    private let navigationEngine = NavigationEngine.shared
    
    private var sessionStartTime: Date? = nil
    private var sessionTimer: AnyCancellable? = nil
    private var cancellables = Set<AnyCancellable>()
    
    private var lastStableLimit: Int?
    private var stableLimitSeconds: Int = 0
    private var stableLimitTimer: AnyCancellable?

    public init(modelContext: ModelContext? = nil) {
        let locManager = LocationManager()
        let recorder = SessionRecorder(locationManager: locManager)
        
        self.locationManager = locManager
        self.sessionRecorder = recorder
        
        if let ctx = modelContext {
            recorder.setModelContext(ctx)
        }
        
        // We create a subject that emits status changes for AlertEngine
        let statusSubject = CurrentValueSubject<SpeedStatus, Never>(.safe)
        self.alertEngine = AlertEngine(statusPublisher: statusSubject.eraseToAnyPublisher())
        
        // Bind SpeedLimitBrain limit
        SpeedLimitBrain.shared.$currentLimit
            .receive(on: RunLoop.main)
            .assign(to: &$limit)
            
        SpeedLimitBrain.shared.$limitSource
            .receive(on: RunLoop.main)
            .assign(to: &$limitSource)
            
        // Observe internal status changes to feed AlertEngine
        $status
            .dropFirst()
            .sink { newStatus in
                statusSubject.send(newStatus)
            }
            .store(in: &cancellables)
            
        // Calculate status dynamically
        Publishers.CombineLatest($speed, SpeedLimitBrain.shared.$currentLimit)
            .receive(on: RunLoop.main)
            .sink { [weak self] currentSpeed, currentLimit in
                guard let self = self else { return }
                let threshold = Double(currentLimit + 5) // Hardcoded 5mph buffer for MVP
                if currentSpeed > threshold {
                    self.status = .over
                } else if currentSpeed > (threshold - 2.0) {
                    self.status = .warning
                } else {
                    self.status = .safe
                }
            }
            .store(in: &cancellables)
            
        // Update speed from location manager
        locManager.$latestLocation
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] location in
                guard let self = self else { return }
                let rawSpeed = max(0, location.speed * 2.23694)
                // Filter low noise
                self.speed = rawSpeed < 1.0 ? 0.0 : round(rawSpeed)
                
                if self.isNavigating {
                    self.navigationEngine.updateProgress(location: location)
                }
            }
            .store(in: &cancellables)
            
        // Bind NavigationEngine state
        navigationEngine.$currentRoute.assign(to: &$currentRoute)
        navigationEngine.$alternativeRoutes.assign(to: &$alternativeRoutes)
        navigationEngine.$nextManeuverInstruction.assign(to: &$nextManeuverInstruction)
        navigationEngine.$nextManeuverDistance.assign(to: &$nextManeuverDistance)
        navigationEngine.$eta.assign(to: &$eta)
        navigationEngine.$remainingDistance.assign(to: &$remainingDistance)
        navigationEngine.$isRerouting.assign(to: &$isRerouting)
        
        setupFlagPromptLogic()
        
        locManager.requestAuthorization()
        locManager.startUpdatingLocation()
    }

    public func configureModelContext(_ context: ModelContext) {
        sessionRecorder.setModelContext(context)
    }

    
    private func setupFlagPromptLogic() {
        // Only show "correct?" flag after displaying stable limit for 5s
        SpeedLimitBrain.shared.$currentLimit
            .receive(on: RunLoop.main)
            .sink { [weak self] newLimit in
                guard let self = self else { return }
                if self.lastStableLimit != newLimit {
                    self.lastStableLimit = newLimit
                    self.stableLimitSeconds = 0
                }
            }
            .store(in: &cancellables)
            
        stableLimitTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.stableLimitSeconds += 1
                if self.stableLimitSeconds >= 5 {
                    self.showVerifyPrompt = true
                } else {
                    self.showVerifyPrompt = false
                }
            }
    }
    
    public func startSession() {
        sessionRecorder.startSession()
        isRecording = true
        
        sessionStartTime = Date()
        sessionTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let start = self?.sessionStartTime else { return }
                self?.sessionDuration = Date().timeIntervalSince(start)
            }
    }
    
    public func endSession() {
        if let session = sessionRecorder.endSession() {
            currentSession = session
        }
        isRecording = false
        sessionTimer?.cancel()
        sessionTimer = nil
        sessionDuration = 0
        sessionStartTime = nil
    }
    
    public func searchDestination(query: String) async {
        isSearching = true
        let region = MKCoordinateRegion(
            center: locationManager.latestLocation?.coordinate ?? CLLocationCoordinate2D(latitude: 33.4, longitude: -111.9),
            latitudinalMeters: 50000,
            longitudinalMeters: 50000
        )
        searchResults = await navigationEngine.search(query: query, region: region)
        isSearching = false
    }
    
    public func startNavigation(to destination: MKMapItem) async {
        self.destination = destination
        self.isNavigating = true
        guard let location = locationManager.latestLocation else { return }
        let startItem = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
        await navigationEngine.calculateRoute(from: startItem, to: destination)
    }
    
    public func endNavigation() {
        isNavigating = false
        destination = nil
        currentRoute = nil
        navigationEngine.currentRoute = nil
    }
}


