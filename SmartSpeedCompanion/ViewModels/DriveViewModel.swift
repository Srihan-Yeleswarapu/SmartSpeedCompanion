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
    // MARK: - Core Services
    public let locationManager: LocationManager
    public let speedEngine: SpeedEngine
    public let alertEngine: AlertEngine
    public let sessionRecorder: SessionRecorder
    private var lastRerouteTime: Date = .distantPast
    private var isCalculatingReroute: Bool = false
    private let offRouteThreshold: CLLocationDistance = 20.0 // 20 meters (~66 feet)
    
    // MARK: - Core Driving State
    /// User's current speed in MPH (always converted to MPH for the logic layer).
    @Published public var speed: Double = 0.0
    /// True heading when available; otherwise falls back to course (direction of travel).
    @Published public var currentHeading: Double? = nil
    /// Current speed limit from the active data source (Overpass or Arizona GeoJSON).
    @Published public var limit: Int = 0
    /// Status indicating if the user is over, near, or safely within the limit.
    @Published public var status: SpeedStatus = .safe
    /// Indicates if a drive session is currently being recorded to the database.
    @Published public var isRecording: Bool = false {
        didSet { updateIdleTimer() }
    }
    /// Total duration of the current recording session in seconds.
    @Published public var sessionDuration: TimeInterval = 0
    /// Indicates if an audio alert (beeps/warnings) is currently sounding.
    @Published public var alertActive: Bool = false
    /// Humand-readable label for where the speed limit data is coming from.
    @Published public var speedLimitSource: String = "No Data"
    /// List of speed cameras currently within proximity of the driver.
    @Published public var nearbyCameras: [SpeedCamera] = []
    /// The specific camera that triggered the most recent alert.
    @Published public var activeCameraAlert: SpeedCamera? = nil
    
    // MARK: - Navigation State
    /// Indicates if active turn-by-turn navigation is running.
    @Published public var isNavigating: Bool = false {
        didSet { updateIdleTimer() }
    }
    /// The MapKit route object being followed.
    @Published public var currentRoute: MKRoute? = nil
    /// The destination selected by the user.
    @Published public var destination: MKMapItem? = nil
    // Core Driving State
    @Published public var destinationItem: MKMapItem? = nil
    /// Resolved search results for the user's manual query.
    @Published public var searchResults: [MKMapItem] = []
    /// Real-time search completion suggestions (addresses/POIs).
    @Published public var searchCompletions: [MKLocalSearchCompletion] = []
    /// Indicates if a server-side search is currently in progress.
    @Published public var isSearching: Bool = false
    /// Indicates if local search suggestions are currently refreshing.
    @Published public var isSearchingLocally: Bool = false
    /// History of recent search query strings.
    @Published public var recentSearches: [String] = []
    
    // MARK: - Route Selection State
    /// Indicates if we are showing the alternate route selection screen.
    @Published public var isSelectingRoute: Bool = false
    /// Indicates if the system is currently calculating a reroute.
    @Published public var isRerouting: Bool = false
    /// The list of alternate routes returned by MKDirections.
    @Published public var availableRoutes: [MKRoute] = []
    
    // MARK: - Map Interaction State
    /// True if the user has manually panned the map away from current tracking.
    @Published public var isMapDetached: Bool = false
    
    // MARK: - Deletion States
    /// Controls the UI prompt that asks to delete drives shorter than 90 seconds.
    @Published public var showShortSessionPrompt: Bool = false
    /// Temporary storage for a short session pending user deletion choice.
    public var lastSessionToPotentialDelete: DriveSession? = nil
 
    // MARK: - Guidance Details
    /// Spoken and displayed text for the current navigation step (e.g., "Turn Left").
    @Published public var nextManeuverInstruction: String = ""
    /// SFSymbol name representing the type of turn or move.
    @Published var nextManeuverImageName: String = "arrow.up"
    /// Meters remaining until the next maneuver point.
    @Published public var distanceToNextTurn: CLLocationDistance = 0
    /// Estimated time of arrival calculated based on expected route time and progress.
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
    private var hasAnnouncedArrival: Bool = false
    
    public init(modelContext: ModelContext? = nil) {
        // Core Logic components are owned by the ViewModel
        let locManager = LocationManager()
        let spdEngine = SpeedEngine(locationManager: locManager)
        let alrtEngine = AlertEngine(speedEngine: spdEngine)
        let rec = SessionRecorder(speedEngine: spdEngine, locationManager: locManager)
        
        // Feed the database context into the recorder
        if let ctx = modelContext {
            rec.setModelContext(ctx)
        }
        
        self.locationManager = locManager
        self.speedEngine = spdEngine
        self.alertEngine = alrtEngine
        self.sessionRecorder = rec
        self.recentSearches = UserDefaults.standard.stringArray(forKey: "recentSearches") ?? []

        super.init()
        #if DEBUG || DEVELOPER_BUILD
        SimulationManager.shared.dataSource = self
        #endif
        
        self.speechSynthesizer.delegate = self
        setupAudioSession() // Prepare the singleton AVAudioSession
        
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
        
        // 1. COMPUTE HEADING: Use course for heading when moving > 4.5mph for stability, fall back to compass
        Publishers.CombineLatest(locManager.$latestLocation, locManager.$latestHeading)
            .map { location, heading -> Double? in
                if let loc = location, loc.speed > 2.0 {
                    return loc.course >= 0 ? loc.course : heading?.trueHeading
                }
                return heading?.trueHeading
            }
            .receive(on: RunLoop.main)
            .assign(to: &$currentHeading)

        // 2. STATE BINDING: Connect logic-layer publishers to UI-layer @Published properties
        spdEngine.$speed.assign(to: &$speed)
        SmartSpeedLimitService.shared.$currentLimit.assign(to: &$limit)
        spdEngine.$status.assign(to: &$status)
        alrtEngine.$audioAlertActive.assign(to: &$alertActive)
        rec.$isRecording.assign(to: &$isRecording)
        
        SmartSpeedLimitService.shared.$dataSource
            .receive(on: RunLoop.main)
            .assign(to: &$speedLimitSource)
        
        // 3. CACHE INITIALIZATION: Load Arizona speed limit data into memory (only happens once)
        Task {
            await ArizonaSpeedLimitService.shared.loadDataIfNeeded()
        }
        
        // 4. PERIODIC UI SYNC: Update Live Activities and items every 5 seconds if active
        Timer.publish(every: 5.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, self.isRecording || self.isNavigating else { return }
                self.updateLiveActivity()
            }
            .store(in: &cancellables)
        
        // 5. CORE LOOP: Listen to raw location updates to drive navigation logic
        locManager.$latestLocation
            .compactMap { $0 }
            .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] location in
                guard let self = self else { return }
                self.speed = location.speedMPH
                self.currentHeading = location.course >= 0 ? location.course : nil
                // Advance turn-by-turn guidance
                if self.isNavigating {
                    self.updateNavigationProgress(at: location)
                }
                // Ensure Dynamic Island / Lock Screen stays fresh
                if self.isRecording || self.isNavigating {
                    self.updateLiveActivity()
                }
                if self.currentRoute != nil {
                    self.checkOffRouteStatus(location)
                }
                // Sync position to Firebase for potential multi-device/dashboard features
                AuthenticationManager.shared.updateLastLocation(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Drive Session Management
    
    /// Logic to start recording GPS points. Triggered manually or automatically with navigation.
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
        
        // Start the Lock Screen Live Activity
        LiveActivityManager.shared.startActivity(sessionStartDate: sessionStartTime ?? Date())
        updateLiveActivity()
    }
    
    /// Updates the Dynamic Island and Lock Screen widgets with real-time driving data.
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
    
    /// Stops recording the session and checks if it's worth saving (long enough).
    public func endSession() {
        DebugLogger.shared.log("Drive session ENDING (Duration: \(Int(sessionDuration))s)")
        if let session = sessionRecorder.endSession() {
            // Trips under 90 seconds are usually accidental. Prompt user instead of auto-saving.
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
        
        // Only stop Live Activity if navigation isn't using it too.
        if !isNavigating {
            LiveActivityManager.shared.endActivity()
            Task {
                // Wipe speed limit cache to save memory once drive is over
                await ArizonaSpeedLimitService.shared.clearCache()
            }
        }
    }
    
    /// User explicitly chose to 'Keep' a drive that was under 90 seconds. 
    /// Manually triggers the write to SwiftData and Firebase.
    public func saveLastSession() {
        if let session = self.lastSessionToPotentialDelete {
            self.sessionRecorder.saveSession(session)
            AuthenticationManager.shared.syncDriveSession(session)
            self.lastSessionToPotentialDelete = nil
        }
    }
    
    /// User explicitly chose 'Delete Drive' for a short session. We clear local refs and log.
    public func deleteLastSession(context: ModelContext) {
        // Since we didn't insert it into the modelContext yet during endSession(), 
        // we just nulify our reference and log it.
        self.lastSessionToPotentialDelete = nil
        DebugLogger.shared.log("Short drive session DISCARDED by user.")
    }
    
    // MARK: - Route Calculation
    
    /// Requests route options from MapKit and triggers the selection view.
    public func selectDestinationAndCalculateRoutes(to destination: MKMapItem, isRerouting: Bool = false) async {
        self.destination = destination
        saveRecentSearch(destination.name ?? "Unknown Location")
        
        let request = MKDirections.Request()
        request.source = MKMapItem.forCurrentLocation()
        request.destination = destination
        request.transportType = .automobile
        request.requestsAlternateRoutes = !isRerouting // Fast 1-route calculation if rerouting
        request.departureDate = .now 
        
        if UserDefaults.standard.bool(forKey: "avoidHighways") {
            request.highwayPreference = .avoid
        }
        
        do {
            let directions = MKDirections(request: request)
            DebugLogger.shared.log("Calculating routes to: \(destination.name ?? "Unknown")")
            let response = try await directions.calculate()
            self.availableRoutes = response.routes
            DebugLogger.shared.log("Found \(response.routes.count) available routes\(isRerouting ? " (Fast Reroute)" : "")")
            if !isRerouting {
                self.isSelectingRoute = true
            }
        } catch {
            DebugLogger.shared.log("Route calculation FAILED: \(error.localizedDescription)")
            print("Route error: \(error)")
        }
        
        if isRerouting {
            self.isRerouting = false
        }
    }
    
    // MARK: - Navigation Control
    
    /// Commences turn-by-turn guidance on a specific path.
    public func startNavigation(with route: MKRoute, isReroute: Bool = false) async {
        DebugLogger.shared.log("Navigation \(isReroute ? "REROUTED" : "STARTED") using Route (\(Int(route.distance))m)")
        self.isSelectingRoute = false
        self.isNavigating = true
        self.currentRoute = route
        self.currentStepIndex = 0
        
        // Reset flags so we can re-announce the approach to the first turn
        self.stepStageFlags.removeAll()
        self.lastDistanceToTurn = nil
        self.hasAnnouncedArrival = false
        
        startRerouteTimer() // Every 5 minutes check for a faster path
        self.eta = Date().addingTimeInterval(route.expectedTravelTime)
        
        // Automatically start recording the drive session if it hasn't been started manually
        if !isRecording {
            startSession()
            DebugLogger.shared.log("Session AUTO-STARTED with navigation")
        }

        // Cache speed limits for the route points to ensure we stay offline-capable during the drive
        await cacheRouteSegments(route)

        // Inform the CarPlay/UI layer that navigation is moving
        if let dest = self.destination {
            await navigationDelegate?.startNavigationTrigger(to: dest, route: route)
        }
        
        // Setup initial UI text based on the first meaningful step
        if !route.steps.isEmpty {
            var targetIndex = 0
            while targetIndex < route.steps.count && route.steps[targetIndex].instructions.isEmpty {
                targetIndex += 1
            }
            if targetIndex >= route.steps.count { targetIndex = 0 }
            
            self.currentStepIndex = targetIndex
            
            let activeStep = route.steps[targetIndex]
            
            // Look ahead for the actual instruction if the current one is 'Proceed to route'
            var displayInstruction = activeStep.instructions
            if instructionIsGenericLabel(displayInstruction) && targetIndex + 1 < route.steps.count {
                displayInstruction = route.steps[targetIndex + 1].instructions
            }
            
            self.nextManeuverInstruction = displayInstruction
            self.nextManeuverImageName = getImageForManeuver(displayInstruction)
        }

        // Display the route in a Live Activity on the lock screen
        if #available(iOS 16.1, *) {
            LiveActivityManager.shared.startActivity(sessionStartDate: sessionStartTime ?? Date())
        }
    }

    /// Grabs coordinates along the route and pre-fetches speed limit data for those points.
    private func cacheRouteSegments(_ route: MKRoute) async {
        let polylinePoints = route.polyline.points()
        let pointCount = route.polyline.pointCount
        var coordinates: [CLLocationCoordinate2D] = []
        
        // Sample the route every 30 points (~500m to 1km) to cover the whole path
        for i in stride(from: 0, to: pointCount, by: 30) {
            coordinates.append(polylinePoints[i].coordinate)
        }
        if pointCount > 0 { coordinates.append(polylinePoints[pointCount-1].coordinate) }
        
        await ArizonaSpeedLimitService.shared.preCacheRoute(coordinates: coordinates)
    }
    
    /// Alternative start navigation that triggers the calculation internally (legacy/direct support).
    public func startNavigation(to destination: MKMapItem) async {
        self.destination = destination
        self.isNavigating = true
        if !isRecording { startSession() }
        await navigationDelegate?.startNavigationTrigger(to: destination, route: nil)
    }
    
    /// Persianality: Track recently searched locations to show in search history.
    public func saveRecentSearch(_ title: String) {
        if !recentSearches.contains(title) {
            recentSearches.insert(title, at: 0)
            if recentSearches.count > 10 {
                recentSearches.removeLast()
            }
            UserDefaults.standard.set(recentSearches, forKey: "recentSearches")
        }
    }

    /// Terminates the current navigation session.
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
    
    // MARK: - Search Logic
    
    /// Filters address completions as the user types.
    public func updateSearchQuery(_ query: String) {
        if query.isEmpty {
            searchCompletions = []
            searchResults = []
            isSearchingLocally = false
            return
        }
        isSearchingLocally = true
        if let userLocation = locationManager.latestLocation {
            // Focus search results around the user's current 50km radius
            completer.region = MKCoordinateRegion(
                center: userLocation.coordinate,
                latitudinalMeters: 50000,
                longitudinalMeters: 50000
            )
        }
        completer.queryFragment = query
    }
    
    /// Resolves a text-based completion from the dropdown into a real MKMapItem.
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
    
    /// Full manual search for points of interest or addresses.
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
    
    /// The main "heartbeat" of navigation. Runs every location update to check for steps, turns, and reroutes.
    private func updateNavigationProgress(at location: CLLocation) {
        guard let route = currentRoute else { return }
        let steps = route.steps
        
        // 1. OFF-ROUTE DETECTION: Check if we are too far from the polyline
        let nearestPoint = findNearestPointOnPolyline(location.coordinate, polyline: route.polyline)
        let distanceToRoute = location.distance(from: CLLocation(latitude: nearestPoint.latitude, longitude: nearestPoint.longitude))
        
        if distanceToRoute > 150 { // 150m is the industry standard for "Off Route"
            // Do NOT reroute when stationary or very slow (stopped at a light, parking lot).
            // This prevents both false positives and the map going "bonkers" in car parks.
            let currentSpeed = location.speed // m/s
            if currentSpeed < 2.2 { // < ~5 mph
                return
            }
            if !self.isRerouting {
                self.isRerouting = true
                DebugLogger.shared.log("OFF ROUTE: \(Int(distanceToRoute))m. Rerouting...")
                announce("Off route. recalculating.")
                if let dest = destination {
                    Task {
                        await selectDestinationAndCalculateRoutes(to: dest, isRerouting: true)
                        if let newRoute = availableRoutes.first {
                            await startNavigation(with: newRoute, isReroute: true)
                        } else {
                            self.isRerouting = false
                        }
                    }
                } else {
                    self.isRerouting = false
                }
            }
            return
        }

        // Validate index to prevent out-of-bounds
        if self.currentStepIndex >= steps.count { return }
        
        // Skip empty polyline steps
        var currentStep = steps[self.currentStepIndex]
        while currentStep.polyline.pointCount == 0 && self.currentStepIndex < steps.count - 1 {
            self.currentStepIndex += 1
            currentStep = steps[self.currentStepIndex]
            self.lastDistanceToTurn = nil
        }
        
        let stepPolyline = currentStep.polyline
        let pointCount = stepPolyline.pointCount
        
        // 2. TURN PROXIMITY: Calculate distance to the END of the current step (the upcoming turn)
        if pointCount > 0 {
            let maneuverPoint = stepPolyline.points()[pointCount - 1].coordinate
            let maneuverLocation = CLLocation(latitude: maneuverPoint.latitude, longitude: maneuverPoint.longitude)
            let distanceToTurn = location.distance(from: maneuverLocation)
            
            self.distanceToNextTurn = distanceToTurn
            
            // Determine the actual active instruction (skip generic labels)
            var activeInstruction = currentStep.instructions
            if instructionIsGenericLabel(activeInstruction) {
                var nextIdx = self.currentStepIndex + 1
                while nextIdx < steps.count && steps[nextIdx].instructions.isEmpty {
                    nextIdx += 1
                }
                if nextIdx < steps.count {
                    activeInstruction = steps[nextIdx].instructions
                }
            }
            
            // Sync UI text immediately
            if !activeInstruction.isEmpty {
                self.nextManeuverInstruction = activeInstruction
                self.nextManeuverImageName = getImageForManeuver(activeInstruction)
            }
            
            // Trigger spoken alerts
            processVoiceAnnouncements(for: currentStepIndex, distanceToTurn: distanceToTurn, steps: steps, speed: location.speed)
            
            // 3. STEP PROGRESSION: Advance to next step once we pass the point
            let isMoving = location.speed > 2.0
            // Higher thresholds prevent premature advancement at traffic lights.
            // At speed (>20 m/s) use 40m; otherwise 25m.
            let advanceThreshold = location.speed > 20 ? 40.0 : 25.0
            
            if distanceToTurn < advanceThreshold && isMoving {
                advanceToNextStep(steps)
            } else if let prevDist = lastDistanceToTurn, distanceToTurn > prevDist + 20 && distanceToTurn < 80 && isMoving {
                // Distance increasing significantly after being very close: we passed the turn
                advanceToNextStep(steps)
            }
            
            lastDistanceToTurn = distanceToTurn
        }
        
        // 4. ETA REFRESH: Re-calculate ETA based on current progress vs expected route time
        let remainingDistance = route.steps[currentStepIndex...].reduce(0) { $0 + $1.distance }
        let progressPercent = 1.0 - (remainingDistance / route.distance)
        let totalExpectedTime = route.expectedTravelTime
        let newETA = Date().addingTimeInterval(max(30, totalExpectedTime * (1.0 - progressPercent)))
        self.eta = newETA
        
        // 5. PROACTIVE ARRIVAL: Announce "arriving" when within 10m of destination,
        //    regardless of whether step logic has completed.
        if !hasAnnouncedArrival, let dest = destination?.placemark.location {
            let distToDest = location.distance(from: dest)
            if distToDest <= 10.0 {
                hasAnnouncedArrival = true
                announce("You are arriving at your destination.")
            }
        }
    }
    
    /**
     Handles the logic for spoken turn-by-turn guidance. 
     Provides exactly two announcements per step: 
     1) Right after turning onto a new road (long distance)
     2) Right before the upcoming turn
     */
    private func processVoiceAnnouncements(for stepIndex: Int, distanceToTurn: Double, steps: [MKRoute.Step], speed: Double) {
        if stepStageFlags[stepIndex] == nil {
            stepStageFlags[stepIndex] = []
        }
        var flags = stepStageFlags[stepIndex]!
        
        // Use current instruction unless it's generic, then use next
        var activeInstruction = steps[stepIndex].instructions
        if instructionIsGenericLabel(activeInstruction) {
            var nextIdx = stepIndex + 1
            while nextIdx < steps.count && steps[nextIdx].instructions.isEmpty {
                nextIdx += 1
            }
            if nextIdx < steps.count {
                activeInstruction = steps[nextIdx].instructions
            }
        }
        
        if activeInstruction.isEmpty { return }

        // Immediate announcement threshold based on speed (higher speed = more warning)
        // Adjusting downwards to prevent "too early" announcements reported by user.
        // Highway (~50mph+): 220m (720ft / 0.15 mile) for the final "Turn" prompt.
        // City: 60m (~200ft) for the final prompt.
        let immediateThreshold = speed > 22.0 ? 220.0 : 60.0 
        
        // 1. Initial Advance Warning (Right after previous turn or start)
        if !flags.contains("initial") {
            flags.insert("initial")
            
            // Only give advance warning if we aren't already right on top of the turn
            if distanceToTurn > immediateThreshold + 50 {
                let formattedDist = formatDistance(distanceToTurn)
                if distanceToTurn > 3218 { // > 2 miles, give a "continue"
                    let routeName = currentRoute?.name ?? "the road"
                    announce("Continue on \(routeName) for \(formattedDist).")
                } else {
                    announce("In \(formattedDist), \(activeInstruction)")
                }
            }
        }
        
        // 2. Immediate Turning Warning (Right before the turn)
        if distanceToTurn <= immediateThreshold && !flags.contains("immediate") {
            flags.insert("immediate")
            announce(activeInstruction)
        }
        
        stepStageFlags[stepIndex] = flags
    }
    
    /// Updates the index and UI state for the next turn. 
    private func advanceToNextStep(_ steps: [MKRoute.Step]) {
        if self.currentStepIndex < steps.count - 1 {
            self.currentStepIndex += 1
            self.lastDistanceToTurn = nil
        } else {
            // We are on the final step — announce arrival when within 50m
            let dist = locationManager.latestLocation.flatMap { loc in
                destination?.placemark.location.map { loc.distance(from: $0) }
            } ?? 999
            if dist <= 50 {
                announce("You have arrived at your destination.")
                Task { await self.endNavigation() }
            }
        }
    }
    
    // MARK: - Navigation Math
    
    /// Finds the closest coordinate on the route's line to the user's current GPS ping.
    /// This is used for "snapping" the car to the road and detecting off-route deviations.
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
    
    /// Formats distance conversationally (e.g., "in half a mile" instead of "0.5 miles").
    private func formatDistance(_ meters: Double) -> String {
        let isMetric = UserDefaults.standard.string(forKey: "measurementSystem") == "Metric"
        if isMetric {
            if meters >= 1000 {
                let km = meters / 1000.0
                return formatDecimalForSpeech(km) + " kilometers"
            } else {
                // Round to nearest 50m for more natural speech
                return "\(Int(meters / 50) * 50) meters"
            }
        } else {
            let miles = meters / 1609.34
            if miles >= 2.0 {
                return formatDecimalForSpeech(miles) + " miles"
            } else if miles >= 1.0 {
                // Check for nice fractions first
                let rounded = (miles * 4).rounded() / 4
                switch rounded {
                case 1.0: return "1 mile"
                case 1.25: return "one and a quarter miles"
                case 1.5: return "one and a half miles"
                case 1.75: return "one and three quarter miles"
                default: return formatDecimalForSpeech(miles) + " miles"
                }
            } else if miles >= 0.4 {
                return "half a mile"
            } else if miles >= 0.2 {
                return "a quarter mile"
            } else {
                let feet = meters * 3.28084
                // Round to nearest 100ft
                return "\(Int(feet / 100) * 100) feet"
            }
        }
    }
    
    /// Converts a decimal number to a speakable English string so TTS doesn't say "2 5" for 2.5.
    private func formatDecimalForSpeech(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        let intPart = Int(rounded)
        let fracPart = Int((rounded - Double(intPart)) * 10 + 0.5)
        if fracPart == 0 {
            return "\(intPart)"
        }
        // e.g. 2.5 -> "2 point 5", 2.0 -> "2"
        return "\(intPart) point \(fracPart)"
    }
    
    // MARK: - Audio Session & Announcements
    
    /// Prepares the shared AVAudioSession for spoken navigation.
    /// Uses .mixWithOthers to allow Spotify/Music to continue playing while navigation speaks.
    private func setupAudioSession() {
        do {
            var options: AVAudioSession.CategoryOptions = [.duckOthers, .mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]
            if #available(iOS 17.0, *) {
                // Allows navigation to blend nicely with existing audio on iOS 17+
                options.insert(.interruptSpokenAudioAndMixWithOthers)
            }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: options)
            DebugLogger.shared.log("Audio Session Configured")
        } catch {
            DebugLogger.shared.log("Audio Session CONFIG ERROR: \(error.localizedDescription)")
        }
    }

    /// Triggers speech synthesis for a given string.
    func announce(_ message: String) {
        let rawVoiceVal = UserDefaults.standard.object(forKey: "voiceNavEnabled") as? Bool
        let voiceEnabled = rawVoiceVal ?? true
        
        guard voiceEnabled, !message.isEmpty else { return }
        
        // Sanitize punctuation that causes natural speech to sound robotic ("Period", "Full Stop")
        // NOTE: We only replace dots that are followed by a space to preserve decimals like "2.5"
        let cleanMessage = message
            .replacingOccurrences(of: "...", with: " ")
            .replacingOccurrences(of: "..", with: " ")
            .replacingOccurrences(of: ". ", with: " ") 
            .trimmingCharacters(in: .whitespaces)
        
        // Convert abbreviations like "Ave" to "Avenue" before speaking
        let expandedMessage = expandAbbreviations(cleanMessage)
        
        do {
            // Activate session so ducking (lowering music volume) kicks in
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            DebugLogger.shared.log("AUDIO ACTIVATE ERROR: \(error.localizedDescription)")
        }
        
        let utterance = AVSpeechUtterance(string: expandedMessage)
        
        // BUFFERING: Pre-utterance delay gives car Bluetooth systems ~500ms to 'wake up' 
        // before the voice starts, preventing the first word from being cut off.
        utterance.preUtteranceDelay = 0.5 
        utterance.postUtteranceDelay = 0.2
        
        // Attempt to use a premium/enhanced voice if installed
        if let premiumVoice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language == "en-US" && $0.quality == .enhanced }) {
            utterance.voice = premiumVoice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1.0
        
        speechSynthesizer.speak(utterance)
        DebugLogger.shared.log("NAV VOICE SENT: \(expandedMessage) (Voice enabled: \(voiceEnabled))")
    }

    /// Maps short address forms into full-blown words for synthesis.
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
            // \\b boundaries ensure we don't replace "W" inside the word "Way".
            let pattern = "\\b\(abbr)\\b\\.?"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: full)
            }
        }
        
        // Manual interstate fix
        if let regex = try? NSRegularExpression(pattern: "\\bI-", options: [.caseInsensitive]) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "Interstate ")
        }
        
        return result
    }

    // MARK: - AVSpeechSynthesizerDelegate
    
    /// Restores background music volume once a navigation announcement finishes.
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

    /// Disables the system idle timer to keep the screen on while the user is actively driving or following a route.
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = isRecording || isNavigating
    }
    
    /// Logic to select the appropriate glyph for a step based on keywords in the text.
    private func getImageForManeuver(_ instruction: String) -> String {
        let lower = instruction.lowercased()
        // U-turn MUST be checked before left/right to avoid matching "left" inside "u-turn left"
        if lower.contains("u-turn") || lower.contains("uturn") || lower.contains("u turn") { return "arrow.uturn.left" }
        if lower.contains("exit") { return "arrow.up.right.square" }
        if lower.contains("merge") { return "arrow.merge" }
        
        if lower.contains("slight right") || lower.contains("keep right") { return "arrow.up.right" }
        if lower.contains("slight left") || lower.contains("keep left") { return "arrow.up.left" }
        
        if lower.contains("sharp right") { return "arrow.turn.up.right" }
        if lower.contains("sharp left") { return "arrow.turn.up.left" }
        if lower.contains("right") { return "arrow.turn.up.right" }
        if lower.contains("left") { return "arrow.turn.up.left" }
        
        return "arrow.up"
    }

    /// Checks if an instruction is a generic starting/ending label.
    private func instructionIsGenericLabel(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("proceed to route") || lower.contains("starting route") || lower.contains("you have arrived")
    }

    // MARK: - Dynamic Rerouting (Traffic Awareness)
    
    /// Starts a recurring monitor that checks for more efficient route options.
    private func startRerouteTimer() {
        rerouteTimer?.invalidate()
        // Check for a faster route every 5 minutes during navigation
        rerouteTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkForFasterRoute()
            }
        }
    }

    private func checkForFasterRoute() async {
        guard let dest = destinationItem, let current = currentRoute else { return }
        
        let request = MKDirections.Request()
        request.source = MKMapItem.forCurrentLocation()
        request.destination = dest
        request.transportType = .automobile
        
        do {
            let directions = MKDirections(request: request)
            let response = try await directions.calculate()
            if let fastest = response.routes.first {
                let remainingTime = current.expectedTravelTime - (Date().timeIntervalSince(sessionStartTime ?? Date()))
                // If the new route saves more than 2 minutes, reroute
                if fastest.expectedTravelTime < remainingTime - 120 {
                    DebugLogger.shared.log("TRAFFIC ALERT: Faster route found.")
                    await startNavigation(to: dest) 
                }
            }
        } catch {
            // Silently fail traffic checks to avoid interrupting the drive
        }
    }

    // MARK: - Rerouting Logic
    private func checkOffRouteStatus(_ location: CLLocation) {
        guard let route = currentRoute, !isCalculatingReroute else { return }
        
        let distance = distanceToPolyline(location, polyline: route.polyline)
        
        if distance > 35.0 { 
            let timeSinceLastReroute = Date().timeIntervalSince(lastRerouteTime)
            
            if timeSinceLastReroute > 3.0 { 
                DebugLogger.shared.log("OFF ROUTE: \(Int(distance))m away. Rerouting.")
                lastRerouteTime = Date()
                isCalculatingReroute = true
                
                Task { @MainActor in
                    // FIXED: Using destinationItem which is defined at line 72
                    if let dest = self.destinationItem {
                        await self.startNavigation(to: dest) 
                    }
                    self.isCalculatingReroute = false
                }
            }
        }
    }

    private func distanceToPolyline(_ location: CLLocation, polyline: MKPolyline) -> CLLocationDistance {
        var minDistance: CLLocationDistance = .greatestFiniteMagnitude
        let points = polyline.points()
        for i in stride(from: 0, to: polyline.pointCount, by: 5) {
            let routeLocation = CLLocation(latitude: points[i].coordinate.latitude, longitude: points[i].coordinate.longitude)
            let distance = location.distance(from: routeLocation)
            if distance < minDistance { minDistance = distance }
            if minDistance < 10 { return minDistance }
        }
        return minDistance
    }
} // <--- THIS BRACE CLOSES THE DRIVEVIEWMODEL CLASS

// MARK: - File Scope Extensions
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

extension CLLocation {
    var speedMPH: Double {
        return max(0, speed * 2.23694)
    }
}

#if DEBUG || DEVELOPER_BUILD
extension DriveViewModel: SimulationDataSource {
    public func getNearestPointOnRoute(to coordinate: CLLocationCoordinate2D) -> (coordinate: CLLocationCoordinate2D, heading: Double?) {
        guard let route = self.currentRoute else { return (coordinate, nil) }
        
        let polyPoints = route.polyline.points()
        let count = route.polyline.pointCount
        if count < 2 { return (coordinate, nil) }
        
        var minDistance = CLLocationDistance.infinity
        var closest = polyPoints[0].coordinate
        var bestHeading: Double? = nil
        
        // Find nearest segment
        for i in 0..<count - 1 {
            let p1 = polyPoints[i].coordinate
            let p2 = polyPoints[i+1].coordinate
            
            let nearestOnSegment = nearestPointOnSegment(p: coordinate, v: p1, w: p2)
            let dist = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: CLLocation(latitude: nearestOnSegment.latitude, longitude: nearestOnSegment.longitude))
            
            if dist < minDistance {
                minDistance = dist
                closest = nearestOnSegment
                
                // Calculate heading of this segment
                let deltaY = p2.latitude - p1.latitude
                let deltaX = (p2.longitude - p1.longitude) * cos(p1.latitude * .pi / 180.0)
                var angle = atan2(deltaX, deltaY) * 180 / .pi
                if angle < 0 { angle += 360 }
                bestHeading = angle
            }
        }
        
        // Only snap if we are reasonably close to the route
        if minDistance < 100 {
            return (closest, bestHeading)
        }
        
        return (coordinate, nil)
    }
}
#endif