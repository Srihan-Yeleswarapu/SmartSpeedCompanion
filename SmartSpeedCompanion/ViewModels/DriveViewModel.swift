import Foundation
import Combine
import SwiftData
import MapKit
import ActivityKit
import AVFoundation
import UIKit

/// Main observable view model that combines LocationManager, SpeedEngine, AlertEngine, and SessionRecorder.
@MainActor
public final class DriveViewModel: NSObject, ObservableObject {
    public let locationManager: LocationManager
    public let speedEngine: SpeedEngine
    public let alertEngine: AlertEngine
    public let sessionRecorder: SessionRecorder
    
    // Core driving state
    @Published public var speed: Double = 0.0
    @Published public var currentHeading: Double? = nil
    @Published public var limit: Int = 0
    @Published public var status: SpeedStatus = .safe
    @Published public var isRecording: Bool = false {
        didSet { updateIdleTimer() }
    }
    @Published public var sessionDuration: TimeInterval = 0
    @Published public var alertActive: Bool = false
    @Published public var speedLimitSource: String = "No Data"
    @Published public var nearbyCameras: [SpeedCamera] = []
    @Published public var activeCameraAlert: SpeedCamera? = nil
    // Navigation state
    @Published public var isNavigating: Bool = false {
        didSet { updateIdleTimer() }
    }
    @Published public var currentRoute: MKRoute? = nil
    @Published public var destination: MKMapItem? = nil
    @Published public var searchResults: [MKMapItem] = []
    @Published public var searchCompletions: [MKLocalSearchCompletion] = []
    @Published public var isSearching: Bool = false
    @Published public var isSearchingLocally: Bool = false
    @Published public var recentSearches: [String] = []
    
    // Route Selection State
    @Published public var isSelectingRoute: Bool = false
    @Published public var availableRoutes: [MKRoute] = []
    
    // Map Interaction State
    @Published public var isMapDetached: Bool = false
    
    // Deletion states
    @Published public var showShortSessionPrompt: Bool = false
    public var lastSessionToPotentialDelete: DriveSession? = nil

    
    // Guidance details
    @Published public var nextManeuverInstruction: String = ""
    @Published var nextManeuverImageName: String = "arrow.up"
    @Published public var distanceToNextTurn: CLLocationDistance = 0
    @Published public var eta: Date? = nil
    
    // Search Completer
    private let completer = MKLocalSearchCompleter()
    
    private let speechSynthesizer = AVSpeechSynthesizer()
    
    // Timer properties
    private var sessionStartTime: Date? = nil
    private var sessionTimer: AnyCancellable? = nil
    private var currentStepIndex: Int = 0
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
        
        // Load Local Arizona Geodatabase Data
        Task {
            await ArizonaSpeedLimitService.shared.loadDataIfNeeded()
        }

        // Setup Audio Session once
        setupAudioSession()

        // Setup Completer

        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
        
        // Bind UI state
        // Use course for heading when moving > 5mph for stability, fall back to compass
        Publishers.CombineLatest(locManager.$latestLocation, locManager.$latestHeading)
            .map { location, heading -> Double? in
                if let loc = location, loc.speed > 2.0 { // > ~4.5 mph
                    return loc.course >= 0 ? loc.course : heading?.trueHeading
                }
                return heading?.trueHeading
            }
            .receive(on: RunLoop.main)
            .assign(to: &$currentHeading)

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
        DebugLogger.shared.log("Drive session STARTED")
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
        DebugLogger.shared.log("Drive session ENDING (Duration: \(Int(sessionDuration))s)")
        if let session = sessionRecorder.endSession() {
            if session.durationSeconds < 90 {
                // Short trip: Prompt user before saving
                self.lastSessionToPotentialDelete = session
                self.showShortSessionPrompt = true
            } else {
                // Normal trip: Save immediately
                sessionRecorder.saveSession(session)
            }
        }
        
        sessionTimer?.cancel()
        sessionTimer = nil
        sessionStartTime = nil
        self.sessionDuration = 0
        
        if !isNavigating {
            LiveActivityManager.shared.endActivity()
            
            // Clear Arizona Speed Limit cache when session fully ends
            Task {
                await ArizonaSpeedLimitService.shared.clearCache()
            }
        }
    }
    
    public func saveLastSession() {
        if let session = lastSessionToPotentialDelete {
            sessionRecorder.saveSession(session)
            lastSessionToPotentialDelete = nil
        }
    }
    
    public func deleteLastSession(context: ModelContext) {
        // Since we stopped auto-saving short trips in endSession,
        // we just need to clear our local reference to it.
        lastSessionToPotentialDelete = nil
        showShortSessionPrompt = false
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
            DebugLogger.shared.log("Calculating routes to: \(destination.name ?? "Unknown")")
            let response = try await directions.calculate()
            self.availableRoutes = response.routes
            DebugLogger.shared.log("Found \(response.routes.count) available routes")
            self.isSelectingRoute = true
        } catch {
            DebugLogger.shared.log("Route calculation FAILED: \(error.localizedDescription)")
            print("Route error: \(error)")
        }
    }
    
    public func startNavigation(with route: MKRoute) async {
        DebugLogger.shared.log("Navigation STARTED using Route (\(Int(route.distance))m)")
        self.isSelectingRoute = false
        self.isNavigating = true
        self.currentRoute = route
        self.currentStepIndex = 0
        
        // Pre-cache speed limits along the route polyline points
        Task {
            let polylinePoints = route.polyline.points()
            let pointCount = route.polyline.pointCount
            var coordinates: [CLLocationCoordinate2D] = []
            
            // Sample points along the route (every ~20th point for performance, 
            // the service handles 3x3 grid around each)
            for i in stride(from: 0, to: pointCount, by: 20) {
                coordinates.append(polylinePoints[i].coordinate)
            }
            // Always include last
            if pointCount > 0 { coordinates.append(polylinePoints[pointCount-1].coordinate) }
            
            await ArizonaSpeedLimitService.shared.preCacheRoute(coordinates: coordinates)
        }

        if let dest = self.destination {
            await navigationDelegate?.startNavigationTrigger(to: dest, route: route)
        }
        
        // Initial instruction announcement
        if !route.steps.isEmpty {
            let firstInstruction = route.steps[0].instructions
            self.nextManeuverInstruction = firstInstruction
            self.nextManeuverImageName = getImageForManeuver(firstInstruction)
            announce("Starting navigation. \(firstInstruction)")
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
            isSearchingLocally = false
            return
        }
        
        isSearchingLocally = true
        
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
        let steps = route.steps
        
        // 1. Off-Route Detection (more accurate)
        // Check distance to the nearest point on the route polyline
        let nearestPoint = findNearestPointOnPolyline(location.coordinate, polyline: route.polyline)
        let distanceToRoute = location.distance(from: CLLocation(latitude: nearestPoint.latitude, longitude: nearestPoint.longitude))
        
        if distanceToRoute > 150 {
            DebugLogger.shared.log("OFF ROUTE: \(Int(distanceToRoute))m. Rerouting...")
            if let dest = destination {
                Task {
                    await selectDestinationAndCalculateRoutes(to: dest)
                    if let newRoute = availableRoutes.first {
                        await startNavigation(with: newRoute)
                    }
                }
            }
            return
        }

        // 2. Step Progress Tracking
        // Ensure index stays valid
        if self.currentStepIndex >= steps.count { return }
        
        let currentStep = steps[self.currentStepIndex]
        let stepPolyline = currentStep.polyline
        let pointCount = stepPolyline.pointCount
        
        if pointCount > 0 {
            // Maneuver point is the LAST point of the current step's polyline
            let maneuverPoint = stepPolyline.points()[pointCount - 1].coordinate
            let maneuverLocation = CLLocation(latitude: maneuverPoint.latitude, longitude: maneuverPoint.longitude)
            let distanceToTurn = location.distance(from: maneuverLocation)
            
            self.distanceToNextTurn = distanceToTurn
            
            // UI should show the NEXT maneuver
            if self.currentStepIndex + 1 < steps.count {
                let nextStep = steps[self.currentStepIndex + 1]
                let instruction = nextStep.instructions
                
                if self.nextManeuverInstruction != instruction {
                    self.nextManeuverInstruction = instruction
                    self.nextManeuverImageName = getImageForManeuver(instruction)
                }
                
                // Voice Announcements (multi-stage)
                // 1. Initial (at 1000m)
                // 2. Final (at 150m)
                let turnInMeters = Int(distanceToTurn)
                if turnInMeters == 1000 || turnInMeters == 1001 { // Loose window
                    announce("In one kilometer, \(instruction)")
                } else if turnInMeters == 150 || turnInMeters == 151 {
                    announce("In 150 meters, \(instruction)")
                }
            } else {
                // Approaching destination
                self.nextManeuverInstruction = "Arriving at Destination"
                self.nextManeuverImageName = "mappin.and.ellipse"
            }
            
            if distanceToTurn < 30 {
                self.currentStepIndex += 1
                if self.currentStepIndex < steps.count {
                    let newStep = steps[self.currentStepIndex]
                    announce(newStep.instructions) // Announce the maneuver JUST as it happens
                } else if let dest = destination?.placemark.location, 
                          location.distance(from: dest) < 50 {
                    Task { await self.endNavigation() }
                }
            }
        }
        
        // Simple ETA calculation
        if self.eta == nil {
            self.eta = Date().addingTimeInterval(route.expectedTravelTime)
        }
    }
    
    // Helper to find nearest point on polyline to a coordinate
    private func findNearestPointOnPolyline(_ coord: CLLocationCoordinate2D, polyline: MKPolyline) -> CLLocationCoordinate2D {
        let points = polyline.points()
        let count = polyline.pointCount
        if count == 0 { return coord }
        if count == 1 { return points[0].coordinate }
        
        var minDistance = CLLocationDistance.infinity
        var closest = points[0].coordinate
        
        for i in 0..<count - 1 {
            let p1 = points[i].coordinate
            let p2 = points[i+1].coordinate
            
            let nearestOnSegment = nearestPointOnSegment(p: coord, v: p1, w: p2)
            let dist = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                .distance(from: CLLocation(latitude: nearestOnSegment.latitude, longitude: nearestOnSegment.longitude))
            
            if dist < minDistance {
                minDistance = dist
                closest = nearestOnSegment
            }
        }
        return closest
    }
    
    private func nearestPointOnSegment(p: CLLocationCoordinate2D, v: CLLocationCoordinate2D, w: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let l2 = pow(v.longitude - w.longitude, 2) + pow(v.latitude - w.latitude, 2)
        if l2 == 0 { return v }
        
        var t = ((p.longitude - v.longitude) * (w.longitude - v.longitude) + (p.latitude - v.latitude) * (w.latitude - v.latitude)) / l2
        t = max(0, min(1, t))
        
        return CLLocationCoordinate2D(
            latitude: v.latitude + t * (w.latitude - v.latitude),
            longitude: v.longitude + t * (w.longitude - v.longitude)
        )
    }
    
    private func setupAudioSession() {
        do {
            // .playback ensures it plays even when the silent switch is ON.
            // .defaultToSpeaker ensures it doesn't just play in the earpiece.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers, .defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
            DebugLogger.shared.log("Audio Session Configured: playback/speaker/spoken")
        } catch {
            DebugLogger.shared.log("Audio Session ERROR: \(error.localizedDescription)")
            print("[DriveViewModel] Audio Session Setup Error: \(error)")
        }
    }

    private func announce(_ message: String) {
        // Default to true if not set
        let rawVoiceVal = UserDefaults.standard.object(forKey: "voiceNavEnabled") as? Bool
        let voiceEnabled = rawVoiceVal ?? true
        
        DebugLogger.shared.log("AUDIO STATE: enabled=\(voiceEnabled), msg='\(message)'")
        
        guard voiceEnabled, !message.isEmpty else { 
            return 
        }
        
        // Ensure session is correctly categorized and active EVERY time before speaking
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers, .defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            DebugLogger.shared.log("AUDIO SESSION ERROR: \(error.localizedDescription)")
        }
        
        let utterance = AVSpeechUtterance(string: message)
        
        // Use a consistent default voice if English-US enhanced isn't found
        if let premiumVoice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language == "en-US" && $0.quality == .enhanced }) {
            utterance.voice = premiumVoice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        
        // Stop any current reading to avoid overlap
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        
        speechSynthesizer.speak(utterance)
        DebugLogger.shared.log("NAV VOICE SENT: \(message)")
    }

    private func updateIdleTimer() {
        // Prevent screen dimming if we are driving OR navigating
        UIApplication.shared.isIdleTimerDisabled = isRecording || isNavigating
        DebugLogger.shared.log("Idle Timer Disabled: \(UIApplication.shared.isIdleTimerDisabled)")
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
