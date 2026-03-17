import Foundation
import Combine
import SwiftData
import MapKit
import ActivityKit
import AVFoundation
import UIKit
import FirebaseAuth
import FirebaseFirestore

/// Main observable view model that combines LocationManager, SpeedEngine, AlertEngine, and SessionRecorder.
@MainActor
public final class DriveViewModel: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
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
    private var rerouteTimer: Timer?
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
        self.speechSynthesizer.delegate = self
        setupAudioSession()
        
        // NOTE: Speed Camera API fetch is DISABLED. SpeedCameraService struct is
        // kept in the codebase for future re-enablement. Map annotations will simply
        // not appear until re-enabled.
        // Task { await SpeedCameraService.shared.fetchCameras() }
        
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
        
        // Throttled Live Activity update (every 5 seconds)
        Task {
            await ArizonaSpeedLimitService.shared.loadDataIfNeeded()
        }
        
        // Throttled Live Activity update (every 5 seconds)
        Timer.publish(every: 5.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, self.isRecording || self.isNavigating else { return }
                self.updateLiveActivity()
            }
            .store(in: &cancellables)
        
        // Listen to location updates for navigation progress and live activity
        // Speed camera proximity check removed (API disabled)
        locManager.$latestLocation
            .compactMap { $0 }
            .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] location in
                guard let self = self else { return }
                if self.isNavigating {
                    self.updateNavigationProgress(at: location)
                }
                
                // Keep the Dynamic Island / Live Activity updated with live speed
                if self.isRecording || self.isNavigating {
                    self.updateLiveActivity()
                }
                
                // PERIODIC SYNC: Update last location in Firestore
                AuthenticationManager.shared.updateLastLocation(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
            }
            .store(in: &cancellables)
    }
    
    public func startSession() {
        DebugLogger.shared.log("Drive session STARTED")
        
        // Request authorization only when session starts
        locationManager.requestAuthorization()
        locationManager.startUpdatingLocation()
        
        var destID: String? = nil
        if #available(iOS 18.0, *) {
            destID = destination?.identifier?.rawValue
        }
        sessionRecorder.startSession(destinationPlaceID: destID)
        
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
        updateLiveActivity()
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
                AuthenticationManager.shared.syncDriveSession(session)
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
            AuthenticationManager.shared.syncDriveSession(session)
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
        request.departureDate = .now // ESSENTIAL for traffic-aware routing
        
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
    
    public func startNavigation(with route: MKRoute, isReroute: Bool = false) async {
        DebugLogger.shared.log("Navigation \(isReroute ? "REROUTED" : "STARTED") using Route (\(Int(route.distance))m)")
        self.isSelectingRoute = false
        self.isNavigating = true
        self.currentRoute = route
        self.currentStepIndex = 0
        
        // Start Traffic Monitoring / Rerouting Timer
        startRerouteTimer()
        
        // Reset ETA to fresh calculation
        self.eta = Date().addingTimeInterval(route.expectedTravelTime)
        
        // Auto-start session if not already recording
        if !isRecording {
            startSession() // This now picks up the destination ID from the property
            DebugLogger.shared.log("Session AUTO-STARTED with navigation")
        }

        // Pre-cache speed limits along the route polyline points
        // Essential to prevent limits from 'glitching away' during the drive.
        await cacheRouteSegments(route)

        if let dest = self.destination {
            await navigationDelegate?.startNavigationTrigger(to: dest, route: route)
        }
        
        // Announce first instruction
        if !route.steps.isEmpty {
            // Find first step with actual content
            let firstStep = route.steps.first(where: { !$0.instructions.isEmpty })
            if let step = firstStep {
                self.nextManeuverInstruction = step.instructions
                self.nextManeuverImageName = getImageForManeuver(step.instructions)
                if isReroute {
                    announce("Rerouting. \(step.instructions)")
                } else {
                    announce("Navigation started. \(step.instructions)")
                }
            }
        }

        if #available(iOS 16.1, *) {
            LiveActivityManager.shared.startActivity(sessionStartDate: sessionStartTime ?? Date())
        }
    }

    private func cacheRouteSegments(_ route: MKRoute) async {
        let polylinePoints = route.polyline.points()
        let pointCount = route.polyline.pointCount
        var coordinates: [CLLocationCoordinate2D] = []
        
        // Cache every ~1 mile or so (stride by 40 points which is ~1-1.5km on highway)
        for i in stride(from: 0, to: pointCount, by: 30) {
            coordinates.append(polylinePoints[i].coordinate)
        }
        if pointCount > 0 { coordinates.append(polylinePoints[pointCount-1].coordinate) }
        
        await ArizonaSpeedLimitService.shared.preCacheRoute(coordinates: coordinates)
        DebugLogger.shared.log("Route segments cached (\(coordinates.count) points)")
    }
    
    public func startNavigation(to destination: MKMapItem) async {
        self.destination = destination
        self.isNavigating = true
        
        if !isRecording {
            startSession()
        }
        
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
        rerouteTimer?.invalidate()
        rerouteTimer = nil
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
        
        // Only request location if search is actually happening (needed for region)
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestAuthorization()
        }
        
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
                        await startNavigation(with: newRoute, isReroute: true)
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
            
            // UI should show the instructions for the NEXT maneuver we are approaching.
            // If we are on step N, we are approaching the maneuver point at the END of step N.
            // The instructions for step N describe what to do at that point.
            
            let instruction = currentStep.instructions
            if self.nextManeuverInstruction != instruction && !instruction.isEmpty {
                self.nextManeuverInstruction = instruction
                self.nextManeuverImageName = getImageForManeuver(instruction)
            }
            
            // Voice Announcements (multi-stage)
            let isMetric = UserDefaults.standard.string(forKey: "measurementSystem") == "Metric"
            
            let thresholds: [(distance: Double, key: String, text: String)]
            if isMetric {
                thresholds = [
                    (3000.0, "3km", "3 kilometers"),
                    (2000.0, "2km", "2 kilometers"),
                    (1000.0, "1km", "1 kilometer"),
                    (500.0, "500m", "500 meters"),
                    (200.0, "200m", "200 meters")
                ]
            } else {
                thresholds = [
                    (3218.69, "2mi", "2 miles"),
                    (1609.34, "1mi", "1 mile"),
                    (804.67, "halfi", "half a mile"),
                    (304.8, "1000ft", "1000 feet"),
                    (152.4, "500ft", "500 feet")
                ]
            }
            
            // Check thresholds in descending order
            for (threshold, key, text) in thresholds {
                // If we've just crossed under this threshold (within a 200m buffer to avoid announcing late)
                if distanceToTurn <= threshold && distanceToTurn > threshold - 200 {
                    let stageKey = "\(currentStepIndex)_\(key)"
                    if !announcementStages.contains(stageKey) {
                        // Mark all larger thresholds as announced so we don't say them out of order
                        for (largerThresh, largerKey, _) in thresholds where largerThresh > threshold {
                            announcementStages.insert("\(currentStepIndex)_\(largerKey)")
                        }
                        
                        announcementStages.insert(stageKey)
                        announce("In \(text), \(instruction)")
                        break // Only announce one stage at a time
                    }
                }
            }
            
            if distanceToTurn < 45 { 
                advanceToNextStep(steps)
            } else if let prevDist = lastDistanceToTurn, distanceToTurn > prevDist + 15 && distanceToTurn < 250 {
                // If the distance to the turn is abruptly INCREASING while still on the route, 
                // it implies the user passed the maneuver point without hitting the 45m inner circle.
                advanceToNextStep(steps)
            }
            lastDistanceToTurn = distanceToTurn
        }
        
        // 3. Regular ETA calculation refresh (every location update)
        // Adjust for current progress
        let remainingDistance = route.steps[currentStepIndex...].reduce(0) { $0 + $1.distance }
        let progressPercent = 1.0 - (remainingDistance / route.distance)
        let totalExpectedTime = route.expectedTravelTime
        
        // Simple smoothing for ETA
        let newETA = Date().addingTimeInterval(max(30, totalExpectedTime * (1.0 - progressPercent)))
        self.eta = newETA
    }
    
    private var lastDistanceToTurn: CLLocationDistance? = nil
    
    private func advanceToNextStep(_ steps: [MKRoute.Step]) {
                if self.currentStepIndex != lastAnnouncedStep {
                    lastAnnouncedStep = self.currentStepIndex
                    self.currentStepIndex += 1
                    self.lastDistanceToTurn = nil // Reset tracking for next turn
                    
                    if self.currentStepIndex < steps.count {
                        let newStep = steps[self.currentStepIndex]
                        if !newStep.instructions.isEmpty {
                            announce(newStep.instructions) 
                        }
                    } else if let dest = destination?.placemark.location, 
                              locationManager.latestLocation?.distance(from: dest) ?? 100 < 50 {
                        Task { await self.endNavigation() }
                    }
                }
    }
    
    // Helper to sum distances up to index bounds safely
    private var lastAnnouncedStep: Int = -1
    private var announcementStages: Set<String> = []
    
    // Helper to find nearest point on polyline to a coordinate
    // Restored to full scan to ensure we NEVER lose tracking if the user goes off-route
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
            // We configure the CATEGORY here but do NOT call setActive(true) yet.
            // Calling setActive(true) on launch is what interrupts background music.
            // .mixWithOthers is CRITICAL to let Spotify/Apple Music keep playing.
            var options: AVAudioSession.CategoryOptions = [.duckOthers, .mixWithOthers, .defaultToSpeaker]
            if #available(iOS 17.0, *) {
                options.insert(.interruptSpokenAudioAndMixWithOthers)
            }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: options)
            DebugLogger.shared.log("Audio Session Configured (Inactive): playback/mixWithOthers")
        } catch {
            DebugLogger.shared.log("Audio Session CONFIG ERROR: \(error.localizedDescription)")
        }
    }

    private func announce(_ message: String) {
        let rawVoiceVal = UserDefaults.standard.object(forKey: "voiceNavEnabled") as? Bool
        let voiceEnabled = rawVoiceVal ?? true
        
        guard voiceEnabled, !message.isEmpty else { return }
        
        // Expand common road abbreviations for natural speech
        let expandedMessage = expandAbbreviations(message)
        
        // 1. Activate session only when speaking starts
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            DebugLogger.shared.log("AUDIO ACTIVATE ERROR: \(error.localizedDescription)")
        }
        
        let utterance = AVSpeechUtterance(string: expandedMessage)
        if let premiumVoice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language == "en-US" && $0.quality == .enhanced }) {
            utterance.voice = premiumVoice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1.0
        
        // We do NOT stop speaking immediately. This allows announcements to enqueue
        // naturally instead of abruptly cutting themselves off.
        
        speechSynthesizer.speak(utterance)
        DebugLogger.shared.log("NAV VOICE SENT: \(expandedMessage)")
    }

    private func expandAbbreviations(_ text: String) -> String {
        var result = text
        let mapping: [String: String] = [
            "Ave": "Avenue", "St": "Street", "Pl": "Place", "Rd": "Road",
            "Dr": "Drive", "Blvd": "Boulevard", "Hwy": "Highway", "Fwy": "Freeway",
            "Expy": "Expressway", "Pkwy": "Parkway", "Ln": "Lane", "Cir": "Circle",
            "Ct": "Court", "Ter": "Terrace", "US": "U.S.", 
            "N": "North", "S": "South", "E": "East", "W": "West", 
            "NE": "Northeast", "NW": "Northwest",
            "SE": "Southeast", "SW": "Southwest"
        ]
        
        for (abbr, full) in mapping {
            // \\b matches word boundaries safely so we don't replace "W" inside "Way"
            let pattern = "\\b\(abbr)\\b\\.?"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: full)
            }
        }
        
        // Handle Interstates (e.g. I-95 -> Interstate 95)
        if let regex = try? NSRegularExpression(pattern: "\\bI-", options: [.caseInsensitive]) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "Interstate ")
        }
        
        return result
    }

    // AVSpeechSynthesizerDelegate
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            // Deactivate with .notifyOthersOnDeactivation to restore music volume
            if !synthesizer.isSpeaking {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                DebugLogger.shared.log("Audio Session Deactivated (Music Restored)")
            }
        }
    }
    
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if !synthesizer.isSpeaking {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    private func updateIdleTimer() {
        // Prevent screen dimming if we are driving OR navigating
        UIApplication.shared.isIdleTimerDisabled = isRecording || isNavigating
        DebugLogger.shared.log("Idle Timer Disabled: \(UIApplication.shared.isIdleTimerDisabled)")
    }
    
    private func getImageForManeuver(_ instruction: String) -> String {
        let lower = instruction.lowercased()
        if lower.contains("u-turn") { return "arrow.uturn.left" }
        if lower.contains("exit") { return "arrow.up.right.square" }
        if lower.contains("merge") { return "arrow.merge" }
        
        // Slight/Keep checks must precede general turn checks
        if lower.contains("slight right") || lower.contains("keep right") { return "arrow.up.right" }
        if lower.contains("slight left") || lower.contains("keep left") { return "arrow.up.left" }
        
        // General turn checks
        if lower.contains("right") { return "arrow.turn.up.right" }
        if lower.contains("left") { return "arrow.turn.up.left" }
        
        return "arrow.up"
    }

    // MARK: - Dynamic Rerouting (Traffic Awareness)
    private func startRerouteTimer() {
        rerouteTimer?.invalidate()
        // Check for a faster route every 5 minutes
        rerouteTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkForFasterRoute()
            }
        }
    }

    private func checkForFasterRoute() async {
        guard isNavigating, let dest = destination, let current = currentRoute else { return }
        
        let request = MKDirections.Request()
        request.source = MKMapItem.forCurrentLocation()
        request.destination = dest
        request.transportType = .automobile
        request.departureDate = .now
        
        do {
            let directions = MKDirections(request: request)
            let response = try await directions.calculate()
            if let fastest = response.routes.first {
                // If the new route is at least 120 seconds (2 mins) faster than the expected remaining time
                // of the current route, then reroute.
                let remainingTime = current.expectedTravelTime - (Date().timeIntervalSince(sessionStartTime ?? Date()))
                if fastest.expectedTravelTime < remainingTime - 120 {
                    DebugLogger.shared.log("TRAFFIC ALERT: Faster route found (\(Int(remainingTime - fastest.expectedTravelTime))s saved). Rerouting...")
                    await startNavigation(with: fastest, isReroute: true)
                }
            }
        } catch {
            // Silently fail traffic checks
        }
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
