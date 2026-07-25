import Foundation
import Combine
import SwiftData
import MapKit
import ActivityKit
import AVFoundation
import UIKit
import WidgetKit
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
    /// Standalone navigation coordinator owning route-calc, turn-by-turn
    /// progression, off-route detection, voice, ETA, and the reroute timer.
    /// See `NavigationCoordinator.swift`.
    @Published public var navigationCoordinator = NavigationCoordinator()
    
    // MARK: - Core Driving State
    /// User's current speed in MPH (always converted to MPH for the logic layer).
    @Published public var speed: Double = 0.0
    /// True heading when available; otherwise falls back to course (direction of travel).
    @Published public var currentHeading: Double? = nil
    /// Reverse-geocoded current road name from `RoadGeocoder` (e.g. "W Frye Rd").
    /// Populated by a ~10 sec throttled background geocode kicked off from the
    /// 500 ms GPS sink; the underlying `RoadGeocoder` already carries a 50 m
    /// grid-cell cache so the actual geocode call is effectively free when
    /// the driver stays on the same road. Surfaced on the HUD as a tiny
    /// monospaced chip above the START button. Hidden when nil (first
    /// 1-2 ticks before geocode resolves, end-of-drive cleardown, or
    /// geocode returning no thoroughfare on a parking-lot churn).
    @Published public var currentRoadName: String? = nil
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
    /// True while the user-triggered speed-limit refetch is in flight
    /// (`manualRefetchSpeedLimit()`, wired to a tap on the LimitSignView in
    /// MapWithHUDView). Drives the cyan ring + brightness pulse that gives
    /// the user immediate visual feedback when their tap landed.
    @Published public var isRefreshingSpeedLimit: Bool = false
    
    // MARK: - Navigation State
    /// Indicates if active turn-by-turn navigation is running.
    @Published public var isNavigating: Bool = false {
        didSet { updateIdleTimer() }
    }
    /// The MapKit route object being followed. Owned by NavigationCoordinator;
    /// writable get/set so legacy call sites that pass through `viewModel`
    /// remain source-compatible. Reactivity flows through `init()`'s
    /// `navigationCoordinator.objectWillChange → DriveViewModel.objectWillChange`
    /// sink.
    public var currentRoute: MKRoute? {
        get { navigationCoordinator.currentRoute }
        set { navigationCoordinator.currentRoute = newValue }
    }
    /// The destination selected by the user. Owned by NavigationCoordinator.
    public var destination: MKMapItem? {
        get { navigationCoordinator.destination }
        set { navigationCoordinator.destination = newValue }
    }
    /// Destination mirror used by the 35 m off-route detector and the
    /// 5-minute faster-route poll. Owned by NavigationCoordinator.
    public var destinationItem: MKMapItem? {
        get { navigationCoordinator.destinationItem }
        set { navigationCoordinator.destinationItem = newValue }
    }
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
    
    // MARK: - Route Selection State    /// Indicates if we are showing the alternate route selection screen.
    @Published public var isSelectingRoute: Bool = false
    /// Indicates if the system is currently calculating a reroute. Owned by
    /// NavigationCoordinator.
    public var isRerouting: Bool {
        get { navigationCoordinator.isRerouting }
        set { navigationCoordinator.isRerouting = newValue }
    }
    /// The list of alternate routes returned by MKDirections.
    @Published public var availableRoutes: [MKRoute] = [] 
    
    // MARK: - Drive Focus Mode
    /// When true, a distraction-free full-screen view replaces the normal HUD.
    @Published public var isDriveFocusMode: Bool = false
    
    // MARK: - Map Interaction State
    /// True if the user has manually panned the map away from current tracking.
    @Published public var isMapDetached: Bool = false
    
    // MARK: - Speed Alert Profiles
    /// All saved speed alert profiles. Loaded from SwiftData on init.
    @Published public var alertProfiles: [SpeedAlertProfile] = []
    /// True when the alert profiles list sheet should be presented.
    @Published public var showAlertProfilesSheet: Bool = false
    /// The profile currently being edited (nil = creating new).
    public var editingProfile: SpeedAlertProfile? = nil
    
    // MARK: - Named Locations
    /// All saved named locations. Loaded from SwiftData on init.
    @Published public var namedLocations: [NamedLocation] = []
    /// True when the name-location sheet should be presented.
    @Published public var showNameLocationSheet: Bool = false
    /// The coordinate the user tapped to name.
    public var namingCoordinate: CLLocationCoordinate2D? = nil
    /// The reverse-geocoded address at the naming coordinate.
    @Published public var namingAddress: String? = nil
    /// If non-nil, we are editing an existing named location.
    public var editingNamedLocation: NamedLocation? = nil
    
    // MARK: - Alert Profile Management
    
    /// Loads all alert profiles from SwiftData, activating the first one if none are active.
    public func loadAlertProfiles(context: ModelContext) {
        let descriptor = FetchDescriptor<SpeedAlertProfile>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        if let profiles = try? context.fetch(descriptor) {
            alertProfiles = profiles
            // Ensure at least one profile is active
            if !profiles.contains(where: { $0.isActive }), let first = profiles.first {
                activateProfile(first.id, context: context)
            }
        }
    }
    
    /// Creates a new speed alert profile with default buffer values, inserts into SwiftData, and activates it.
    @discardableResult
    public func createNewProfile(name: String, context: ModelContext) -> SpeedAlertProfile {
        let profile = SpeedAlertProfile(name: name, isActive: true)
        context.insert(profile)
        try? context.save()
        
        // Deactivate other profiles
        for p in alertProfiles { p.isActive = false }
        alertProfiles.append(profile)
        return profile
    }
    
    /// Activates a profile by ID, deactivating all others.
    public func activateProfile(_ id: UUID, context: ModelContext) {
        for p in alertProfiles {
            let wasActive = p.isActive
            p.isActive = (p.id == id)
            if p.id == id && !wasActive {
                // Apply the profile's default buffer to the speed engine
                speedEngine.userBuffer = p.defaultBuffer
            }
        }
        try? context.save()
        objectWillChange.send()
    }
    
    /// Deletes a profile from SwiftData.
    ///
    /// TestFlight 29-tester feedback: "I can't delete a speed profile".
    /// The previous implementation guarded on `alertProfiles.count > 1`
    /// which silently refused to delete the user's only — and therefore
    /// most-common — profile. New users ship with exactly ONE profile
    /// (`loadAlertProfiles(...)` only seeds one when the store is empty),
    /// so the swipe-to-delete they could discover was disabled for the
    /// exact case they tried it on.
    ///
    /// New behavior: always delete the requested row, then if the store
    /// would be left empty, seed a fresh "Default" profile so the speed
    /// alert system never has zero profiles (every code site assumes at
    /// least one is `.isActive`). If the deleted profile was active,
    /// promote either the newly seeded Default or the next remaining
    /// profile to active.
    public func deleteProfile(_ id: UUID, context: ModelContext) {
        guard let toDelete = alertProfiles.first(where: { $0.id == id }) else { return }
        let wasActive = toDelete.isActive
        context.delete(toDelete)
        try? context.save()
        alertProfiles.removeAll { $0.id == id }

        if alertProfiles.isEmpty {
            // Auto-seed a fresh Default. Treated identical to a fresh
            // install so the user keeps a working alert profile even
            // after deleting their last one. Same defaults as the
            // model initializer so thresholds match the rest of the app.
            //
            // NOTE: `createNewProfile(...)` flips `isActive: true` on
            // insert but does NOT mirror that into `speedEngine.userBuffer`
            // — only `activateProfile(_:context:)` does, and we don't
            // take that branch when we just wiped the last row. Apply
            // the new profile's default buffer directly so the alert
            // engine doesn't keep using the buffer from the now-deleted
            // profile (code review flagged this as a real, subtle bug).
            let seeded = createNewProfile(name: "Default", context: context)
            speedEngine.userBuffer = seeded.defaultBuffer
        } else if wasActive, let first = alertProfiles.first {
            // Active profile was deleted but others remain — promote
            // the first remaining to active so the alert engine keeps
            // using a non-zero buffer.
            activateProfile(first.id, context: context)
        }
    }
    
    // MARK: - Vehicle Profiles
    /// All saved vehicle profiles. Loaded from SwiftData on init.
    @Published public var vehicleProfiles: [VehicleProfile] = []
    /// True when the vehicle profile picker sheet should be presented.
    @Published public var showVehicleProfilePicker: Bool = false
    
    /// Loads all vehicle profiles from SwiftData, creating a default profile if none exist.
    public func loadVehicleProfiles(context: ModelContext) {
        let descriptor = FetchDescriptor<VehicleProfile>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        if let profiles = try? context.fetch(descriptor) {
            if profiles.isEmpty {
                // Create default "Primary Vehicle" profile from current @AppStorage values
                let ud = UserDefaults.standard
                let defaultProfile = VehicleProfile(
                    name: "Primary Vehicle",
                    isActive: true,
                    userBuffer: Int(ud.double(forKey: "userBuffer")),
                    audioAlertsEnabled: ud.bool(forKey: "audioAlertsEnabled"),
                    hapticAlertsEnabled: ud.bool(forKey: "hapticAlertsEnabled"),
                    hapticAlertStyle: ud.string(forKey: "hapticAlertStyle") ?? "strong",
                    avoidHighways: ud.bool(forKey: "avoidHighways"),
                    vehicleIconId: ud.string(forKey: "selectedVehicleIconId") ?? "default_blue",
                    measurementSystem: ud.string(forKey: "measurementSystem") ?? "Imperial"
                )
                context.insert(defaultProfile)
                try? context.save()
                vehicleProfiles = [defaultProfile]
            } else {
                vehicleProfiles = profiles
                // Ensure at least one profile is active
                if !profiles.contains(where: { $0.isActive }), let first = profiles.first {
                    activateVehicleProfile(first.id, context: context)
                }
            }
        }
    }
    
    /// Creates a new vehicle profile with default settings.
    @discardableResult
    public func createVehicleProfile(name: String, context: ModelContext) -> VehicleProfile {
        let profile = VehicleProfile(name: name, isActive: true)
        context.insert(profile)
        try? context.save()
        for p in vehicleProfiles { p.isActive = false }
        vehicleProfiles.append(profile)
        applyVehicleProfileSettings(profile)
        return profile
    }
    
    /// Activates a vehicle profile, applying its settings to the app.
    public func activateVehicleProfile(_ id: UUID, context: ModelContext) {
        for p in vehicleProfiles {
            p.isActive = (p.id == id)
            if p.isActive {
                applyVehicleProfileSettings(p)
            }
        }
        try? context.save()
        objectWillChange.send()
    }
    
    /// Deletes a vehicle profile. Cannot delete the last profile.
    public func deleteVehicleProfile(_ id: UUID, context: ModelContext) {
        guard vehicleProfiles.count > 1 else { return }
        if let toDelete = vehicleProfiles.first(where: { $0.id == id }) {
            let wasActive = toDelete.isActive
            context.delete(toDelete)
            try? context.save()
            vehicleProfiles.removeAll { $0.id == id }
            if wasActive, let first = vehicleProfiles.first {
                activateVehicleProfile(first.id, context: context)
            }
        }
    }
    
    /// Applies a vehicle profile's settings to the relevant UserDefaults and engines.
    private func applyVehicleProfileSettings(_ profile: VehicleProfile) {
        let ud = UserDefaults.standard
        ud.set(profile.userBuffer, forKey: "userBuffer")
        ud.set(profile.audioAlertsEnabled, forKey: "audioAlertsEnabled")
        ud.set(profile.hapticAlertsEnabled, forKey: "hapticAlertsEnabled")
        ud.set(profile.hapticAlertStyle, forKey: "hapticAlertStyle")
        ud.set(profile.avoidHighways, forKey: "avoidHighways")
        ud.set(profile.vehicleIconId, forKey: "selectedVehicleIconId")
        ud.set(profile.measurementSystem, forKey: "measurementSystem")
        selectedVehicleIconId = profile.vehicleIconId
        speedEngine.userBuffer = profile.userBuffer
        speedEngine.measurementSystem = profile.measurementSystem
    }
    
    // MARK: - Offline Map Regions
    /// Saved offline map regions. Persisted as JSON in UserDefaults.
    @Published public var savedOfflineRegions: [OfflineRegion] = []
    
    /// Loads saved offline regions from UserDefaults.
    public func loadOfflineRegions() {
        guard let data = UserDefaults.standard.data(forKey: "savedOfflineRegions"),
              let regions = try? JSONDecoder().decode([OfflineRegion].self, from: data) else {
            savedOfflineRegions = []
            return
        }
        savedOfflineRegions = regions
    }
    
    /// Saves the current map region as an offline area.
    public func saveOfflineRegion(named label: String, centerLat: Double, centerLon: Double) {
        let region = OfflineRegion(label: label, lat: centerLat, lon: centerLon)
        savedOfflineRegions.append(region)
        persistOfflineRegions()
    }
    
    /// Removes an offline region at the given index.
    public func removeOfflineRegion(at index: Int) {
        guard savedOfflineRegions.indices.contains(index) else { return }
        savedOfflineRegions.remove(at: index)
        persistOfflineRegions()
    }
    
    private func persistOfflineRegions() {
        if let data = try? JSONEncoder().encode(savedOfflineRegions) {
            UserDefaults.standard.set(data, forKey: "savedOfflineRegions")
        }
    }
    
    // MARK: - Deletion States
    /// Controls the UI prompt that asks to delete drives shorter than 90 seconds.
    @Published public var showShortSessionPrompt: Bool = false
    /// Temporary storage for a short session pending user deletion choice.
    public var lastSessionToPotentialDelete: DriveSession? = nil
 
    // MARK: - Guidance Details
    // The following properties are owned by NavigationCoordinator. They are
    // exposed as get/set forwarders on DriveViewModel so existing SwiftUI
    // bindings (`viewModel.nextManeuverInstruction`, etc.) keep compiling
    // unchanged. Changes originating in the coordinator flow back to
    // DriveViewModel subscribers through an `objectWillChange` sink installed
    // in `DriveViewModel.init()`.
    public var nextManeuverInstruction: String {
        get { navigationCoordinator.nextManeuverInstruction }
        set { navigationCoordinator.nextManeuverInstruction = newValue }
    }
    public var nextManeuverImageName: String {
        get { navigationCoordinator.nextManeuverImageName }
        set { navigationCoordinator.nextManeuverImageName = newValue }
    }
    public var distanceToNextTurn: CLLocationDistance {
        get { navigationCoordinator.distanceToNextTurn }
        set { navigationCoordinator.distanceToNextTurn = newValue }
    }
    public var eta: Date? {
        get { navigationCoordinator.eta }
        set { navigationCoordinator.eta = newValue }
    }

    /// Remaining route distance in meters to the active destination.
    /// Updated:
    ///   * `DriveViewModel.updateNavigationProgress(...)` (phone-only path)
    ///     every location tick — reuses the `remainingDistance` sum used to
    ///     compute the ETA.
    ///   * `CarPlayNavigationManager.evaluateNavigationProgress(...)` (CarPlay
    ///     path) every CarPlay HUD update — reuses the `totalDistance`
    ///     `Measurement` already passed to `CPTravelEstimates`.
    /// Siri `GetDistanceToDestinationIntent` reads this directly so both paths
    /// keep the same property fresh. Reset to 0 in `clearNativeMapCache()`
    /// (fresh-drive) and in `CarPlayNavigationManager.endNavigation()`
    /// (route ended).
    public var distanceToDestination: CLLocationDistance {
        get { navigationCoordinator.distanceToDestination }
        set { navigationCoordinator.distanceToDestination = newValue }
    }

    // MARK: - Native MapKit Features (see Apple Maps Server API notes in code comments)

    /// Coordinate of the upcoming maneuver (last point of the current route step).
    /// Consumed by `LiveMapView` to drop a maneuver annotation while navigating.
    /// (Look Around fetching was removed in TestFlight 2.2.0 / FB10.)
    public var nextManeuverCoordinate: CLLocationCoordinate2D? {
        get { navigationCoordinator.nextManeuverCoordinate }
        set { navigationCoordinator.nextManeuverCoordinate = newValue }
    }

    /// Last few MKMapItems returned by a "nearby amenities" category search.
    @Published public var nearbyAmenities: [MKMapItem] = []
    /// Short label for the active nearby search ("Gas", "Coffee", …) for HUD presentation.
    @Published public var nearbyAmenitiesQuery: String = ""

    /// Persisted map style (the same enum exposed to the Settings screen).
    public var mapStyle: MapStyleChoice {
        get { MapStyleChoice(rawValue: UserDefaults.standard.string(forKey: Self.mapStyleKey) ?? "") ?? .mutedDark }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.mapStyleKey) }
    }
    private static let mapStyleKey = "mapStyle"

    /// AVAudioSession.CategoryOptions bundle used by both
    /// `setupAudioSession()` (forced at app launch) and `announce()`
    /// (defensive re-apply before every utterance). Kept as a class-level
    /// static so the two paths can't drift if a future change adds e.g.
    /// `.allowBluetoothHFP` for car-kit routing. iOS 17+ only — project
    /// `deploymentTarget` is `18.0` per `project.yml`, so no
    /// `@available(iOS 17, *)` guard is needed.
    private static let navVoiceOptions: AVAudioSession.CategoryOptions = [
        .duckOthers,
        .mixWithOthers,
        .defaultToSpeaker,
        .allowBluetoothA2DP,
        .interruptSpokenAudioAndMixWithOthers
    ]




    /// Selected vehicle icon id. Persisted in UserDefaults. Defaults to "default_blue".
    @Published public var selectedVehicleIconId: String = UserDefaults.standard.string(forKey: "selectedVehicleIconId") ?? "default_blue" {
        didSet { UserDefaults.standard.set(selectedVehicleIconId, forKey: "selectedVehicleIconId") }
    }
    
    /// Whether to render Apple's POI glyphs (gas / food / parking / hospital / police)
    /// on top of the map. Persisted from Settings.
    public var showApplePOIs: Bool {
        get { UserDefaults.standard.object(forKey: "showApplePOIs") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "showApplePOIs") }
    }

    /// When true, the route polyline is drawn with a gradient (iOS 17+) tinted by
    /// the per-segment speed limit pulled from our local SQLite provider.
    public var gradientRouteEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "gradientRouteEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "gradientRouteEnabled") }
    }

    // NB: "3D flyover on long highways" was a UserDefaults-backed toggle
    // removed in 2.2.x. The flyover camera pitch is now baked into
    // `LiveMapView.updateSmartAltitude` as default behavior — the gate there
    // (`isNavigating && distanceToTurn > 4000 && speed > 50`) only fires when
    // it would look good, so we don't surface a confusing toggle in Settings.

    // MARK: - Camera pitch override (NEW: TestFlight 2.2.x redesign)
    //
    // User-controlled 2D / 3D pitch override. Persisted to UserDefaults.
    // When `.auto` (default) the existing `LiveMapView.updateSmartAltitude`
    // dynamic logic decides pitch from speed/nav/recording state. When
    // `.forced2D` / `.forced3D`, the override short-circuit in
    // `LiveMapView.updateUIView` flips the camera pitch immediately, AND
    // `updateSmartAltitude` clamps the auto-derived pitch so the user's
    // pin survives even mid-route when the auto logic would otherwise
    // zoom-in / pitch for a turn.
    //
    // SwiftUI Views observe the @Published raw value (string) for
    // reactivity; the typed `mapPitchMode` computed view is the public
    // API for callers that want the enum (button actions, MapKit glue).
    @Published public var mapPitchModeRaw: String = UserDefaults.standard.string(forKey: "mapPitchMode") ?? MapPitchMode.auto.rawValue

    /// User-facing computed view of `mapPitchModeRaw` with the typed enum.
    /// Persistent across launches via the "mapPitchMode" UserDefaults key.
    public var mapPitchMode: MapPitchMode {
        get { MapPitchMode(rawValue: mapPitchModeRaw) ?? .auto }
        set {
            mapPitchModeRaw = newValue.rawValue
            UserDefaults.standard.set(newValue.rawValue, forKey: "mapPitchMode")
        }
    }

    /// User-controlled camera pitch override (2D / 3D pill toggle in the map).
    /// The pill toggle in `MapWithHUDView.MapPitchToggleButton` cycles
    /// through these three modes. (The older "long-highway flyover" toggle
    /// was retired; that automatic pitch-up lives in LiveMapView now.)
    public enum MapPitchMode: String, CaseIterable, Identifiable, Sendable {
        /// Default. Lets `LiveMapView.updateSmartAltitude` decide — keeps
        /// the existing "pitch 0 idle / 45 navigating / 30 recording"
        /// behavior. Native MKMapView pinch-to-3D still works.
        case auto
        /// Pin to a flat top-down view (pitch 0°). Wins over auto-altitude.
        case forced2D
        /// Pin to a perspective view (pitch 45°). Wins over auto-altitude.
        case forced3D

        public var id: String { rawValue }

        /// Target pitch in degrees. Returns -1 as a sentinel meaning
        /// "auto-altitude decides" — callers MUST treat `targetPitch < 0`
        /// as no-op so they don't accidentally clamp the camera to a
        /// phantom -1° angle.
        public var targetPitch: Double {
            switch self {
            case .auto:     return -1
            case .forced2D: return 0
            case .forced3D: return 45
            }
        }

        /// Short label rendered inside the small inline pill toggle next
        /// to the search bar. "AUTO" reads slightly longer than "2D"/"3D"
        /// but fits the same 44×44 capsule without ellipsis.
        public var shortLabel: String {
            switch self {
            case .auto:     return "AUTO"
            case .forced2D: return "2D"
            case .forced3D: return "3D"
            }
        }
    }

    /// The four map styles the Settings screen offers, mapped to the native
    /// `MKMapConfiguration` family. Every choice below is on-device and free.
    public enum MapStyleChoice: String, CaseIterable, Identifiable, Sendable {
        case mutedDark      // MKStandardMapConfiguration(.realistic, .muted) — current default
        case standard       // MKStandardMapConfiguration(.flat, .default)
        case satellite      // MKImageryMapConfiguration(.realistic)
        case hybridFlyover  // MKHybridMapConfiguration(.realistic) with terrain

        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .mutedDark:     return "Muted (Dark)"
            case .standard:      return "Standard"
            case .satellite:     return "Satellite"
            case .hybridFlyover: return "Hybrid 3D"
            }
        }
    }

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
    /// Set<String> keys = "lat,lon" rounded to 4 decimals (~11 m precision)
    /// so the speed-camera voice alert fires ONCE per physical camera
    /// location even if the backend reconstructs the `SpeedCamera` struct
    /// repeatedly across location ticks. Reset in `startNavigation(...)`
    /// and `endNavigation()` so each fresh drive starts clean.
    private var spokenCameraKeys: Set<String> = []
    /// Wall-clock throttle for `manualRefetchSpeedLimit()` taps on the
    /// LimitSignView. Two back-to-back taps within a 600 ms window collapse
    /// to a single refetch so a double-tap from a frustrated user doesn't
    /// double-bill the network provider chain. Reset by the completion
    /// path inside the method itself.
    private var lastManualRefetchAt: Date = .distantPast
    private let manualRefetchThrottle: TimeInterval = 0.6
    /// Captures the user's heading degrees the last time we fired any
    /// "fresh" speed-limit fetch (heading-delta trigger). When the
    /// absolute bearing delta from `currentHeading` exceeds
    /// `headingDeltaFetchThresholdDeg`, the forward-facing pipeline
    /// fires another fetch -- this is an ADDITIONAL trigger alongside
    /// the existing speed/distance-driven fetches, not a replacement.
    /// Reset to nil in `endNavigation()` so each drive starts with a
    /// clean baseline.
    private var lastSpeedLimitFetchHeading: Double? = nil
    /// Threshold for the heading-delta trigger (degrees, absolute delta).
    /// 20° chosen so passing a cross street (e.g. Bush Rd at a 45° angle)
    /// triggers a fresh fetch before the GPS snaps to the adjacent road.
    /// The user's TestFlight feedback showed 30° was too lax — a 20+ degree
    /// bearing change often means the GPS is near a cross street whose speed
    /// limit differs from the road the user is actually on.
    private let headingDeltaFetchThresholdDeg: Double = 20



    // Current road name reverse-geocode throttle. The 10 sec wall-clock gate
    // stops us from re-issuing an async task on every 500 ms GPS tick while
    // cruising; `RoadGeocoder` itself deduplicates by 50 m coordinate grid so
    // when the gate fires the underlying call is usually a cache hit.
    private var lastRoadNameRefreshAt: Date = .distantPast
    private let roadNameRefreshInterval: TimeInterval = 10.0
    /// Monotonic search id for `searchNearby(category:)`. When the user
    /// taps Gas then Coffee rapidly, only the last response updates the
    /// card so the label always matches the visible results.
    private var nearbySearchGeneration: UInt64 = 0

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
        // In iOS Simulator there is no real GPS. Auto-start the simulation
        // loop so the app shows live data the moment the user hits Run.
        // Phoenix, AZ is the existing default location. We also bump
        // mockSpeed to 35 mph so the HUD shows a real-looking speed
        // instead of 0; the user can override from the Developer tab.
        #if targetEnvironment(simulator)
        SimulationManager.shared.mockSpeed = 35
        SimulationManager.shared.isSimulationActive = true
        DebugLogger.shared.log("DriveViewModel: auto-started simulator loop (iOS Simulator detected).")
        #endif
        #endif

        // Wire NavigationCoordinator with production collaborators. The
        // closures keep the coordinator free of any DriveViewModel
        // reference so it remains independently unit-testable. The
        // objectWillChange sink below forwards navigation publishes
        // into DriveViewModel so SwiftUI views reading forwarded
        // properties (e.g. `viewModel.nextManeuverImageName`) re-render
        // when the coordinator publishes — without this, computed
        // forwarders would only re-read on DriveViewModel's own
        // objectWillChange events.
        self.navigationCoordinator = NavigationCoordinator(
            isRecordingProvider: { [weak self] in self?.isRecording ?? false },
            nearbyCamerasProvider: { [weak self] in self?.nearbyCameras ?? [] },
            availableRoutesProvider: { [weak self] in self?.availableRoutes ?? [] },
            availableRoutesSetter: { [weak self] routes in self?.availableRoutes = routes },
            onRerouteRequest: { [weak self] dest in
                guard let self else { return }
                await self.selectDestinationAndCalculateRoutes(to: dest, isRerouting: true)
                if let first = self.availableRoutes.first {
                    await self.startNavigation(with: first, isReroute: true)
                } else {
                    self.navigationCoordinator.isRerouting = false
                }
            },
            startSession: { [weak self] in self?.startSession() },
            liveActivityStart: { date in
                #if !targetEnvironment(simulator)
                LiveActivityManager.shared.startActivity(sessionStartDate: date)
                #endif
            },
            liveActivityEnd: {
                #if !targetEnvironment(simulator)
                LiveActivityManager.shared.endActivity()
                #endif
            },
            sessionStartTimeProvider: { [weak self] in self?.sessionStartTime }
        )
        navigationCoordinator.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

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
        
        // SmartSpeedLimitService emits a typed SpeedLimitDataSource enum now; the UI still reads
        // a String here via .rawValue so we map at the binding boundary.
        SmartSpeedLimitService.shared.$dataSource
            .map { $0.rawValue }
            .receive(on: RunLoop.main)
            .assign(to: &$speedLimitSource)
        // SPEED CAMERA FEED: wire the SpeedCameraService shared publisher
        // onto @Published `nearbyCameras`. The previous code declared the
        // @Published but never bound it, so `updateNavigationProgress(...)`'s
        // voice alert had no data. SpeedCameraService.shared.$cameras is
        // already collected continuously as the driver moves; we just mirror
        // it onto this field so the voice alert + any future Mira UI can
        // read live values.
        SpeedCameraService.shared.$cameras
            .receive(on: RunLoop.main)
            .assign(to: &$nearbyCameras)
        
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
                // NOTE: we deliberately do NOT write `self.speed = location.speedMPH`
                // here. Two writers to `DriveViewModel.speed` (this GPS sink + the
                // `spdEngine.$speed.assign(to: &$speed)` pipeline above) caused a
                // unit-mismatch race that surfaced in the Live Activity / Widget
                // (Metric user could see "65 KMH" when the display speed was 65
                // mph). SpeedEngine is now the SOLE source of truth — it publishes
                // the active display unit (km/h when metric, mph when imperial) so
                // any view reading `viewModel.speed` always gets the right value.
                self.currentHeading = location.course >= 0 ? location.course : nil
                // 10-sec-throttled reverse-geocode to refresh
                // `currentRoadName`. RoadGeocoder.shared already carries a
                // 50 m grid-cell cache so when this gate fires the actual
                // `resolveRoadContext` call is usually a cache hit; the wall-
                // clock gate exists purely to keep async-task creation sane
                // for highway GPS cadences.
                let now = Date()
                if now.timeIntervalSince(self.lastRoadNameRefreshAt) >= self.roadNameRefreshInterval {
                    self.lastRoadNameRefreshAt = now
                    let coord = location.coordinate
                    Task { [weak self] in
                        await self?.refreshCurrentRoadName(at: coord)
                    }
                }
                // Advance turn-by-turn guidance (delegated to NavigationCoordinator).
                if self.isNavigating {
                    self.navigationCoordinator.updateNavigationProgress(at: location)
                }
                // Ensure Dynamic Island / Lock Screen stays fresh
                if self.isRecording || self.isNavigating {
                    self.updateLiveActivity()
                }
                if self.navigationCoordinator.currentRoute != nil {
                    self.navigationCoordinator.checkOffRouteStatus(at: location)
                }
                // Sync position to Firebase for potential multi-device/dashboard features
                AuthenticationManager.shared.updateLastLocation(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                // Heading-delta trigger: a 30+ degree bearing change
                // forces a fresh fetch even mid-route. Pre-cache of the
                // route ahead + heading-triggered re-fetches are the
                // two "more smooth" adds per the user's request; the
                // existing throttled fetches remain in place. Fire-and-
                // forget so we don't block the GPS sink block.
                Task { await self.evaluateHeadingDeltaTrigger() }
            }
            .store(in: &cancellables)

        // 4b. WIDGET SYNC: write `widgetSpeed` / `widgetLimit` / `widgetStatus`
        // / unit mirror to the App-Group suite every 5 seconds regardless of
        // recording/navigation state so the home-screen widget refreshes
        // even when the user is just driving without a session. Kept separate
        // from the Live Activity timer because (a) the Widget timeline reads
        // from App-Group defaults, not from an `Activity`, and (b) we want
        // the cadence to outlive the 1-Hz session-duration ticks that drive
        // `updateLiveActivity()` — hammering `WidgetCenter.reloadAllTimelines()`
        // from a 1-Hz timer exhausts WidgetKit's daily rate-limit budget.
        Timer.publish(every: 5.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                #if !targetEnvironment(simulator)
                self?.writeWidgetSnapshot()
                #endif
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
        // Live Activities don't render in the iOS Simulator; skip the call
        // so the simulator path doesn't trip an ActivityKit no-op warning.
        #if !targetEnvironment(simulator)
        LiveActivityManager.shared.startActivity(sessionStartDate: sessionStartTime ?? Date())
        #endif
        updateLiveActivity()
    }
    
    /// Updates the Dynamic Island and Lock Screen widgets with real-time driving data.
    private func updateLiveActivity() {
        // Live Activities don't render in the iOS Simulator. Calling the
        // manager from a simulator emits ActivityKit no-op warnings every
        // 1-second tick — gate the call so the simulator path is silent.
        #if !targetEnvironment(simulator)
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
        #endif
        // NOTE: widget snapshot writes (speed/limit/status/unit mirror) are
        // intentionally NOT called from this method. They live on a dedicated
        // 5-second Timer in `DriveViewModel.init` so the cadence stays steady
        // and `WidgetCenter.reloadAllTimelines()` isn't hammered by the 1-Hz
        // session-timer path that also drives this method.
    }

    /// Mirrors the current drive state into `group.com.smartspeedcompanion.app`
    /// for `SpeedWidget.Provider.getTimeline` to read. Cheap to call —
    /// `UserDefaults.set(...)` is in-memory after the first write —
    /// so we eagerly call from the 5-second Live Activity tick AND from
    /// the 1-Hz session-duration tick below (see `sessionTimer`).
    public func writeWidgetSnapshot() {
        let suite = UserDefaults(suiteName: SpeedFormatting.appGroupSuite)
        suite?.set(Int(speed), forKey: "widgetSpeed")
        suite?.set(limit, forKey: "widgetLimit")
        suite?.set(status.rawValue, forKey: "widgetStatus")
        // Re-mirror the unit each call so an in-app UNITS toggle
        // (Settings onChange writes once already, but a stale widget
        // update from before that changeover self-heals on the next
        // tick without requiring an app restart).
        suite?.set(
            SpeedFormatting.measurementSystem(),
            forKey: SpeedFormatting.widgetMeasurementSystemAppGroupKey
        )
        // WidgetKit is iOS 14+ so it's safe to call unconditionally.
        // `reloadAllTimelines()` is the official API that tells WidgetKit
        // "your cached entries are stale, ask providers again" — without
        // this call, the widget may show stale numbers for up to its
        // natural refresh interval.
        WidgetCenter.shared.reloadAllTimelines()
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
        
        // Requirement 4: If we stop session, we also end the directions.
        if isNavigating {
            Task { @MainActor in
                await endNavigation()
            }
        }
        
        // Only stop Live Activity if navigation isn't using it too.
        if !isNavigating {
            // Live Activities don't render in the iOS Simulator; the matching
            // start call is gated, so gate the stop call to keep the path silent.
            #if !targetEnvironment(simulator)
            LiveActivityManager.shared.endActivity()
            #endif
            Task {
                // Wipe speed limit cache to save memory once drive is over
                await ArizonaSpeedLimitService.shared.clearCache()
            }
            // Free amenity + maneuver-coordinate transient state between
            // drives so the next navigation starts clean.
            // (Look-Around scratch state was removed in TestFlight 2.2.0 / FB10.)
            clearNativeMapCache()
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
        saveRecentSearch(destination.name ?? "Unknown Location")
        await navigationCoordinator.selectDestinationAndCalculateRoutes(to: destination, isRerouting: isRerouting)
        if !isRerouting {
            self.isSelectingRoute = true
        }
    }
    
    // MARK: - Navigation Control
    
    /// Commences turn-by-turn guidance on a specific path.
    public func startNavigation(with route: MKRoute, isReroute: Bool = false) async {
        self.isSelectingRoute = false
        self.isNavigating = true
        await navigationCoordinator.startNavigation(with: route, isReroute: isReroute)
    }

    /// Grabs coordinates along the route and pre-fetches speed limit data for those points.
    private func cacheRouteSegments(_ route: MKRoute) async {
        let polylinePoints = route.polyline.points()
        let pointCount = route.polyline.pointCount
        var coordinates: [CLLocationCoordinate2D] = []

        // Sample every 10 points (~150-300m) for denser ahead-of-time
        // coverage than the old every-30-points (~500m-1km) cadence.
        // User asked that we "fetch all the roads the user will be on
        // ahead of time" -- denser sampling catches on-ramps, exits,
        // and named cross-roads that sparse sampling skipped.
        for i in stride(from: 0, to: pointCount, by: 10) {
            coordinates.append(polylinePoints[i].coordinate)
        }
        if pointCount > 0 { coordinates.append(polylinePoints[pointCount-1].coordinate) }

        // Layer 1: SQLite pre-cache. Existing path, no network hit.
        await ArizonaSpeedLimitService.shared.preCacheRoute(coordinates: coordinates)

        // Layer 2: live-provider ahead-of-time pre-fetch. Fires
        // `SmartSpeedLimitService.prefetchAheadOfRoute(...)` for every
        // sample coord with bounded concurrency (4 in flight). Skips
        // the continuity guard so the user's actual GPS-driven
        // continuity is untouched -- see SpeedLimitService.swift doc on
        // `prefetchAheadOfRoute` for why bypassing the guard matters.
        //
        // The pre-cache runs in a fire-and-let-finish Task so this
        // method returns promptly and `startNavigation` isn't blocked
        // on ~500ms-per-point round-trips on a long drive.
        let coordinatesForWarmup = coordinates
        let roadNameForWarmup: String? = nil
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                var inflight = 0
                for coord in coordinatesForWarmup {
                    group.addTask {
                        await SmartSpeedLimitService.shared.prefetchAheadOfRoute(
                            at: coord, roadName: roadNameForWarmup
                        )
                    }
                    inflight += 1
                    if inflight >= 4 {
                        await group.next()
                        inflight = 0
                    }
                }
                await group.waitForAll()
            }
        }
    }
    
    /// Alternative start navigation that triggers the calculation internally (legacy/direct support).
    public func startNavigation(to destination: MKMapItem) async {
        self.isNavigating = true
        await navigationCoordinator.startNavigation(to: destination)
    }
    
    /// Persianality: Track recently searched locations to show in search history.
    public func saveRecentSearch(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Remove if already exists so we can move it to the top
        if let index = recentSearches.firstIndex(of: trimmed) {
            recentSearches.remove(at: index)
        }
        
        // Insert at the beginning
        recentSearches.insert(trimmed, at: 0)
        
        // Cap at 10 items
        if recentSearches.count > 10 {
            recentSearches.removeLast()
        }
        UserDefaults.standard.set(recentSearches, forKey: "recentSearches")
    }

    /// Removes a specific recent search query from history and persists to UserDefaults.
    public func removeRecentSearch(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let index = recentSearches.firstIndex(of: trimmed) {
            recentSearches.remove(at: index)
        }
        UserDefaults.standard.set(recentSearches, forKey: "recentSearches")
    }

    /// Terminates the current navigation session. The orchestration
    /// pipeline lives here: set `isNavigating = false`, ask the coordinator
    /// to clean its own state and notify the navigation delegate, then end
    /// the recording session if one was running. Live-activity teardown
    /// is delegated to the coordinator via the `liveActivityEnd` closure
    /// in `init()`.
    public func endNavigation() async {
        self.isNavigating = false
        await navigationCoordinator.endNavigation()
        if isRecording {
            endSession()
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
        if pointCount > 0 {                let maneuverPoint = stepPolyline.points()[pointCount - 1].coordinate
                let maneuverLocation = CLLocation(latitude: maneuverPoint.latitude, longitude: maneuverPoint.longitude)
                let distanceToTurn = location.distance(from: maneuverLocation)
                self.distanceToNextTurn = distanceToTurn

            // Surface the maneuver coordinate so LiveMapView can drop a
            // maneuver annotation on the route. CLLocationCoordinate2D is
            // `Sendable`, so we publish it directly. (Look Around fetches
            // were removed in TestFlight 2.2.0 / FB10.)
            let maneuverCoord = stepPolyline.points()[pointCount - 1].coordinate
            self.nextManeuverCoordinate = maneuverCoord

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
        // Same `remainingDistance` sum is what Siri
        // `GetDistanceToDestinationIntent` speaks back; mirror it onto the
        // @Published `distanceToDestination` so the Intent sees live values
        // even when the user is on the phone (no CarPlay).
        self.distanceToDestination = remainingDistance

        // 5. SPEED CAMERA PROXIMITY ALERT (replaces the prior
        //    "PROACTIVE ARRIVAL < 10 m" voice cue, which fired within the
        //    same 50 m window as `advanceToNextStep` and produced a
        //    "arriving..." / "arrived..." double-buzz). The remaining
        //    arrival cue lives in advanceToNextStep at ~50 m, which is the
        //    only provisioning maintainers should expect going forward.
        //
        //    The new alert speaks "Reduce speed, speed camera ahead." ONCE
        //    per physical camera within 800 ft (~245 m) on the route.
        //    spokenCameraKeys dedupes on "lat,lon" rounded to 4 decimals
        //    (~11 m precision), so backend reconstructions of SpeedCamera
        //    structs across location ticks do NOT trigger re-announces.
        for camera in nearbyCameras {
            let distToCamera = location.distance(
                from: CLLocation(latitude: camera.coordinate.latitude,
                                 longitude: camera.coordinate.longitude)
            )
            if distToCamera <= 245.0 {
                let key = String(format: "%.4f,%.4f",
                                 camera.coordinate.latitude,
                                 camera.coordinate.longitude)
                if spokenCameraKeys.insert(key).inserted {
                    announce("Reduce speed, speed camera ahead.")
                    break // one announcement per location tick max
                }
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
        
        // 1.5 Approaching Warning (TestFlight 2.2.x enhancement): the third
        // cue, sitting ~643 m / 0.4 mi out from the maneuver — between the
        // initial "advance" and the immediate "turn" cues. Fires ONCE per
        // step (gated by the new "approaching" flag in stepStageFlags),
        // and only AFTER `initial` has spoken while we're still above the
        // immediate threshold — that gates the cue to genuine long steps
        // (e.g. blocks >= 643 m) so we don't compress three back-to-back
        // utterances on short turns.
        //
        // Highway maneuvers whose instruction text contains "Merge onto" /
        // "Take exit" get a "Merging in .4 mile" prefix so the user hears
        // a clean highway-transition reminder BEFORE the bare instruction
        // fires at 220 m (e.g. "Take exit 142"). City/local steps fall
        // through to the existing "In <dist>, <instruction>" phrasing.
        if flags.contains("initial") &&
           distanceToTurn <= 643.0 &&
           distanceToTurn > immediateThreshold &&
           !flags.contains("approaching") {
            flags.insert("approaching")
            let approachingDist = formatDistance(distanceToTurn)
            let lower = activeInstruction.lowercased()
            if lower.contains("merge onto") || lower.contains("take exit") {
                announce("Merging in \(approachingDist).")
            } else {
                announce("In \(approachingDist), \(activeInstruction)")
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
    ///
    /// Includes the deactivate → setCategory → reactivate cycle so the
    /// `.spokenAudio` mode actually sticks:
    ///
    ///   `AlertEngine.init(...)` runs INSIDE `DriveViewModel.init(...)` (the
    ///   alert engine is constructed here as `let alrtEngine = ...`) and
    ///   calls `setCategory(.playback, mode: .default) + setActive(true)`
    ///   immediately, so before we run, the session is already active in
    ///   `.default` mode for the speeding tone. iOS only honours a mode
    ///   change when the session transitions inactive → active — without
    ///   the explicit `setActive(false)` first, the call below updates the
    ///   recorded category in logs but leaves the underlying routing in
    ///   `.default` mode, which sends AVSpeechSynthesizer output to the
    ///   ringer/earpiece speaker at low volume. TestFlight 2.2.x feedback
    ///   was "navigation messages not heard"; the `DebugLogger` line
    ///   "NAV VOICE SENT" was still firing normally — the speech was sent,
    ///   just routed through the wrong output path.
    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // Guarded release: drop the existing session only if there's
            // an active audio-app competitor OR the session sits in a
            // mode/category that would reject the upcoming `.spokenAudio`
            // transition (e.g. AlertEngine's `.default` mode from init).
            // Skips the unnecessary release for the common cold-launch /
            // quiet drive case so opening the app while Spotify is playing
            // doesn't yank the user's music out of focus for ~100 ms.
            if session.isOtherAudioPlaying || session.mode != .spokenAudio || session.category != .playback {
                if (try? session.setActive(false, options: .notifyOthersOnDeactivation)) == nil {
                    DebugLogger.shared.log("Audio Session pre-deactivate failed (continuing)")
                }
            }

            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                options: Self.navVoiceOptions
            )

            try session.setActive(true, options: .notifyOthersOnDeactivation)
            DebugLogger.shared.log("Audio Session Configured (.spokenAudio forced at launch)")
        } catch {
            DebugLogger.shared.log("Audio Session CONFIG ERROR: \(error.localizedDescription)")
        }
    }    // MARK: - Native MapKit Feature Helpers

    // TestFlight 2.2.0 (FB10): Look Around removed.
    //   - `loadLookAroundForUpcomingTurn()` and `loadLookAroundForDestination()`
    //     deleted — both called `LookAroundCoordinator.shared.requestScene(at:)`
    //     which talks to Apple's MKLookAroundSceneRequest per maneuver.
    //   - `LookAroundCoordinator.shared` is no longer referenced from this
    //     file; the coordinator itself has been deleted from the project.

    /// Free-text + category "nearby" search. The native MKLocalSearch API is
    /// fully on-device (this is `/v1/search`'s free equivalent in Apple Maps
    /// Server API terms) — no Apple Maps Server token required.
    public func searchNearby(category: MKPointOfInterestCategory) async {
        // Bump the generation early so any earlier in-flight search becomes
        // a no-op when it eventually returns.
        nearbySearchGeneration &+= 1
        let myGeneration = nearbySearchGeneration

        self.nearbyAmenitiesQuery = Self.labelForCategory(category)
        let request = MKLocalSearch.Request()
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [category])
        let center = locationManager.latestLocation?.coordinate
            ?? destination?.placemark.coordinate
            ?? CLLocationCoordinate2D()
        request.region = MKCoordinateRegion(
            center: center,
            latitudinalMeters: 10000,
            longitudinalMeters: 10000
        )
        let search = MKLocalSearch(request: request)
        do {
            let response = try await search.start()
            // Drop the response if a newer search has been kicked off since.
            guard myGeneration == nearbySearchGeneration else { return }
            self.nearbyAmenities = Array(response.mapItems.prefix(8))
        } catch {
            guard myGeneration == nearbySearchGeneration else { return }
            self.nearbyAmenities = []
        }
    }

    /// Convenience label for the active nearby search.
    private static func labelForCategory(_ category: MKPointOfInterestCategory) -> String {
        switch category {
        case .gasStation:  return "Gas"
        case .restaurant:  return "Food"
        case .cafe:        return "Coffee"
        case .parking:     return "Parking"
        case .hospital:    return "Hospital"
        case .pharmacy:    return "Pharmacy"
        case .atm:         return "ATM"
        case .bank:        return "Bank"
        case .evCharger:  return "Charge"
        default:           return "Nearby"
        }
    }

    /// User-triggered re-fetch of the speed-limit answer for the current
    /// location. Bypasses `SpeeEDLimitResponseCache` via
    /// `forceRefresh: true` so the live provider chain + SQLite fallback
    /// run fresh and surface any newer answer. Wired to a tap on the
    /// `LimitSignView` (see `MapWithHUDView.swift`).
    ///
    /// Visual feedback: toggles `isRefreshingSpeedLimit` @Published
    /// while the call is in flight so the `LimitSignView` can show a
    /// scale pulse and the user immediately sees their tap landed (even
    /// when the new answer matches the old one).
    public func manualRefetchSpeedLimit() async {
        let now = Date()
        guard now.timeIntervalSince(lastManualRefetchAt) >= manualRefetchThrottle else { return }
        lastManualRefetchAt = now

        // No fresh GPS sample yet (cold launch, denied auth, etc.) — the
        //                                              call would silently go to (0,0).
        // Bail rather than stash a stale answer over the user's
        // last-known value.
        guard let coord = locationManager.latestLocation?.coordinate else {
            DebugLogger.shared.log("manualRefetchSpeedLimit: skipped (no current GPS fix).")
            return
        }

        isRefreshingSpeedLimit = true
        defer { isRefreshingSpeedLimit = false }

        // Call SmartSpeedLimitService directly so we hit the freshly-plumbed
        // `forceRefresh:` parameter on the new TestFlight 2.2.x signature
        // (SpeedEngine's wrapper still routes through the same shared
        // service, so the @Published `limit` binding picks up the new
        // value on the next tick automatically).
        // currentSpeedMph is the GPS-derived speed converted from m/s → mph
        // (matches the 2.23694 constant used elsewhere in the codebase, e.g.
        // SpeedEngine.input). Pass 0 when we have no fresh GPS fix so the
        // continuity guard's physics-override rule never auto-commits just
        // because the candidate happens to match a stale speed value — the
        // user tapped this button precisely because they suspected the
        // displayed answer was wrong, so we want the strictest path.
        let gpsMps = locationManager.latestLocation?.speed ?? 0
        let currentSpeedMph = gpsMps * 2.23694

        _ = await SmartSpeedLimitService.shared.updateSpeedLimit(
            at: coord,
            heading: currentHeading,
            currentSpeedMph: currentSpeedMph,
            forceRefresh: true
        )
        DebugLogger.shared.log("manualRefetchSpeedLimit: completed (limit=\(limit)).")
    }

    // MARK: - Heading-delta trigger
    //
    // Whenever the user's bearing shifts by >30° from the last
    // speed-limit fetch (post-turn behavior forces this fresh), fire a
    // normal `SmartSpeedLimitService.updateSpeedLimit(...)` call. This
    // is ADDITIVE to the existing GPS-distance / speed-throttled fetch
    // pipeline -- it doesn't replace anything, just adds a new trigger
    // so the next HUD reflects the new road the user just turned onto.
    // The existing throttle + cache wins keep network pressure
    // unchanged in steady state.

    /// Robust shortest-path bearing delta in [-180, 180]. Wraps the
    /// raw `(to - from)` modulo 360 and corrects for the ±180
    /// ambiguity so a 350-→10° turn reads as 20°, not -340°.
    private func angleDelta(from a: Double, to b: Double) -> Double {
        var diff = (b - a).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff -= 360 }
        if diff < -180 { diff += 360 }
        return diff
    }

    /// Fires a fresh speed-limit fetch when the user's bearing has
    /// shifted by more than `headingDeltaFetchThresholdDeg` (default
    /// 20°) since the last fetch. The fetch goes through the full
    /// `SmartSpeedLimitService.updateSpeedLimit(...)` pipeline (NOT a
    /// parallel sqlite-only path) so the continuity guard sees the new
    /// bearing and the cache benefits from warm-up. forceRefresh=false
    /// so a recent correct answer on the same road still wins.
    ///
    /// Snaps `lastSpeedLimitFetchHeading` to `currentHeading` AFTER
    /// firing -- so a 90° turn is ONE trigger then needs another 20°
    /// change to re-fire (avoids spurious re-fires on near-stationary
    /// oscillation back to the original bearing).
    private func evaluateHeadingDeltaTrigger() async {
        guard let heading = currentHeading else { return }
        // Defense-in-depth against stationary compass drift. The
        // existing init-level Course-over-Compass already falls back to
        // compass trueHeading when loc.speed < 2 m/s, but a stopped car
        // + momentarily-rotated phone (e.g. user adjusting a mounted
        // phone at a stoplight) can spike compass 30-45° and fire a
        // spurious refetch. A hard speed gate here cuts that case.
        let mpsGate = locationManager.latestLocation?.speed ?? 0
        guard mpsGate > 2.0 else { return }
        let baseline: Double
        if let last = lastSpeedLimitFetchHeading {
            baseline = last
        } else {
            // First GPS tick with a usable heading -- baseline it so we
            // don't fire a redundant fetch. The SpeedEngine's normal
            // distance-throttled fetches are doing the first-fetch job.
            lastSpeedLimitFetchHeading = heading
            return
        }
        let delta = abs(angleDelta(from: baseline, to: heading))
        guard delta > headingDeltaFetchThresholdDeg else { return }
        guard let coord = locationManager.latestLocation?.coordinate else { return }

        let mps = locationManager.latestLocation?.speed ?? 0
        let currentSpeedMph = mps * 2.23694

        _ = await SmartSpeedLimitService.shared.updateSpeedLimit(
            at: coord,
            heading: heading,
            currentSpeedMph: currentSpeedMph,
            roadName: nil,
            forceRefresh: false
        )
        lastSpeedLimitFetchHeading = heading
        DebugLogger.shared.log("DriveViewModel: heading-delta refetch (delta=\(Int(delta))°).")
    }

    /// Promotes an MKMapItem out to Apple Maps for full-fidelity directions,
    /// live traffic detail, and Look Around the moment the user wants it.
    /// Used when the user taps "Open in Maps" in the HUD.
    public func openInAppleMaps(_ item: MKMapItem) {
        item.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }

    /// Reverse-geocode a coordinate via the on-device CLGeocoder (this is
    /// `/v1/reverseGeocode`'s free equivalent). We use it during session end
    /// to enrich recorded journeys with a human-readable city/state string.
    public func reverseGeocode(_ coord: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard let p = placemarks.first else { return nil }
            let parts = [p.locality, p.administrativeArea].compactMap { $0 }
            return parts.isEmpty ? p.name : parts.joined(separator: ", ")
        } catch {
            return nil
        }
    }

    /// Throttled reverse-geocode that populates `currentRoadName`. Called
    /// from the 500 ms GPS sink; typically fires once per 10 sec while
    /// driving. We intentionally do NOT clear `currentRoadName` when the
    /// geocode returns no thoroughfare (e.g. parking-lot churn after a
    /// destination arrival) — keeping the last known road name prevents
    /// the HUD chip from flickering off when the user briefly drives through
    /// an unnamed lot before re-entering a named street.
    func refreshCurrentRoadName(at coordinate: CLLocationCoordinate2D) async {
        if let context = await RoadGeocoder.shared.resolveRoadContext(at: coordinate),
           let name = context.roadName,
           !name.isEmpty,
           name != currentRoadName {
            currentRoadName = name
        }
    }

    /// Resets maneuver coordinate + amenity transient state for a fresh drive.
    /// (Look Around scratch state was removed in TestFlight 2.2.0 / FB10.)
    // MARK: - Named Locations
    
    /// Loads all saved named locations from SwiftData.
    public func loadNamedLocations(context: ModelContext) {
        let fetchDescriptor = FetchDescriptor<NamedLocation>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        if let results = try? context.fetch(fetchDescriptor) {
            self.namedLocations = results
        }
    }
    
    /// Saves a new named location at the given coordinate. If `address` is provided,
    /// skips the reverse-geocode to avoid a redundant network call.
    public func saveNamedLocation(name: String, coordinate: CLLocationCoordinate2D, context: ModelContext, address: String? = nil) {
        if let addr = address {
            // Address already resolved — synchronous path
            let namedLocation = NamedLocation(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude, address: addr)
            context.insert(namedLocation)
            try? context.save()
            self.namedLocations.insert(namedLocation, at: 0)
        } else {
            // No address provided — reverse-geocode asynchronously
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let geocoder = CLGeocoder()
            Task { @MainActor in
                let resolvedAddress: String?
                if let placemarks = try? await geocoder.reverseGeocodeLocation(location), let placemark = placemarks.first {
                    let parts = [placemark.subThoroughfare, placemark.thoroughfare, placemark.locality, placemark.administrativeArea].compactMap { $0 }
                    resolvedAddress = parts.isEmpty ? nil : parts.joined(separator: " ")
                } else {
                    resolvedAddress = nil
                }
                let namedLocation = NamedLocation(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude, address: resolvedAddress)
                context.insert(namedLocation)
                try? context.save()
                self.namedLocations.insert(namedLocation, at: 0)
            }
        }
    }
    
    /// Deletes a named location by id.
    public func deleteNamedLocation(_ id: UUID, context: ModelContext) {
        guard let location = namedLocations.first(where: { $0.id == id }) else { return }
        context.delete(location)
        try? context.save()
        namedLocations.removeAll { $0.id == id }
    }
    
    /// Checks if a coordinate has a saved name using a ~20m tolerance.
    public func namedLocation(for coordinate: CLLocationCoordinate2D) -> String? {
        let coord = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        for loc in namedLocations {
            let saved = CLLocation(latitude: loc.latitude, longitude: loc.longitude)
            if coord.distance(from: saved) < 20 {
                return loc.name
            }
        }
        return nil
    }
    
    /// Presents the naming sheet for a given coordinate. Reverse-geocodes to pre-fill the address.
    public func presentNameLocationSheet(for coordinate: CLLocationCoordinate2D) {
        self.namingCoordinate = coordinate
        self.editingNamedLocation = nil
        self.namingAddress = nil
        
        // Reverse geocode to show the address
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let geocoder = CLGeocoder()
        Task {
            if let placemarks = try? await geocoder.reverseGeocodeLocation(location), let placemark = placemarks.first {
                let parts = [placemark.subThoroughfare, placemark.thoroughfare, placemark.locality, placemark.administrativeArea].compactMap { $0 }
                self.namingAddress = parts.isEmpty ? placemark.name : parts.joined(separator: " ")
            }
            self.showNameLocationSheet = true
        }
    }
    
    public func clearNativeMapCache() {
        self.nearbyAmenities = []
        self.nearbyAmenitiesQuery = ""
        self.nextManeuverCoordinate = nil
        self.distanceToDestination = 0
        self.currentRoadName = nil
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

        // Defensive: re-apply `.spokenAudio` mode just before every utterance so
        // anything that flipped the session back to `.default` mid-drive (CarPlay
        // audio route change, AlertEngine tone reset, an external interruption
        // handler, a Bluetooth re-pair) is corrected immediately. Cheap no-op when
        // the state already matches, and applies the same option set used in
        // setupAudioSession() so behavior stays consistent across launch and
        // per-utterance calls.
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(
            .playback,
            mode: .spokenAudio,
            options: Self.navVoiceOptions
        )

        // Only activate audio session if other audio is playing — that way we
        // don't redundantly grab focus during a quiet drive but ensure
        // `.duckOthers` kicks in during a Spotify/Music session.
        let shouldActivate = audioSession.isOtherAudioPlaying
        if shouldActivate {
            do {
                // Activate session so ducking (lowering music volume) kicks in
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                DebugLogger.shared.log("AUDIO ACTIVATE ERROR: \(error.localizedDescription)")
            }
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
    // NOTE: checkOffRouteStatus and distanceToPolyline were moved to
    // NavigationCoordinator. The private copies that lived here referenced
    // isCalculatingReroute and lastRerouteTime which are now owned by the
    // coordinator. The GPS sink calls navigationCoordinator.checkOffRouteStatus(at:)
    // directly, so this dead code is safe to remove.
} // <--- THIS BRACE CLOSES THE DRIVEVIEWMODEL CLASS

// MARK: - MKLocalSearchCompleterDelegate
// Properly handle Swift concurrency: delegate methods are nonisolated (called off-main-thread)
// so we must hop to @MainActor when updating @Published properties
extension DriveViewModel: MKLocalSearchCompleterDelegate {
    nonisolated public func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        // Hop to MainActor to update @Published property
        Task { @MainActor [weak self] in
            self?.searchCompletions = completer.results
        }
    }
    
    nonisolated public func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        // Log on background thread, no UI update needed
        print("Completer error: \(error)")
    }
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