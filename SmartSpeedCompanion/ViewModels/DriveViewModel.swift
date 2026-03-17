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
    
    // Voice Navigation Tracking
    private var stepStageFlags: [Int: Set<String>] = [:]
    private var lastDistanceToTurn: CLLocationDistance? = nil
    
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
        
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
        
        Publishers.CombineLatest(locManager.$latestLocation, locManager.$latestHeading)
            .map { location, heading -> Double? in
                if let loc = location, loc.speed > 2.0 {
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
        
        SmartSpeedLimitService.shared.$dataSource
            .receive(on: RunLoop.main)
            .assign(to: &$speedLimitSource)
        
        Task {
            await ArizonaSpeedLimitService.shared.loadDataIfNeeded()
        }
        
        Timer.publish(every: 5.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, self.isRecording || self.isNavigating else { return }
                self.updateLiveActivity()
            }
            .store(in: &cancellables)
        
        locManager.$latestLocation
            .compactMap { $0 }
            .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] location in
                guard let self = self else { return }
                if self.isNavigating {
                    self.updateNavigationProgress(at: location)
                }
                
                if self.isRecording || self.isNavigating {
                    self.updateLiveActivity()
                }
                
                AuthenticationManager.shared.updateLastLocation(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
            }
            .store(in: &cancellables)
    }
    
    public func startSession() {
        DebugLogger.shared.log("Drive session STARTED")
        locationManager.requestAuthorization()
        locationManager.startUpdatingLocation()
        
        var destID: String? = nil
        if #available(iOS 18.0, *) {
            destID = destination?.identifier?.rawValue
        }
        sessionRecorder.startSession(destinationPlaceID: destID)
        
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
                consecutiveOverSeconds: 0,
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
                self.lastSessionToPotentialDelete = session
                self.showShortSessionPrompt = true
            } else {
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
        request.departureDate = .now 
        
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
        
        // Reset Voice State
        self.stepStageFlags.removeAll()
        self.lastDistanceToTurn = nil
        
        startRerouteTimer()
        self.eta = Date().addingTimeInterval(route.expectedTravelTime)
        
        if !isRecording {
            startSession()
            DebugLogger.shared.log("Session AUTO-STARTED with navigation")
        }

        await cacheRouteSegments(route)

        if let dest = self.destination {
            await navigationDelegate?.startNavigationTrigger(to: dest, route: route)
        }
        
        if !route.steps.isEmpty {
            var firstRealIndex = 0
            while firstRealIndex < route.steps.count && route.steps[firstRealIndex].instructions.isEmpty {
                firstRealIndex += 1
            }
            
            let targetIndex = firstRealIndex < route.steps.count ? firstRealIndex : 0
            self.currentStepIndex = targetIndex
            
            let activeStep = route.steps[targetIndex]
            self.nextManeuverInstruction = activeStep.instructions
            self.nextManeuverImageName = getImageForManeuver(activeStep.instructions)
        }

        if #available(iOS 16.1, *) {
            LiveActivityManager.shared.startActivity(sessionStartDate: sessionStartTime ?? Date())
        }
    }

    private func cacheRouteSegments(_ route: MKRoute) async {
        let polylinePoints = route.polyline.points()
        let pointCount = route.polyline.pointCount
        var coordinates: [CLLocationCoordinate2D] = []
        
        for i in stride(from: 0, to: pointCount, by: 30) {
            coordinates.append(polylinePoints[i].coordinate)
        }
        if pointCount > 0 { coordinates.append(polylinePoints[pointCount-1].coordinate) }
        
        await ArizonaSpeedLimitService.shared.preCacheRoute(coordinates: coordinates)
    }
    
    public func startNavigation(to destination: MKMapItem) async {
        self.destination = destination
        self.isNavigating = true
        if !isRecording { startSession() }
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
        self.stepStageFlags.removeAll()
        await navigationDelegate?.endNavigationTrigger()
        
        if !isRecording {
            LiveActivityManager.shared.endActivity()
        }
    }
    
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
    
    public func selectCompletion(_ completion: MKLocalSearchCompletion) async {
        let searchRequest = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: searchRequest)
        do {
            let response = try await search.start()
            if let first = response.mapItems.first {
                searchResults = [first]
            }
        } catch {
            print("Failed to resolve completion: \(error)")
        }
    }
    
    public func searchDestination(query: String) async {
        guard !query.isEmpty else { searchResults = []; return }
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
    
    // MARK: - Core Navigation Loop (Apple Maps Parity)
    
    private func updateNavigationProgress(at location: CLLocation) {
        guard let route = currentRoute else { return }
        let steps = route.steps
        
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

        if self.currentStepIndex >= steps.count { return }
        
        let currentStep = steps[self.currentStepIndex]
        let stepPolyline = currentStep.polyline
        let pointCount = stepPolyline.pointCount
        
        if pointCount > 0 {
            let maneuverPoint = stepPolyline.points()[pointCount - 1].coordinate
            let maneuverLocation = CLLocation(latitude: maneuverPoint.latitude, longitude: maneuverPoint.longitude)
            let distanceToTurn = location.distance(from: maneuverLocation)
            
            self.distanceToNextTurn = distanceToTurn
            
            let currentInstruction = currentStep.instructions
            if self.nextManeuverInstruction != currentInstruction && !currentInstruction.isEmpty {
                self.nextManeuverInstruction = currentInstruction
                self.nextManeuverImageName = getImageForManeuver(currentInstruction)
            }
            
            processVoiceAnnouncements(for: currentStepIndex, distanceToTurn: distanceToTurn, steps: steps, speed: location.speed)
            
            let isMoving = location.speed > 1.0 
            
            if distanceToTurn < 25 && isMoving { 
                advanceToNextStep(steps)
            } else if let prevDist = lastDistanceToTurn, distanceToTurn > prevDist + 25 && distanceToTurn < 250 && isMoving {
                advanceToNextStep(steps)
            }
            
            lastDistanceToTurn = distanceToTurn
        }
        
        let remainingDistance = route.steps[currentStepIndex...].reduce(0) { $0 + $1.distance }
        let progressPercent = 1.0 - (remainingDistance / route.distance)
        let totalExpectedTime = route.expectedTravelTime
        let newETA = Date().addingTimeInterval(max(30, totalExpectedTime * (1.0 - progressPercent)))
        self.eta = newETA
    }
    
    private func processVoiceAnnouncements(for stepIndex: Int, distanceToTurn: Double, steps: [MKRoute.Step], speed: Double) {
        let currentStep = steps[stepIndex]
        let instruction = currentStep.instructions
        guard !instruction.isEmpty else { return }

        // 1. New Step Initialization
        if stepStageFlags[stepIndex] == nil {
            stepStageFlags[stepIndex] = []
            
            let routeName = currentStep.name.isEmpty ? "the current route" : currentStep.name
            
            if stepIndex == 0 {
                if distanceToTurn < 150 { // Very close start (< 500ft)
                    var msg = "Starting route. \(instruction)"
                    // Lookahead to bundle the next turn if it's right after this one
                    if stepIndex + 1 < steps.count, steps[stepIndex+1].distance < 150, !steps[stepIndex+1].instructions.isEmpty {
                        msg += ", then \(steps[stepIndex+1].instructions)"
                        stepStageFlags[stepIndex+1] = ["immediate", "quartermi"] // Prevent repeating next turn
                    }
                    announce(msg)
                } else {
                    announce("Starting route. Continue on \(routeName) for \(formatDistance(distanceToTurn)).")
                }
            } else {
                // Mid-route transition into a new step
                if distanceToTurn > 3218 { // > 2 miles
                    announce("Continue on \(routeName) for \(formatDistance(distanceToTurn)).")
                } else if distanceToTurn > 1200 { // ~0.75 miles
                    announce("In \(formatDistance(distanceToTurn)), \(instruction)")
                }
            }
        }

        var flags = stepStageFlags[stepIndex]!
        guard let lastDist = lastDistanceToTurn else { return }

        let isMetric = UserDefaults.standard.string(forKey: "measurementSystem") == "Metric"
        let immediateThreshold: Double = speed > 22.0 ? 250.0 : 80.0 // Give more warning time at highway speeds

        let milestones: [(key: String, distance: Double, prefix: String)]
        if isMetric {
            milestones = [
                ("2km", 2000, "In 2 kilometers, "),
                ("1km", 1000, "In 1 kilometer, "),
                ("500m", 500, "In 500 meters, "),
                ("immediate", immediateThreshold, "")
            ]
        } else {
            milestones = [
                ("2mi", 3218, "In 2 miles, "),
                ("1mi", 1609, "In 1 mile, "),
                ("halfmi", 804, "In half a mile, "),
                ("quartermi", 402, "In a quarter mile, "),
                ("immediate", immediateThreshold, "")
            ]
        }

        // 2. Downward Crossing Check
        for (key, thresholdDist, prefix) in milestones {
            if lastDist > thresholdDist && distanceToTurn <= thresholdDist {
                if !flags.contains(key) {
                    flags.insert(key)
                    stepStageFlags[stepIndex] = flags

                    var speech = prefix + instruction

                    // "Then..." Lookahead Logic for immediate turns
                    if key == "immediate" || key == "quartermi" {
                        let nextIdx = stepIndex + 1
                        if nextIdx < steps.count {
                            let nextStep = steps[nextIdx]
                            if !nextStep.instructions.isEmpty && nextStep.distance < 150 {
                                speech += ", then \(nextStep.instructions)"
                                
                                if stepStageFlags[nextIdx] == nil { stepStageFlags[nextIdx] = [] }
                                stepStageFlags[nextIdx]?.insert("immediate")
                                stepStageFlags[nextIdx]?.insert("quartermi")
                            }
                        }
                    }

                    announce(speech)
                    break // Prevent announcing multiple milestones in a single location update
                }
            }
        }
    }
    
    private func advanceToNextStep(_ steps: [MKRoute.Step]) {
        var nextIdx = self.currentStepIndex + 1
        
        while nextIdx < steps.count && steps[nextIdx].instructions.isEmpty {
            nextIdx += 1
        }
        
        self.currentStepIndex = nextIdx
        self.lastDistanceToTurn = nil // Crucial: Resets tracking for the new step
        
        if self.currentStepIndex < steps.count {
            let nextStep = steps[self.currentStepIndex]
            self.nextManeuverInstruction = nextStep.instructions
            self.nextManeuverImageName = getImageForManeuver(nextStep.instructions)
            
            // Notice: We intentionally do NOT announce here. 
            // The processVoiceAnnouncements engine will handle it gracefully on the next location tick.
        } else if let dest = destination?.placemark.location, 
                  locationManager.latestLocation?.distance(from: dest) ?? 100 < 50 {
            announce("You have arrived at your destination.")
            Task { await self.endNavigation() }
        }
    }
    
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
    
    // Formats distance conversationally
    private func formatDistance(_ meters: Double) -> String {
        let isMetric = UserDefaults.standard.string(forKey: "measurementSystem") == "Metric"
        if isMetric {
            if meters >= 1000 {
                return String(format: "%.1f kilometers", meters / 1000.0)
            } else {
                return "\(Int(meters / 50) * 50) meters"
            }
        } else {
            let miles = meters / 1609.34
            if miles >= 1.0 {
                return String(format: "%.1f miles", miles).replacingOccurrences(of: ".0", with: "")
            } else if miles >= 0.4 {
                return "half a mile"
            } else if miles >= 0.2 {
                return "a quarter mile"
            } else {
                let feet = meters * 3.28084
                return "\(Int(feet / 100) * 100) feet"
            }
        }
    }
    
    // MARK: - Audio Session & Announcements
    
    private func setupAudioSession() {
        do {
            var options: AVAudioSession.CategoryOptions = [.duckOthers, .mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]
            if #available(iOS 17.0, *) {
                options.insert(.interruptSpokenAudioAndMixWithOthers)
            }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: options)
            DebugLogger.shared.log("Audio Session Configured")
        } catch {
            DebugLogger.shared.log("Audio Session CONFIG ERROR: \(error.localizedDescription)")
        }
    }

    private func announce(_ message: String) {
        let rawVoiceVal = UserDefaults.standard.object(forKey: "voiceNavEnabled") as? Bool
        let voiceEnabled = rawVoiceVal ?? true
        
        guard voiceEnabled, !message.isEmpty else { return }
        
        var cleanMessage = message.replacingOccurrences(of: "...", with: "")
        cleanMessage = cleanMessage.replacingOccurrences(of: "..", with: "")
        if cleanMessage.hasSuffix(".") { cleanMessage.removeLast() }
        
        let expandedMessage = expandAbbreviations(cleanMessage)
        
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            DebugLogger.shared.log("AUDIO ACTIVATE ERROR: \(error.localizedDescription)")
        }
        
        let utterance = AVSpeechUtterance(string: expandedMessage)
        utterance.preUtteranceDelay = 0.5 
        utterance.postUtteranceDelay = 0.2
        
        if let premiumVoice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language == "en-US" && $0.quality == .enhanced }) {
            utterance.voice = premiumVoice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1.0
        
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
            "NE": "Northeast", "NW": "Northwest", "SE": "Southeast", "SW": "Southwest",
            "SR": "State Route", "CR": "County Route"
        ]
        
        for (abbr, full) in mapping {
            let pattern = "\\b\(abbr)\\b\\.?"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: full)
            }
        }
        
        if let regex = try? NSRegularExpression(pattern: "\\bI-", options: [.caseInsensitive]) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "Interstate ")
        }
        
        return result
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
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
        UIApplication.shared.isIdleTimerDisabled = isRecording || isNavigating
    }
    
    private func getImageForManeuver(_ instruction: String) -> String {
        let lower = instruction.lowercased()
        if lower.contains("u-turn") { return "arrow.uturn.left" }
        if lower.contains("exit") { return "arrow.up.right.square" }
        if lower.contains("merge") { return "arrow.merge" }
        
        if lower.contains("slight right") || lower.contains("keep right") { return "arrow.up.right" }
        if lower.contains("slight left") || lower.contains("keep left") { return "arrow.up.left" }
        
        if lower.contains("right") { return "arrow.turn.up.right" }
        if lower.contains("left") { return "arrow.turn.up.left" }
        
        return "arrow.up"
    }

    // MARK: - Dynamic Rerouting (Traffic Awareness)
    private func startRerouteTimer() {
        rerouteTimer?.invalidate()
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
                let remainingTime = current.expectedTravelTime - (Date().timeIntervalSince(sessionStartTime ?? Date()))
                if fastest.expectedTravelTime < remainingTime - 120 {
                    DebugLogger.shared.log("TRAFFIC ALERT: Faster route found. Rerouting...")
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