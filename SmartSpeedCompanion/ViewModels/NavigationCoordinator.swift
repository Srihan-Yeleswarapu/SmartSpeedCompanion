// NavigationCoordinator.swift
//
// Extracted from DriveViewModel so the navigation loop is independently
// unit-testable. Owns turn-by-turn progression, off-route detection, voice
// announcements, ETA computation, and the periodic reroute timer.
//
// DriveViewModel exposes a single @Published `navigationCoordinator` field
// here; session-recording state stays on DriveViewModel and is accessed via
// injected closures. To unit test: pass closures from your fixture — no need
// to construct a full DriveViewModel. The no-arg `init()` wires to no-op
// closures suitable for isolated coord tests; the parameterized `init` is
// what DriveViewModel uses to wire to production behavior.
//
// Design notes (per the extractor's design pass):
//   • Properties moved verbatim — @Published `nextManeuverInstruction`,
//     `nextManeuverImageName`, `distanceToNextTurn`, `eta`,
//     `distanceToDestination`, `nextManeuverCoordinate`, `currentRoute`,
//     `destination`, `destinationItem`, `isRerouting`,
//     `offRouteThreshold`, `lastRerouteTime`, `isCalculatingReroute`.
//   • Methods moved verbatim by name — `selectDestinationAndCalculateRoutes`,
//     `startNavigation(with:isReroute:)`, `startNavigation(to:)`,
//     `endNavigation`, `updateNavigationProgress(at:)`,
//     `checkOffRouteStatus(at:)`, `advanceToNextStep`, etc. Caller code is
//     updated to read `viewModel.navigationCoordinator.<X>` for nav state.
//   • Voice/TTS is private to this class — `AVSpeechSynthesizer`,
//     `setupAudioSession`, `announce`, `expandAbbreviations`, the delegate
//     hooks. We don't expose a VoiceAnnouncer protocol yet (kept simple per
//     the user's "don't over-engineer the extraction" guideline). Tests can
//     drive the rest of the pipeline by populating closures for state reads
//     and capturing side effects through injected closures alone.
//   • VM-owned state reads (`isRecording`, `nearbyCameras`, `availableRoutes`)
//     are injected as closures (NO DriveViewModel reference inside the
//     coordinator) so the coordinator remains unit-testable without the VM.
//   • VM-owned state writes (`availableRoutes` from MKDirections) flow back
//     through `availableRoutesSetter` so the coord never touches the VM
//     directly.
//   • Cross-cutting side effects (startSession, LiveActivity) are also
//     injected so a test coord can verify "startNavigation called
//     startSession exactly once when isRecording was false" without
//     spinning up a real session recorder.

import Foundation
import Combine
import MapKit
import AVFoundation
import UIKit

// MARK: - VoiceAnnouncer
//
// Minimal protocol so tests can drop in a recorded spy instead of touching
// AVAudioSession / AVSpeechSynthesizer. Production wires to the no-op
// default (which is the embedded `DefaultVoiceAnnouncer` below).
@MainActor
protocol VoiceAnnouncer: AnyObject {
    func announce(_ message: String)
    /// Deactivate the audio session cleanly when navigation ends.
    /// Keeps the session alive between announcements to avoid CarPlay
    /// audio pipeline re-negotiation glitches.
    func deactivateSession()
}

@MainActor
final class DefaultVoiceAnnouncer: NSObject, VoiceAnnouncer, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var voiceEnabled: Bool = true

    override init() {
        super.init()
        // `AVSpeechSynthesizer.delegate` is declared `weak` in the SDK,
        // so this assignment does NOT create a retain cycle between
        // DefaultVoiceAnnouncer and the synthesizer. Don't promote the
        // delegate ref to strong — it would leak this whole subtree for
        // the app lifetime once the navigation graph grows.
        synthesizer.delegate = self
        setupAudioSession()
    }

    /// CarPlay-friendly audio session options.
    ///
    /// KEY FIXES vs previous options:
    /// • Removed `.mixWithOthers` — it contradicts `.duckOthers` and causes
    ///   the CarPlay DSP to oscillate between mixing and ducking, producing
    ///   glitchy audio.
    /// • Removed `.allowBluetoothA2DP` — it routes speech through the media
    ///   A2DP channel instead of CarPlay's dedicated navigation voice
    ///   channel, which has separate volume control and lower latency.
    /// • Kept `.duckOthers` — lowers music volume during prompts.
    /// • Kept `.defaultToSpeaker` and `.interruptSpokenAudioAndMixWithOthers`.
    /// `.interruptSpokenAudioAndMixWithOthers` requires iOS 17+. Deployment
    /// target is 18.4, so no `@available` guard is needed.
    private static let navVoiceOptions: AVAudioSession.CategoryOptions = [
        .duckOthers,
        .defaultToSpeaker,
        .interruptSpokenAudioAndMixWithOthers
    ]

    /// Configure the audio session ONCE at init. Does NOT tear down and
    /// recreate for each utterance — that was causing CarPlay's audio
    /// pipeline to re-negotiate between every announcement.
    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: Self.navVoiceOptions)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            DebugLogger.shared.log("Audio Session Configured (spokenAudio, nav voice channel)")
        } catch {
            DebugLogger.shared.log("Audio Session CONFIG ERROR: \(error.localizedDescription)")
        }
    }

    /// Speak the given navigation message.
    ///
    /// FIX: No longer re-applies AVAudioSession category on every call
    /// (that was causing the CarPlay audio pipeline to re-negotiate
    /// between utterances). The session is set up once in `init()` and
    /// stays active until `deactivateSession()` is called.
    /// Also reduced `preUtteranceDelay` from 0.5 to 0.05 to eliminate
    /// the unnatural half-second gap before each announcement.
    func announce(_ message: String) {
        let expandedMessage = NavigationCoordinator.expandAbbreviations(message)

        let utterance = AVSpeechUtterance(string: expandedMessage)
        utterance.preUtteranceDelay = 0.05
        utterance.postUtteranceDelay = 0.1
        if let premiumVoice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language == "en-US" && $0.quality == .enhanced }) {
            utterance.voice = premiumVoice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1.0

        synthesizer.speak(utterance)
        DebugLogger.shared.log("NAV VOICE SENT: \(expandedMessage) (Voice enabled: \(voiceEnabled))")
    }

    /// Deactivate the audio session. Called when navigation ends so the
    /// CarPlay audio pipeline is freed and media can resume normally.
    /// NOT called between individual announcements — that caused the
    /// glitchy teardown-and-rebuild cycle.
    func deactivateSession() {
        synthesizer.stop(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        DebugLogger.shared.log("Audio Session Deactivated (navigation ended)")
    }

    // MARK: - AVSpeechSynthesizerDelegate

    /// FIX: Do NOT deactivate the audio session between utterances.
    /// Deactivation was causing CarPlay's audio pipeline to tear down
    /// and re-negotiate on every announcement, producing the severe
    /// stutter/glitch. The session is kept alive for the entire
    /// navigation and only deactivated in `deactivateSession()`.
    ///
    /// FIX: Do NOT deactivate the audio session between utterances.
    /// Deactivation was causing CarPlay's audio pipeline to tear down
    /// and re-negotiate on every announcement, producing the severe
    /// stutter/glitch. The session is kept alive for the entire
    /// navigation and only deactivated in `deactivateSession()`.
    ///
    /// Uses `print()` instead of `DebugLogger.shared.log()` to avoid
    /// Swift 6 data-race safety errors on non-Sendable utterance
    /// properties accessed from a nonisolated delegate context.
    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        #if DEBUG
        print("[SpeedyIO] NAV VOICE finished: \(utterance.speechString)")
        #endif
    }

    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        #if DEBUG
        print("[SpeedyIO] NAV VOICE cancelled: \(utterance.speechString)")
        #endif
    }
}

// MARK: - NavigationCoordinator

@MainActor
public final class NavigationCoordinator: ObservableObject {

    // MARK: - Published navigation state (verbatim move from DriveViewModel)

    /// Spoken and displayed text for the current navigation step (e.g., "Turn Left").
    @Published public var nextManeuverInstruction: String = ""
    /// SFSymbol name representing the type of turn or move.
    @Published public var nextManeuverImageName: String = "arrow.up"
    /// Meters remaining until the next maneuver point.
    @Published public var distanceToNextTurn: CLLocationDistance = 0
    /// Estimated time of arrival calculated based on expected route time and progress.
    @Published public var eta: Date? = nil
    /// Remaining route distance in meters to the active destination.
    @Published public var distanceToDestination: CLLocationDistance = 0
    /// Coordinate of the upcoming maneuver (last point of the current route step).
    @Published public var nextManeuverCoordinate: CLLocationCoordinate2D? = nil

    /// The MapKit route object being followed.
    @Published public var currentRoute: MKRoute? = nil
    /// The destination selected by the user.
    @Published public var destination: MKMapItem? = nil
    /// The destination as a MapItem mirror of `destination` for reroute paths
    /// (e.g. `checkForFasterRoute` and the 35m off-route detector).
    @Published public var destinationItem: MKMapItem? = nil

    /// Indicates if the system is currently calculating a reroute.
    @Published public var isRerouting: Bool = false

    // MARK: - Multi-Stop Route Support

    /// The ordered list of intermediate stops along the route.
    /// The final destination is NOT included here — it's stored in `destination`.
    /// Each stop has per-leg ETA and distance populated after route calculation.
    @Published public var routeStops: [RouteStop] = []

    /// The full set of route legs (origin → stop1, stop1 → stop2, ..., stopN → destination).
    /// Populated after a multi-stop route calculation.
    @Published public var routeLegs: [RouteLeg] = []

    /// Comparison of the current stop order against the most efficient ordering.
    /// Non-nil after `compareStopOrdering()` completes.
    @Published public var orderingComparison: OrderingComparison? = nil

    /// True while a multi-stop route calculation is in flight.
    @Published public var isCalculatingMultiStop: Bool = false

    /// The list of stops for the FINAL destination — this doesn't change when
    /// reordering, it's always the last item passed in `calculateMultiStopRoute`.
    private var finalDestinationMapItem: MKMapItem?

    // MARK: - Internal nav scratch

    /// Wall-clock timestamp of the most recent reroute request, used by the
    /// 35 m off-route detector in `checkOffRouteStatus(_:)` to throttle.
    private var lastRerouteTime: Date = .distantPast
    /// Latched while a reroute is in flight — prevents re-entrant reroutes.
    private var isCalculatingReroute: Bool = false
    /// Declared as a public-state-like threshold (kept private to mirror
    /// the original DriveViewModel.layout) but currently unused — the
    /// 35 m gate in `checkOffRouteStatus` is hard-coded; left here so
    /// future refactors can swap in this constant without a second pass.
    private let offRouteThreshold: CLLocationDistance = 20.0

    /// Index of the current MKRoute.Step being guided through.
    private var currentStepIndex: Int = 0
    /// Exponential moving average of `location.speed` used by the ETA
    /// estimator to prevent flickering from noisy GPS speed readings.
    private var smoothedSpeed: Double = 0
    /// Periodic 5-minute traffic-awareneness timer; runs only during nav.
    private var rerouteTimer: Timer?
    /// Per-step announcement gating: key is step index, value is a set of
    /// stage flags ("initial", "approaching", "immediate") so each cue
    /// fires AT MOST ONCE per step.
    private var stepStageFlags: [Int: Set<String>] = [:]
    /// Distance to turn on the previous tick, used to detect "passed the
    /// turn" (distance was very close, now it's climbing again).
    private var lastDistanceToTurn: CLLocationDistance? = nil
    /// Set<String> keys = "lat,lon" rounded to 4 decimals (~11 m precision)
    /// so the speed-camera voice alert fires ONCE per physical camera
    /// location even if the backend reconstructs the `SpeedCamera` struct
    /// repeatedly across location ticks.
    private var spokenCameraKeys: Set<String> = []

    /// Delegate hook used by CarPlay to keep its template stack in sync.
    /// Kept as a weak var to avoid retain cycles.
    public weak var navigationDelegate: NavigationActionDelegate?

    // MARK: - Injected collaborators (closure-based; no DriveViewModel coupling)

    /// True if a recording session is currently active. Used by
    /// `startNavigation(with:isReroute:)` to decide whether to auto-start one.
    private let isRecordingProvider: () -> Bool
    /// Most-recent list of nearby cameras, polled by the proximity alert
    /// inside `updateNavigationProgress(at:)`.
    private let nearbyCamerasProvider: () -> [SpeedCamera]
    /// Current `availableRoutes` snapshot, used ONLY inside the off-route
    /// callback closure path (the new-route read happens in the host VM).
    private let availableRoutesProvider: () -> [MKRoute]
    /// Sets the host VM's `availableRoutes` after an MKDirections call.
    private let availableRoutesSetter: ([MKRoute]) -> Void
    /// Triggers host-VM reroute logic when off-route is detected
    /// (used by both 150m and 35m thresholds).
    private let onRerouteRequest: (MKMapItem) async -> Void
    /// Starts a recording session (only invoked when `!isRecordingProvider()`).
    private let startSession: () -> Void
    /// Begins a Live Activity for the active nav session. The host VM is
    /// responsible for gating `#if !targetEnvironment(simulator)` since
    /// the activity call itself shouldn't be parameterized on host env.
    private let liveActivityStart: (Date) -> Void
    /// Ends the active Live Activity. Same simulator-gate caveat.
    private let liveActivityEnd: () -> Void
    /// Wall-clock start time of the active recording session, or `nil`
    /// before one is started. Used by `checkForFasterRoute()` for the
    /// original "remaining travel time" heuristic so the 2-minute
    /// reroute-savings threshold matches the previous byte-for-byte
    /// behavior. Injected because sessionStartTime lives on the host VM.
    private let sessionStartTimeProvider: () -> Date?

    /// Voice/TTS — default is the production `DefaultVoiceAnnouncer`
    /// (real AVSpeechSynthesizer + AVAudioSession). Tests pass a spy.
    private let voiceAnnouncer: VoiceAnnouncer

    // MARK: - Init

    /// Default no-arg init that wires every collaborator to a no-op.
    /// Allows constructing a coordinator in pure-unit-test scenarios
    /// BEFORE any host-VM or live service exists.
    public convenience init() {
        self.init(
            isRecordingProvider: { false },
            nearbyCamerasProvider: { [] },
            availableRoutesProvider: { [] },
            availableRoutesSetter: { _ in },
            onRerouteRequest: { _ in },
            startSession: { },
            liveActivityStart: { _ in },
            liveActivityEnd: { },
            voiceAnnouncer: DefaultVoiceAnnouncer()
        )
    }

    /// Fully-threaded init used by DriveViewModel.init(...) in production.
    /// Every closure has a sensible default so test fixtures only have
    /// to override the seams they care about.
    internal init(
        isRecordingProvider: @escaping () -> Bool = { false },
        nearbyCamerasProvider: @escaping () -> [SpeedCamera] = { [] },
        availableRoutesProvider: @escaping () -> [MKRoute] = { [] },
        availableRoutesSetter: @escaping ([MKRoute]) -> Void = { _ in },
        onRerouteRequest: @escaping (MKMapItem) async -> Void = { _ in },
        startSession: @escaping () -> Void = { },
        liveActivityStart: @escaping (Date) -> Void = { _ in },
        liveActivityEnd: @escaping () -> Void = { },
        sessionStartTimeProvider: @escaping () -> Date? = { nil },
        voiceAnnouncer: VoiceAnnouncer? = nil
    ) {
        self.isRecordingProvider = isRecordingProvider
        self.nearbyCamerasProvider = nearbyCamerasProvider
        self.availableRoutesProvider = availableRoutesProvider
        self.availableRoutesSetter = availableRoutesSetter
        self.onRerouteRequest = onRerouteRequest
        self.startSession = startSession
        self.liveActivityStart = liveActivityStart
        self.liveActivityEnd = liveActivityEnd
        self.sessionStartTimeProvider = sessionStartTimeProvider
        // Lazily construct the production announcer; tests override via
        // `voiceAnnouncer:` and that wins.
        self.voiceAnnouncer = voiceAnnouncer ?? DefaultVoiceAnnouncer()
    }

    // MARK: - Multi-Stop Route Support

    /// Adds an intermediate stop to the route at the given index.
    /// Index 0 inserts right after the origin; index `routeStops.count` appends.
    /// After adding, call `calculateMultiStopRoute()` to refresh ETAs.
    public func addStop(_ stop: RouteStop, at index: Int? = nil) {
        let idx = index.map { min(max($0, 0), routeStops.count) } ?? routeStops.count
        routeStops.insert(stop, at: idx)
    }

    /// Removes a stop by its ID.
    public func removeStop(id: UUID) {
        routeStops.removeAll { $0.id == id }
        routeLegs.removeAll()
        orderingComparison = nil
    }

    /// Moves a stop from one position to another (drag-to-reorder).
    public func moveStop(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex >= 0, sourceIndex < routeStops.count,
              destinationIndex >= 0, destinationIndex < routeStops.count else { return }
        let stop = routeStops.remove(at: sourceIndex)
        routeStops.insert(stop, at: destinationIndex)
    }

    /// Calculates the full multi-stop route from the current location through
    /// all intermediate stops to the final destination. Each leg is calculated
    /// separately so we capture per-leg ETA/distance data.
    ///
    /// Returns the overall best route for the final leg (origin→destination
    /// through all waypoints) and populates per-leg estimates on each stop.
    public func calculateMultiStopRoute() async -> MKRoute? {
        guard let finalDest = finalDestinationMapItem ?? destination else { return nil }
        isCalculatingMultiStop = true
        defer { isCalculatingMultiStop = false }

        let source = MKMapItem.forCurrentLocation()
        let allLegs = buildLegs(from: source, through: routeStops, to: finalDest)

        var computedLegs: [RouteLeg] = []
        var overallRoute: MKRoute? = nil
        var cumulativeTime: TimeInterval = 0

        // Calculate each leg sequentially so we can accumulate times.
        // Using a task group would be faster but MKDirections has a concurrency
        // limit; serial is more reliable.
        for (idx, leg) in allLegs.enumerated() {
            guard let legRoute = await calculateRouteBetween(
                source: leg.source,
                destination: leg.destination
            ) else { continue }

            let routeLeg = RouteLeg(
                sourceName: leg.sourceName,
                destinationName: leg.destinationName,
                travelTime: legRoute.expectedTravelTime,
                distance: legRoute.distance,
                route: legRoute
            )
            computedLegs.append(routeLeg)
            cumulativeTime += legRoute.expectedTravelTime

            // Populate the corresponding stop's per-leg data
            if idx < routeStops.count {
                routeStops[idx].travelTimeFromPrevious = legRoute.expectedTravelTime
                routeStops[idx].distanceFromPrevious = legRoute.distance
                routeStops[idx].cumulativeTravelTime = cumulativeTime
            }

            // Keep the first (overall) route for the nav engine
            if idx == 0 {
                overallRoute = legRoute
            }
        }

        self.routeLegs = computedLegs

        // Update ETA to reflect the total multi-stop journey
        if let overall = overallRoute {
            let totalTime = computedLegs.reduce(0) { $0 + $1.travelTime }
            self.eta = Date().addingTimeInterval(totalTime)
            self.distanceToDestination = computedLegs.reduce(0) { $0 + $1.distance }
        }

        return overallRoute
    }

    /// Compares the current stop ordering against an optimized arrangement.
    /// Uses Haversine (straight-line) distance for fast comparison instead of
    /// calling MKDirections for every permutation — this avoids Apple's rate
    /// limits and keeps the UI responsive. For <= 4 stops we exhaustively
    /// search all permutations; for > 4 we use a greedy nearest-neighbor
    /// heuristic. After finding the best order, a single real MKDirections
    /// call validates the time estimate.
    public func compareStopOrdering() async -> OrderingComparison? {
        guard let finalDest = finalDestinationMapItem ?? destination,
              !routeStops.isEmpty else { return nil }

        let source = MKMapItem.forCurrentLocation()
        let currentIDs = routeStops.map(\.id)

        // 1. Calculate the current order's total using REAL directions (one
        //    call per leg, needed for accurate current-ETA display).
        let currentTime = await totalTravelTimeForOrder(
            source: source,
            stops: routeStops,
            destination: finalDest
        )
        guard currentTime > 0 else { return nil }

        // 2. Find the best ordering using Haversine distance (fast, no
        //    network calls) to estimate which permutation is most efficient.
        var bestTime = currentTime
        var bestOrderIDs = currentIDs

        if routeStops.count <= 4 {
            // Exhaustive search using straight-line distance approximation.
            // This is extremely fast because it doesn't hit the network.
            let bestHaversineOrder = await findBestOrderHaversine(
                source: source,
                stops: routeStops,
                destination: finalDest
            )
            if let best = bestHaversineOrder {
                // Verify the best order with real directions
                let verifiedTime = await totalTravelTimeForOrder(
                    source: source,
                    stops: best,
                    destination: finalDest
                )
                if verifiedTime > 0 && verifiedTime < bestTime {
                    bestTime = verifiedTime
                    bestOrderIDs = best.map(\.id)
                }
            }
        } else {
            // Greedy nearest-neighbor using Haversine distance
            let bestNNOrder = await greedyNearestNeighborHaversine(
                source: source,
                stops: routeStops,
                destination: finalDest
            )
            if let best = bestNNOrder {
                let verifiedTime = await totalTravelTimeForOrder(
                    source: source,
                    stops: best,
                    destination: finalDest
                )
                if verifiedTime > 0 && verifiedTime < bestTime {
                    bestTime = verifiedTime
                    bestOrderIDs = best.map(\.id)
                }
            }
        }

        let comparison = OrderingComparison(
            currentOrder: currentIDs,
            currentTotalTime: currentTime,
            bestOrder: bestOrderIDs,
            bestTotalTime: bestTime
        )
        self.orderingComparison = comparison
        return comparison
    }

    /// Applies the best ordering found by `compareStopOrdering()`.
    /// Returns true if the order was changed.
    public func applyBestOrdering() -> Bool {
        guard let comparison = orderingComparison,
              comparison.canSaveTime else { return false }

        // Re-map the best order IDs back to RouteStop objects
        let stopMap = Dictionary(uniqueKeysWithValues: routeStops.map { ($0.id, $0) })
        var reordered: [RouteStop] = []
        for id in comparison.bestOrder {
            if let stop = stopMap[id] {
                reordered.append(stop)
            }
        }
        if reordered.count == routeStops.count {
            routeStops = reordered
            return true
        }
        return false
    }

    /// Clears all multi-stop state.
    public func clearMultiStopState() {
        routeStops.removeAll()
        routeLegs.removeAll()
        orderingComparison = nil
        isCalculatingMultiStop = false
        finalDestinationMapItem = nil
    }

    // MARK: - Multi-Stop Helpers

    /// Builds the list of (source, destination) pairs for each leg of the journey.
    private func buildLegs(
        from source: MKMapItem,
        through stops: [RouteStop],
        to destination: MKMapItem
    ) -> [(source: MKMapItem, destination: MKMapItem, sourceName: String, destinationName: String)] {
        var legs: [(source: MKMapItem, destination: MKMapItem, sourceName: String, destinationName: String)] = []
        var previous: (item: MKMapItem, name: String) = (source, "Current Location")

        for stop in stops {
            let destItem = stop.mapItem
            legs.append((
                source: previous.item,
                destination: destItem,
                sourceName: previous.name,
                destinationName: stop.name
            ))
            previous = (destItem, stop.name)
        }

        // Final leg: last stop → final destination
        legs.append((
            source: previous.item,
            destination: destination,
            sourceName: previous.name,
            destinationName: destination.name ?? "Destination"
        ))

        return legs
    }

    /// Calculates a route between two points.
    private func calculateRouteBetween(source: MKMapItem, destination: MKMapItem) async -> MKRoute? {
        let request = MKDirections.Request()
        request.source = source
        request.destination = destination
        request.transportType = .automobile
        request.requestsAlternateRoutes = false
        request.departureDate = .now

        if UserDefaults.standard.bool(forKey: "avoidHighways") {
            request.highwayPreference = .avoid
        }

        do {
            let directions = MKDirections(request: request)
            let response = try await directions.calculate()
            return response.routes.first
        } catch {
            DebugLogger.shared.log("Multi-stop leg calc FAILED: \(error.localizedDescription)")
            return nil
        }
    }

    /// Computes the total travel time for a specific ordering of stops + destination.
    private func totalTravelTimeForOrder(
        source: MKMapItem,
        stops: [RouteStop],
        destination: MKMapItem
    ) async -> TimeInterval {
        var total: TimeInterval = 0
        var previous = source

        for stop in stops {
            if let route = await calculateRouteBetween(source: previous, destination: stop.mapItem) {
                total += route.expectedTravelTime
                previous = stop.mapItem
            } else {
                return 0
            }
        }

        // Final leg
        if let route = await calculateRouteBetween(source: previous, destination: destination) {
            total += route.expectedTravelTime
        } else {
            return 0
        }

        return total
    }

    /// Generates all permutations of an array. Capped at 5 elements for safety.
    private func generatePermutations<T>(of array: [T]) -> [[T]] {
        guard array.count <= 5 else { return [array] }
        guard array.count > 1 else { return [array] }

        var result: [[T]] = []
        let arr = Array(array)

        func permute(_ prefix: [T], _ remaining: [T]) {
            if remaining.isEmpty {
                result.append(prefix)
                return
            }
            for i in 0..<remaining.count {
                var newRemaining = remaining
                let chosen = newRemaining.remove(at: i)
                permute(prefix + [chosen], newRemaining)
            }
        }

        permute([], arr)
        return result
    }

    /// Computes the Haversine distance between two coordinates in meters.
    private func haversineDistance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lon1 = from.longitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let lon2 = to.longitude * .pi / 180

        let dlat = lat2 - lat1
        let dlon = lon2 - lon1
        let a = sin(dlat / 2) * sin(dlat / 2) + cos(lat1) * cos(lat2) * sin(dlon / 2) * sin(dlon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return 6371000 * c // Earth radius in meters
    }

    /// Finds the best ordering using Haversine (straight-line) distance
    /// for all permutations (up to 4 stops, 24 permutations). Fast and
    /// avoids network calls entirely.
    private func findBestOrderHaversine(
        source: MKMapItem,
        stops: [RouteStop],
        destination: MKMapItem
    ) async -> [RouteStop]? {
        guard !stops.isEmpty else { return nil }
        let sourceCoord = source.placemark.coordinate
        let destCoord = destination.placemark.coordinate

        let permutations = generatePermutations(of: stops)
        var bestOrder: [RouteStop]? = nil
        var bestDistance = Double.greatestFiniteMagnitude

        for perm in permutations {
            var total: Double = 0
            var prev = sourceCoord

            for stop in perm {
                total += haversineDistance(from: prev, to: stop.coordinate)
                prev = stop.coordinate
            }
            total += haversineDistance(from: prev, to: destCoord)

            if total < bestDistance {
                bestDistance = total
                bestOrder = perm
            }
        }

        return bestOrder
    }

    /// Greedy nearest-neighbor heuristic using Haversine distance.
    /// Starts from the current location and always picks the closest
    /// remaining stop by straight-line distance.
    private func greedyNearestNeighborHaversine(
        source: MKMapItem,
        stops: [RouteStop],
        destination: MKMapItem
    ) async -> [RouteStop]? {
        guard !stops.isEmpty else { return nil }
        let sourceCoord = source.placemark.coordinate
        var unvisited = stops
        var ordered: [RouteStop] = []
        var current = sourceCoord

        while !unvisited.isEmpty {
            var bestIdx = 0
            var bestDist = Double.greatestFiniteMagnitude

            for (i, stop) in unvisited.enumerated() {
                let dist = haversineDistance(from: current, to: stop.coordinate)
                if dist < bestDist {
                    bestDist = dist
                    bestIdx = i
                }
            }

            let chosen = unvisited.remove(at: bestIdx)
            ordered.append(chosen)
            current = chosen.coordinate
        }

        return ordered
    }

    // MARK: - Route Calculation

    /// Requests route options from MapKit and triggers the selection view.
    /// Writes the resulting routes back via `availableRoutesSetter` (host
    /// VM stores them on `@Published var availableRoutes`).
    /// The `isSelectingRoute` flag (also host-VM state) is NOT touched
    /// here — that's a UI-state concern for the wrapper method.
    public func selectDestinationAndCalculateRoutes(to destination: MKMapItem, isRerouting: Bool = false) async {
        self.destination = destination
        self.finalDestinationMapItem = destination

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
            self.availableRoutesSetter(response.routes)
            DebugLogger.shared.log("Found \(response.routes.count) available routes\(isRerouting ? " (Fast Reroute)" : "")")
        } catch {
            DebugLogger.shared.log("Route calculation FAILED: \(error.localizedDescription)")
            print("Route error: \(error)")
        }

        if isRerouting {
            self.isRerouting = false
        }
    }

    // MARK: - Navigation Control

    /// Commences turn-by-turn guidance on a specific path. Sets `isNavigating`
    /// is the wrapper's responsibility (host-VM state); this method focuses
    /// on the navigation-tick-readable state.
    public func startNavigation(with route: MKRoute, isReroute: Bool = false) async {
        DebugLogger.shared.log("Navigation \(isReroute ? "REROUTED" : "STARTED") using Route (\(Int(route.distance))m)")
        self.currentRoute = route
        self.currentStepIndex = 0

        // Reset flags so we can re-announce the approach to the first turn
        self.stepStageFlags.removeAll()
        self.lastDistanceToTurn = nil
        self.spokenCameraKeys.removeAll()

        startRerouteTimer() // Every 5 minutes check for a faster path

        // Compute ETA from total journey (multi-stop-aware). When routeStops
        // is populated, `calculateMultiStopRoute` already set `self.eta` and
        // `self.distanceToDestination` to the sum of ALL leg values. Only
        // overwrite with the single-leg values when there are no intermediate
        // stops, so the ETA never shrinks to just the first leg after a stop
        // is added (code review bug).
        if routeStops.isEmpty {
            self.eta = Date().addingTimeInterval(route.expectedTravelTime)
            self.distanceToDestination = route.distance
        } else if eta == nil || distanceToDestination == 0 {
            // Falls back to route values if multi-stop data hasn't been
            // populated yet (edge case: stops added before route calc).
            self.eta = Date().addingTimeInterval(route.expectedTravelTime)
            self.distanceToDestination = route.distance
        }
        // When routeStops is non-empty and multi-stop data is present,
        // we keep the total ETA / distance untouched.

        // Automatically start recording the drive session if it hasn't been started manually
        if !self.isRecordingProvider() {
            self.startSession()
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

        // One-shot spoken ETA + distance announcement on initial navigation
        // start. Skips on reroute so we don't speak "Starting route to X"
        // every time the algorithm picks a faster path mid-drive. Uses
        // formatDistance() so the units match the user's chosen measurement
        // system, and DateFormatter(.short) so the time renders in 12-h or
        // 24-h per the device locale. announce() already honors the
        // voiceNavEnabled user toggle so a quieted user hears nothing.
        if !isReroute, let etaValue = self.eta {
            let destinationName = (destination?.name?.isEmpty == false)
                ? destination!.name!
                : "your destination"
            let distanceText = formatDistance(route.distance)
            let etaFormatter = DateFormatter()
            etaFormatter.timeStyle = .short
            etaFormatter.dateStyle = .none
            let timeText = etaFormatter.string(from: etaValue)
            announce("Starting route to \(destinationName), \(distanceText), arriving at \(timeText).")
        }

        // Display the route in a Live Activity on the lock screen.
        // Live Activities don't render in the iOS Simulator; the host
        // VM is expected to gate the injected closure on
        // `#if !targetEnvironment(simulator)`. That keeps the cleanest
        // cross-platform abstraction without leaking env concerns into
        // the coordinator's API.
        if !isReroute {
            self.liveActivityStart(Date())
        }
    }

    /// Alternative start navigation that triggers the calculation internally
    /// (legacy/direct support). The wrapper on the host VM is responsible
    /// for setting `isNavigating = true` and for starting a recording if
    /// none is in progress.
    public func startNavigation(to destination: MKMapItem) async {
        self.destination = destination
        if !self.isRecordingProvider() { self.startSession() }
        await navigationDelegate?.startNavigationTrigger(to: destination, route: nil as MKRoute?)
    }

    /// Terminates the current navigation session. Cleans all nav-owned
    /// state, notifies the navigationDelegate, and ends the Live Activity.
    /// The host VM wrapper is responsible for setting `isNavigating = false`
    /// BEFORE invoking this, for the `endSession()` recording call AFTER,
    /// and for honoring the simulator speaker gate.
    public func endNavigation() async {
        self.currentRoute = nil
        rerouteTimer?.invalidate()
        rerouteTimer = nil
        self.stepStageFlags.removeAll()
        self.spokenCameraKeys.removeAll()
        // Drop maneuver scratch state so the next navigation starts clean.
        // (Look Around scratch state removed in TestFlight 2.2.0 / FB10.)
        self.nextManeuverCoordinate = nil
        // Reset the smoothed-speed EMA so the next navigation starts from
        // a clean slate instead of fading from the previous drive's last
        // reading (which would briefly produce an inaccurate ETA).
        smoothedSpeed = 0

        // Deactivate the navigation voice audio session so media can
        // resume on the CarPlay audio channel. This is the ONLY place
        // the session is torn down — NOT between individual announcements
        // (which was causing the severe stutter/glitch).
        voiceAnnouncer.deactivateSession()

        await navigationDelegate?.endNavigationTrigger()

        self.liveActivityEnd()
    }

    /// Reset the portion of clearNativeMapCache() that lives in nav-coord.
    /// Called from `DriveViewModel.clearNativeMapCache()` for backward-compat
    /// so any future caller of the legacy public method still gets the
    /// pre-split behavior.
    public func clearNavScratchState() {
        self.nextManeuverCoordinate = nil
        self.distanceToDestination = 0
    }

    // MARK: - Core Navigation Loop (Apple Maps Parity)

    /// The main "heartbeat" of navigation. Runs every location update to
    /// check for steps, turns, and reroutes. Drives off-route detection,
    /// step progression, voice announcements, and ETA refresh.
    public func updateNavigationProgress(at location: CLLocation) {
        guard let route = currentRoute else { return }
        let steps = route.steps

        // 1. OFF-ROUTE DETECTION: Check if we are too far from the polyline
        let nearestPoint = findNearestPointOnPolyline(location.coordinate, polyline: route.polyline)
        let distanceToRoute = location.distance(from: CLLocation(latitude: nearestPoint.latitude, longitude: nearestPoint.longitude))

        if distanceToRoute > 150 { // 150 m is the industry standard for "Off Route"
            // Do NOT reroute when stationary or very slow (stopped at a light, parking lot).
            // This prevents both false positives and the map going "bonkers" in car parks.
            let currentSpeed = location.speed // m/s
            if currentSpeed < 2.2 { // < ~5 mph
                return
            }
            if !self.isRerouting {
                self.isRerouting = true
                DebugLogger.shared.log("OFF ROUTE: \(Int(distanceToRoute))m. Rerouting...")
                // Haptic: sharp warning buzz to alert the driver they've left the route
                HapticAlertManager.playNavigationNope()
                announce("Off route. recalculating.")
                if let dest = self.destination {
                    Task { @MainActor in
                        await self.onRerouteRequest(dest)
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
                advanceToNextStep(steps, at: location)
            } else if let prevDist = lastDistanceToTurn, distanceToTurn > prevDist + 20 && distanceToTurn < 80 && isMoving {
                // Distance increasing significantly after being very close: we passed the turn
                advanceToNextStep(steps, at: location)
            }

            lastDistanceToTurn = distanceToTurn
        }

        // 4. ETA REFRESH: Speed-based estimate using polyline-matched
        //    remaining distance + real-time speed from CoreLocation.
        //
        //    The OLD formula used a proportional estimate:
        //      remainingDist = steps[currentStepIndex...].reduce(0, +)
        //      eta = now + max(30, expectedTravelTime × remainingDist/totalDist)
        //
        //    BUG #1 (Step-index lag): currentStepIndex only advances when
        //    the user is within 15 m of the NEXT step's start coordinate.
        //    "Completed" distance lags actual travel by potentially several
        //    km, overstating remainingDist and inflating the ETA.
        //
        //    BUG #2 (No speed feedback): The proportion assumes constant
        //    expected speed forever. A driver on an open highway sees the
        //    same ETA as if stuck in traffic.
        //
        //    FIX: Walk the route polyline to find the user's actual
        //    position, compute remaining distance along the geometry, and
        //    use location.speed with an exponential moving average for a
        //    smooth live speed-based estimate that converges within seconds.
        let remainingDist = actualRemainingDistance(route: route, location: location)

        // Exponential moving average (alpha = 0.3) to dampen GPS speed
        // noise and prevent the ETA from visibly bouncing between values.
        let rawSpeed = location.speed
        if smoothedSpeed == 0, rawSpeed >= 0 {
            // CoreLocation returns -1.0 when speed is unavailable
            // (GPS lock lost, tunnel). Never seed the EMA with -1 —
            // it would contaminate the average for several ticks.
            smoothedSpeed = rawSpeed
        } else if rawSpeed >= 0 {
            smoothedSpeed = 0.3 * rawSpeed + 0.7 * smoothedSpeed
        }
        // If rawSpeed < 0, keep the previous smoothed value unchanged.
        let speed = max(smoothedSpeed, 1.0) // m/s, floor at walking speed (3.6 km/h)
        let liveEstimate = remainingDist / speed // seconds

        // Sanity clamp: cap the live estimate at 3× the expected
        // proportional remaining time so stop-and-go traffic doesn't
        // produce absurdly pessimistic ETAs (e.g. 83 min for 10 km at
        // 2 m/s when Apple expected 20 min).
        let proportion = remainingDist / route.distance
        let proportionalEstimate = route.expectedTravelTime * proportion
        let timeRemaining = min(liveEstimate, 3.0 * proportionalEstimate)

        self.eta = Date().addingTimeInterval(max(30, timeRemaining))
        // Mirror the polyline-matched distance onto @Published so Siri
        // `GetDistanceToDestinationIntent` reads the same accurate value.
        self.distanceToDestination = remainingDist

        // 5. SPEED CAMERA PROXIMITY ALERT
        //    The remaining arrival cue lives in advanceToNextStep at ~50 m,
        //    which is the only provisioning maintainers should expect going
        //    forward. The new alert speaks "Reduce speed, speed camera
        //    ahead." ONCE per physical camera within 800 ft (~245 m) on the
        //    route. spokenCameraKeys dedupes on "lat,lon" rounded to 4
        //    decimals (~11 m precision).
        for camera in nearbyCamerasProvider() {
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

    /// Monitor off-route state at finer granularity than the in-loop
    /// 150 m check. Called externally (DriveViewModel pumps it from the
    /// 500 ms GPS sink). Triggers a recalc via `onRerouteRequest` if the
    /// user drifts > 35 m AND the last reroute was more than 3 s ago.
    public func checkOffRouteStatus(at location: CLLocation) {
        guard let route = currentRoute, !isCalculatingReroute else { return }

        let distance = distanceToPolyline(location, polyline: route.polyline)

        if distance > 35.0 {
            let timeSinceLastReroute = Date().timeIntervalSince(lastRerouteTime)

            if timeSinceLastReroute > 3.0 {
                DebugLogger.shared.log("OFF ROUTE: \(Int(distance))m away. Rerouting.")
                // Haptic: warning buzz for the fine-grained off-route detector
                HapticAlertManager.playWarningBuzz()
                lastRerouteTime = Date()
                isCalculatingReroute = true

                Task { @MainActor in
                    if let dest = self.destinationItem {
                        await self.onRerouteRequest(dest)
                    }
                    self.isCalculatingReroute = false
                }
            }
        }
    }

    /**
     Handles the logic for spoken turn-by-turn guidance.
     Provides exactly two announcements per step:
     1) Right after turning onto a new road (long distance)
     2) Right before the upcoming turn

     Plus a "Merging in <dist>." / "In <dist>, <instr>." third cue at the
     643 m / 0.4 mi mark (TestFlight 2.2.x enhancement).
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
    /// `at location` is optional and only used by the final-step arrival
    /// detector so the arrival distance check has a `CLLocation` to use;
    /// callers passing nil (e.g. tests) will skip the arrival cue.
    private func advanceToNextStep(_ steps: [MKRoute.Step], at location: CLLocation? = nil) {
        if self.currentStepIndex < steps.count - 1 {
            self.currentStepIndex += 1
            self.lastDistanceToTurn = nil
        } else {
            // We are on the final step — announce arrival when within 50m
            let dist = location.flatMap { loc in
                destination?.placemark.location.map { loc.distance(from: $0) }
            } ?? .greatestFiniteMagnitude
            if dist <= 50 {
                // Haptic: arrival celebration
                HapticAlertManager.playNavigationPop()
                announce("You have arrived at your destination.")
                Task { await self.endNavigation() }
            }
        }
    }

    // MARK: - Navigation Math

    /// Finds the closest coordinate on the route's line to the user's
    /// current GPS ping. Used for "snapping" the car to the road and
    /// detecting off-route deviations.
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

    /// Strided polyline distance for the 35 m off-route detector. Walks
    /// every 5th point and short-circuits when an early-exit of < 10 m is
    /// found; less precise than `findNearestPointOnPolyline` but cheaper
    /// to call on every location tick.
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

    /// Walks the route polyline to find exactly where `location` sits on
    /// the path (nearest-segment matching, not step-index-based) and
    /// returns the remaining distance in meters from that point to the
    /// destination. This eliminates the step-index lag that caused the
    /// old proportional ETA to overstate remaining distance by several km.
    private func actualRemainingDistance(route: MKRoute, location: CLLocation) -> CLLocationDistance {
        let polyline = route.polyline
        let points = polyline.points()
        let count = polyline.pointCount
        guard count > 0 else { return route.distance }

        let userCoord = location.coordinate
        var minDist = CLLocationDistance.infinity
        var cumulativeDist: CLLocationDistance = 0
        var bestDistAlong: CLLocationDistance = route.distance

        for i in 0..<(count - 1) {
            let p1 = points[i].coordinate
            let p2 = points[i + 1].coordinate

            let segLen = CLLocation(latitude: p1.latitude, longitude: p1.longitude)
                .distance(from: CLLocation(latitude: p2.latitude, longitude: p2.longitude))

            let nearest = nearestPointOnSegment(p: userCoord, v: p1, w: p2)
            let dist = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
                .distance(from: CLLocation(latitude: nearest.latitude, longitude: nearest.longitude))

            if dist < minDist {
                minDist = dist
                let distAlongSeg = CLLocation(latitude: p1.latitude, longitude: p1.longitude)
                    .distance(from: CLLocation(latitude: nearest.latitude, longitude: nearest.longitude))
                bestDistAlong = cumulativeDist + distAlongSeg
            }

            cumulativeDist += segLen
        }

        return max(0, route.distance - bestDistAlong)
    }

    /// Formats distance conversationally (e.g., "in half a mile" instead of
    /// "0.5 miles").
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

    /// Converts a decimal number to a speakable English string so TTS
    /// doesn't say "2 5" for 2.5.
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

    // MARK: - Audio Announcements

    /// Spoken navigation message — routes through the injected
    /// `voiceAnnouncer` (production: real AVSpeechSynthesizer; tests: spy).
    /// The default announcer handles abbreviation expansion and per-call
    /// AVAudioSession defensive re-apply so callers don't have to know.
    private func announce(_ message: String) {
        voiceAnnouncer.announce(message)
    }

    /// Maps short address forms ("St", "Rd", "I-17") into full words
    /// for synthesis. Exposed statically so the announcement production
    /// path in DefaultVoiceAnnouncer can share the regex table without
    /// instantiating the coordinator.
    static func expandAbbreviations(_ text: String) -> String {
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

    // MARK: - Rerouting Timer

    /// Starts a recurring monitor that checks for more efficient route
    /// options. The 5-minute cadence runs while a route is active.
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
                // Mirror the original (VM-owned) heuristic: remaining
                // time = expectedTravelTime − (now − sessionStartTime).
                // Falls back to ETA-derived estimate when no recording
                // session is in flight (matches the `sessionStartTime ?? Date()`
                // original behavior in the most natural way).
                let sessionStart = sessionStartTimeProvider() ?? Date()
                let remainingTime = current.expectedTravelTime
                    - Date().timeIntervalSince(sessionStart)
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

    // MARK: - Route Segment Caching

    /// Grabs coordinates along the route and pre-fetches speed limit data
    /// for those points. Stays on the coordinator because it is purely a
    /// side effect of starting guidance.
    private func cacheRouteSegments(_ route: MKRoute) async {
        let polylinePoints = route.polyline.points()
        let pointCount = route.polyline.pointCount
        var coordinates: [CLLocationCoordinate2D] = []

        // Sample every 10 points (~150-300 m) for denser ahead-of-time
        // coverage than the old every-30-points (~500 m-1 km) cadence.
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
        // on ~500 ms-per-point round-trips on a long drive.
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

    // MARK: - Maneuver Glyph & Label Helpers

    /// Logic to select the appropriate glyph for a step based on keywords
    /// in the text.
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
}

// MARK: - NavigationActionDelegate
//
// Hook the host VM's existing delegate implementation gains. Lives here
// next to the coordinator so anyone reading the file sees both ends of
// the contract. The protocol is identical to the original definition
// in DriveViewModel.swift — moved verbatim to keep call-site behavior
// 1:1 and to encourage future testing without DriveViewModel.
public protocol NavigationActionDelegate: AnyObject {
    func startNavigationTrigger(to destination: MKMapItem, route: MKRoute?) async
    func endNavigationTrigger() async
    func searchDestinationTrigger(_ query: String) async -> [MKMapItem]
}
