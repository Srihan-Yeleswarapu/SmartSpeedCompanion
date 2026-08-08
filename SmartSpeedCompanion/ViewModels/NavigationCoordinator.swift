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
//     session ownership (via AudioSessionCoordinator), `announce`,
//     `expandAbbreviations`, the delegate hooks. We don't expose a
//     VoiceAnnouncer protocol yet (kept simple per the user's "don't
//     over-engineer the extraction" guideline). Tests can drive the
//     rest of the pipeline by populating closures for state reads and
//     capturing side effects through injected closures alone.
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
    var isSpeaking: Bool { get }
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
    /// Cues can be generated while a previous prompt is still rendering.
    /// Keep the newest pending cue instead of dropping it or asking AVSpeechSynthesizer
    /// to overlap utterances, which is a common source of chopped CarPlay TTS.
    private var pendingMessages: [String] = []
    /// True once the shared AVAudioSession has been acquired for the
    /// current navigation, so `announce()` doesn't re-begin (and re-count)
    /// the session for every utterance. Cleared by `deactivateSession()`.
    private var sessionHeld = false

    var isSpeaking: Bool {
        synthesizer.isSpeaking || synthesizer.isPaused
    }

    override init() {
        super.init()
        synthesizer.usesApplicationAudioSession = true
        // `AVSpeechSynthesizer.delegate` is declared `weak` in the SDK,
        // so this assignment does NOT create a retain cycle between
        // DefaultVoiceAnnouncer and the synthesizer. Don't promote the
        // delegate ref to strong — it would leak this whole subtree for
        // the app lifetime once the navigation graph grows.
        synthesizer.delegate = self
    }

    /// Speak the given navigation message.
    ///
    /// The shared AVAudioSession is acquired ONCE on the first accepted cue
    /// and held until `deactivateSession()` — see `AudioSessionCoordinator`.
    /// Previously each utterance (re)configured the session, forcing
    /// CarPlay's audio pipeline to re-negotiate between announcements and
    /// stutter.
    /// Also reduced `preUtteranceDelay` from 0.5 to 0.05 to eliminate
    /// the unnatural half-second gap before each announcement.
    func announce(_ message: String) {
        guard UserDefaults.standard.object(forKey: "voiceNavEnabled") as? Bool ?? true else { return }
        // Never ask AVSpeechSynthesizer to overlap utterances. Queue a small
        // number of fresh cues and drain them only after the current render
        // completes; this prevents the chopped/half-second CarPlay output
        // caused by overlapping or rapidly replaced speech streams.
        let expandedMessage = NavigationCoordinator.expandAbbreviations(message)
        if isSpeaking {
            // Keep only the newest cue. A FIFO can speak a turn that was
            // already passed while an earlier prompt was rendering; the
            // latest navigation state is always the useful one.
            pendingMessages = [expandedMessage]
            return
        }

        speakNow(expandedMessage)
    }

    private func speakNow(_ expandedMessage: String) {
        // Acquire the session lazily on the first accepted cue. This avoids
        // activating and ducking other audio at app launch; the session
        // remains stable until navigation ends. After a phone call or Siri
        // interruption, reactivation is performed here without changing the
        // category or route policy.
        if sessionHeld {
            AudioSessionCoordinator.shared.ensureActive()
        } else {
            AudioSessionCoordinator.shared.beginNavigation()
            sessionHeld = true
        }

        let utterance = AVSpeechUtterance(string: expandedMessage)
        utterance.preUtteranceDelay = 0.05
        utterance.postUtteranceDelay = 0.1
        // CARPLAY-AUDIO FIX v2: v1 was BUGGED — the CarPlay branch used
        // `AVSpeechSynthesisVoice(language: "en-US")`, which returns the
        // device's DEFAULT en-US voice. On iOS 16+ that default is a
        // premium/enhanced neural voice — a reported stutter source on some
        // CarPlay head units (speech breaks into syllable fragments over the
        // car speakers while the phone stays clean, and while our own
        // AVAudioEngine beeps through the SAME session stay perfect). v2
        // explicitly enumerates voices and selects a `.default`-quality
        // (compact) en-US voice over CarPlay; the premium `.enhanced` voice
        // is only used on the phone where it sounds better.
        if !isCarPlayRouted,
           let premiumVoice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language == "en-US" && $0.quality == .enhanced }) {
            utterance.voice = premiumVoice
        } else {
            utterance.voice = Self.carPlayReliableVoice()
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1.0

        synthesizer.speak(utterance)
        DebugLogger.shared.log("NAV VOICE SENT: \(expandedMessage) (Voice enabled: \(voiceEnabled))")
    }

    private func drainPendingMessage() {
        guard !isSpeaking, !pendingMessages.isEmpty else { return }
        let next = pendingMessages.removeFirst()
        speakNow(next)
    }

    /// True when audio is routed to a CarPlay head unit. Used to select a
    /// more reliable TTS voice over the car — enhanced-quality voices are a
    /// known CarPlay stutter source (see `announce`).
    private var isCarPlayRouted: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .carAudio }
    }

    /// A reliable, compact-quality en-US voice for CarPlay. Premium and
    /// enhanced neural voices are a reported stutter source on some head
    /// units (syllable-chopped TTS over the car speakers, clean on the
    /// phone); compact (`.default`-quality) voices render from a smaller,
    /// stable model that survives the CarPlay audio pipeline intact. Prefer
    /// `.default` quality explicitly — `AVSpeechSynthesisVoice(language:)`
    /// returns the premium system-default on iOS 16+, which is what v1 of
    /// this fix accidentally kept using.
    private static func carPlayReliableVoice() -> AVSpeechSynthesisVoice? {
        let enUS = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-US" }
        return enUS.first(where: { $0.quality == .default })
            ?? enUS.first(where: { $0.identifier.contains("compact") })
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Release the shared audio session. Called when navigation ends so the
    /// CarPlay audio pipeline is freed and media can resume normally.
    /// NOT called between individual announcements — that caused the
    /// glitchy teardown-and-rebuild cycle. The coordinator only deactivates
    /// the session when no other subsystem (e.g. a speeding alert) still
    /// holds it.
    func deactivateSession() {
        pendingMessages.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        if sessionHeld {
            AudioSessionCoordinator.shared.endNavigation()
            sessionHeld = false
        }
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
        Task { @MainActor [weak self] in
            self?.drainPendingMessage()
        }
    }

    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.drainPendingMessage()
        }
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
    @Published public var destination: MKMapItem? = nil {
        didSet {
            guard !mapItemsMatch(oldValue, destination) else { return }
            // Direct callers (including CarPlay restoration) can set the
            // destination without going through selectDestination... . Keep
            // the multi-stop snapshot and its invalidation token in sync.
            finalDestinationMapItem = destination
            routeLegs.removeAll()
            multiStopLegDestinations.removeAll()
            publishedMultiStopStateGeneration = nil
            activeMultiStopLegIndex = 0
            multiStopStateGeneration &+= 1
        }
    }
    /// The destination as a MapItem mirror of `destination` for reroute paths
    /// and the 35m off-route detector.
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
    /// Invalidates in-flight multi-stop calculations when stops or the
    /// destination changes while MapKit is awaiting a leg response.
    private var multiStopStateGeneration: UInt64 = 0
    /// Read-only edit token for callers that need to roll back only their own
    /// failed stop mutation. A later edit invalidates the token.
    public var routeStopsEditGeneration: UInt64 { multiStopStateGeneration }
    /// Map items for each calculated leg, parallel to `routeLegs`. The
    /// coordinator follows one leg at a time; CarPlay uses this to present the
    /// current stop rather than claiming the final destination is the active
    /// leg's endpoint.
    private var multiStopLegDestinations: [MKMapItem] = []
    /// Generation of the last coherent routeLegs snapshot. Stop edits keep
    /// that old snapshot temporarily for rollback, but it must not be used
    /// for guidance until a replacement calculation publishes successfully.
    private var publishedMultiStopStateGeneration: UInt64?
    private var activeMultiStopLegIndex: Int = 0

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
    /// Most recent navigation fix used to refresh Apple's traffic-aware ETA.
    private var lastNavigationLocation: CLLocation?
    /// Last matched remaining distance. GPS can briefly snap to an earlier
    /// parallel segment; never let that turn make the ETA jump backward.
    private var lastMatchedRemainingDistance: CLLocationDistance = 0
    /// Invalidates a traffic refresh that was suspended across a route change
    /// or navigation teardown.
    private var trafficRefreshGeneration: UInt64 = 0
    /// Prevents a stale GPS fix from lowering the refresh baseline after a
    /// route transition while retaining the active route's canonical geometry.
    private var lastTrafficRefreshDistance: CLLocationDistance = 0
    /// Apple MapKit's latest traffic-aware remaining journey snapshot.
    /// We scale this snapshot by the live remaining route distance between
    /// refreshes, rather than replacing it with a noisy GPS-speed estimate.
    private var trafficReferenceDistance: CLLocationDistance = 0
    private var trafficReferenceTime: TimeInterval = 0
    /// Periodic traffic refresh timer; MapKit directions are one-shot and do
    /// not push traffic changes automatically. 90 seconds keeps ETA current
    /// without hammering Apple's directions service.
    private var rerouteTimer: Timer?
    private var trafficRefreshInFlight = false
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
    /// Prevents repeated arrival tasks while the final GPS fix is delivered
    /// across multiple location ticks.
    private var isCompletingNavigation = false
    /// Cancels delayed arrival teardown if the user starts a new route first.
    private var arrivalTeardownTask: Task<Void, Never>?
    private var navigationLifecycleGeneration: UInt64 = 0
    /// Invalidates overlapping direct/search route requests before an older
    /// MapKit response can publish routes for the wrong destination.
    private var routeRequestGeneration: UInt64 = 0
    private var navigationTeardownInProgress = false

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
    /// Updates the host ViewModel's navigation flag when navigation ends
    /// from an arrival/CarPlay callback rather than the phone wrapper.
    private let setNavigating: (Bool) -> Void
    /// Ends the host recording session after navigation reaches its endpoint.
    /// The host callback runs after `setNavigating(false)` so it cannot recurse
    /// back into navigation teardown.
    private let endSession: () -> Void
    /// Begins a Live Activity for the active nav session. The host VM is
    /// responsible for gating `#if !targetEnvironment(simulator)` since
    /// the activity call itself shouldn't be parameterized on host env.
    private let liveActivityStart: (Date) -> Void
    /// Ends the active Live Activity. Same simulator-gate caveat.
    private let liveActivityEnd: () -> Void

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
            setNavigating: { _ in },
            endSession: { },
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
        setNavigating: @escaping (Bool) -> Void = { _ in },
        endSession: @escaping () -> Void = { },
        liveActivityStart: @escaping (Date) -> Void = { _ in },
        liveActivityEnd: @escaping () -> Void = { },
        voiceAnnouncer: VoiceAnnouncer? = nil
    ) {
        self.isRecordingProvider = isRecordingProvider
        self.nearbyCamerasProvider = nearbyCamerasProvider
        self.availableRoutesProvider = availableRoutesProvider
        self.availableRoutesSetter = availableRoutesSetter
        self.onRerouteRequest = onRerouteRequest
        self.startSession = startSession
        self.setNavigating = setNavigating
        self.endSession = endSession
        self.liveActivityStart = liveActivityStart
        self.liveActivityEnd = liveActivityEnd
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
        // Keep the last complete route snapshot until the replacement
        // calculation succeeds. This prevents routeStops changing while the
        // active route/legs are cleared and then calculation fails.
        orderingComparison = nil
        multiStopStateGeneration &+= 1
    }

    /// Removes a stop by its ID.
    public func removeStop(id: UUID) {
        let before = routeStops.count
        routeStops.removeAll { $0.id == id }
        guard routeStops.count != before else { return }
        orderingComparison = nil
        multiStopStateGeneration &+= 1
    }

    /// Moves a stop from one position to another (drag-to-reorder).
    public func moveStop(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex >= 0, sourceIndex < routeStops.count,
              destinationIndex >= 0, destinationIndex < routeStops.count else { return }
        let stop = routeStops.remove(at: sourceIndex)
        routeStops.insert(stop, at: destinationIndex)
        // Preserve the currently-followed route while the reordered snapshot
        // is recalculated; a failed request must not strand navigation.
        orderingComparison = nil
        multiStopStateGeneration &+= 1
    }

    /// Restores the last coherent stop list after a replacement route fails.
    /// The caller uses this only for the same user edit that initiated the
    /// failed calculation, so the active route and its legs remain aligned.
    @discardableResult
    public func restoreRouteStops(
        _ stops: [RouteStop],
        ifCurrentIDsMatch expectedIDs: [UUID],
        expectedGeneration: UInt64? = nil
    ) -> Bool {
        guard routeStops.map(\.id) == expectedIDs,
              expectedGeneration.map({ routeStopsEditGeneration == $0 }) ?? true else { return false }
        routeStops = stops
        multiStopStateGeneration &+= 1
        // The preserved routeLegs/multiStopLegDestinations still belong to
        // this restored stop order. Mark that coherent snapshot current again;
        // otherwise the published-generation guard would permanently disable
        // intermediate-leg advancement after a failed edit rollback.
        publishedMultiStopStateGeneration = multiStopStateGeneration
        return true
    }

    /// Calculates the full multi-stop route from the current location through
    /// all intermediate stops to the final destination. Each leg is calculated
    /// separately so we capture per-leg ETA/distance data.
    ///
    /// Returns the route for the first active leg. The remaining legs stay in
    /// `routeLegs` and are activated automatically as each stop is reached.
    public func calculateMultiStopRoute() async -> MKRoute? {
        guard let finalDest = finalDestinationMapItem ?? destination else { return nil }
        isCalculatingMultiStop = true
        defer { isCalculatingMultiStop = false }

        let calculationGeneration = multiStopStateGeneration
        let source = MKMapItem.forCurrentLocation()
        let stopsSnapshot = routeStops
        let stopIDsSnapshot = stopsSnapshot.map(\.id)
        let allLegs = buildLegs(from: source, through: stopsSnapshot, to: finalDest)
        var computedLegs: [RouteLeg] = []
        var computedStopEstimates: [(index: Int, travelTime: TimeInterval, distance: CLLocationDistance, cumulativeTime: TimeInterval)] = []
        var cumulativeTime: TimeInterval = 0

        // Calculate each leg sequentially so we can accumulate times.
        // Using a task group would be faster but MKDirections has a concurrency
        // limit; serial is more reliable. Treat the result transactionally:
        // publishing a partial set of legs leaves the phone and CarPlay with
        // incompatible route state and was a direct path to missing directions
        // after a stop was added.
        for (idx, leg) in allLegs.enumerated() {
            guard let legRoute = await calculateRouteBetween(
                source: leg.source,
                destination: leg.destination
            ) else {
                return nil
            }

            let routeLeg = RouteLeg(
                sourceName: leg.sourceName,
                destinationName: leg.destinationName,
                travelTime: legRoute.expectedTravelTime,
                distance: legRoute.distance,
                route: legRoute
            )
            computedLegs.append(routeLeg)
            cumulativeTime += legRoute.expectedTravelTime

            // Hold stop estimates locally until every leg succeeds.
            if idx < stopsSnapshot.count {
                computedStopEstimates.append((
                    index: idx,
                    travelTime: legRoute.expectedTravelTime,
                    distance: legRoute.distance,
                    cumulativeTime: cumulativeTime
                ))
            }
        }

        // Actor reentrancy lets a stop edit or destination replacement happen
        // while MapKit is awaiting a leg. Never publish a mixed snapshot.
        guard calculationGeneration == multiStopStateGeneration,
              routeStops.map(\.id) == stopIDsSnapshot,
              mapItemsMatch(finalDest, finalDestinationMapItem ?? destination),
              computedLegs.count == allLegs.count,
              let overallRoute = computedLegs.first?.route else {
            return nil
        }

        self.multiStopLegDestinations = allLegs.map { $0.destination }
        self.publishedMultiStopStateGeneration = calculationGeneration
        self.activeMultiStopLegIndex = 0
        for estimate in computedStopEstimates {
            routeStops[estimate.index].travelTimeFromPrevious = estimate.travelTime
            routeStops[estimate.index].distanceFromPrevious = estimate.distance
            routeStops[estimate.index].cumulativeTravelTime = estimate.cumulativeTime
        }
        self.routeLegs = computedLegs

        // Update ETA to reflect the total multi-stop journey.
        let totalTime = computedLegs.reduce(0) { $0 + $1.travelTime }
        let totalDistance = computedLegs.reduce(0) { $0 + $1.distance }
        self.setTrafficReference(distance: totalDistance, time: totalTime)
        self.eta = Date().addingTimeInterval(totalTime)
        self.distanceToDestination = totalDistance

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
        let stopsSnapshot = routeStops
        let currentIDs = stopsSnapshot.map(\.id)
        let comparisonGeneration = multiStopStateGeneration

        // 1. Calculate the current order's total using REAL directions (one
        //    call per leg, needed for accurate current-ETA display).
        let currentTime = await totalTravelTimeForOrder(
            source: source,
            stops: stopsSnapshot,
            destination: finalDest
        )
        guard currentTime > 0 else { return nil }

        // 2. Find the best ordering using Haversine distance (fast, no
        //    network calls) to estimate which permutation is most efficient.
        var bestTime = currentTime
        var bestOrderIDs = currentIDs

        if stopsSnapshot.count <= 4 {
            // Exhaustive search using straight-line distance approximation.
            // This is extremely fast because it doesn't hit the network.
            let bestHaversineOrder = await findBestOrderHaversine(
                source: source,
                stops: stopsSnapshot,
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
                stops: stopsSnapshot,
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

        guard comparisonGeneration == multiStopStateGeneration,
              routeStops.map(\.id) == currentIDs,
              mapItemsMatch(finalDest, finalDestinationMapItem ?? destination) else {
            return nil
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
            // The old route remains coherent until the caller successfully
            // recalculates it for the new ordering.
            multiStopStateGeneration &+= 1
            orderingComparison = nil
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
        multiStopLegDestinations.removeAll()
        publishedMultiStopStateGeneration = nil
        activeMultiStopLegIndex = 0
        multiStopStateGeneration &+= 1
    }

    // MARK: - Multi-Stop Helpers

    /// Builds the list of (source, destination) pairs for each leg of the journey.
    /// The endpoint of the leg currently being shown to CarPlay.
    /// `nil` means this is a normal single-destination route.
    public var activeMultiStopDestination: MKMapItem? {
        guard !routeStops.isEmpty,
              multiStopLegDestinations.indices.contains(activeMultiStopLegIndex) else { return nil }
        return multiStopLegDestinations[activeMultiStopLegIndex]
    }

    /// Index of the leg currently being guided. The map uses this to keep the
    /// active leg bold after a stop transition instead of continuing to draw
    /// the original first leg as the primary route.
    public var activeMultiStopLegIndexForDisplay: Int {
        activeMultiStopLegIndex
    }

    /// Advances guidance from an intermediate stop to the next precomputed
    /// leg. Returns nil when the final leg is already active.
    @discardableResult
    public func advanceToNextMultiStopLeg() -> (route: MKRoute, destination: MKMapItem)? {
        // Stop edits preserve the previous complete route until recalculation
        // succeeds. Do not advance that stale snapshot after the last stop was
        // removed while its replacement route is still pending.
        guard !routeStops.isEmpty,
              publishedMultiStopStateGeneration == multiStopStateGeneration,
              activeMultiStopLegIndex + 1 < routeLegs.count,
              let nextRoute = routeLegs[activeMultiStopLegIndex + 1].route,
              multiStopLegDestinations.indices.contains(activeMultiStopLegIndex + 1) else {
            return nil
        }

        let nextDestination = multiStopLegDestinations[activeMultiStopLegIndex + 1]
        // Stop CarPlay's old monitor/session before publishing the new route.
        // Otherwise one location tick can evaluate the new coordinator route
        // against the old CarPlay step array and finish the wrong trip.
        navigationDelegate?.prepareForRouteTransition()
        activeMultiStopLegIndex += 1
        currentRoute = nextRoute
        // Invalidate a traffic request that may still be calculating the
        // completed leg. Its result must never overwrite this new leg's ETA.
        trafficRefreshGeneration &+= 1
        lastMatchedRemainingDistance = nextRoute.distance
        lastTrafficRefreshDistance = nextRoute.distance
        currentStepIndex = 0
        // The published route snapshot remains valid while moving between its
        // legs. Do not advance the edit/calculation generation here: doing so
        // would make the next leg look stale even though no stop changed.
        let transitionGeneration = multiStopStateGeneration
        // CarPlay owns its own CPNavigationSession and step array. Ask it to
        // replace that session immediately; otherwise its monitor would keep
        // evaluating the completed leg while the coordinator follows the next.
        // Capture immutable route data and reject the task if a later edit,
        // clear, or transition supersedes this leg before it runs.
        Task { @MainActor [weak self] in
            guard let self,
                  self.multiStopStateGeneration == transitionGeneration,
                  self.activeMultiStopLegIndex < self.multiStopLegDestinations.count,
                  self.multiStopLegDestinations[self.activeMultiStopLegIndex].placemark.coordinate.latitude == nextDestination.placemark.coordinate.latitude,
                  self.multiStopLegDestinations[self.activeMultiStopLegIndex].placemark.coordinate.longitude == nextDestination.placemark.coordinate.longitude else { return }
            await self.navigationDelegate?.startNavigationTrigger(
                to: nextDestination,
                route: nextRoute
            )
        }
        stepStageFlags.removeAll()
        lastDistanceToTurn = nil
        let remainingLegs = routeLegs[activeMultiStopLegIndex...]
        let remainingTime = remainingLegs.reduce(0) { $0 + $1.travelTime }
        let remainingDistance = remainingLegs.reduce(0) { $0 + $1.distance }
        setTrafficReference(distance: remainingDistance, time: remainingTime)
        eta = Date().addingTimeInterval(remainingTime)
        distanceToDestination = remainingDistance
        return (nextRoute, nextDestination)
    }

    private func mapItemsMatch(_ lhs: MKMapItem?, _ rhs: MKMapItem?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            let a = lhs.placemark.coordinate
            let b = rhs.placemark.coordinate
            return CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) < 1
        default:
            return false
        }
    }

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
        routeRequestGeneration &+= 1
        let requestGeneration = routeRequestGeneration
        // A fresh user-selected destination supersedes any prior off-route
        // reroute indicator immediately; otherwise a failed/stale reroute can
        // leave the HUD spinning while this normal search is in flight.
        if !isRerouting {
            self.isRerouting = false
        }
        self.destination = destination
        self.finalDestinationMapItem = destination
        multiStopStateGeneration &+= 1

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
            guard requestGeneration == routeRequestGeneration,
                  mapItemsMatch(destination, self.destination) else { return }
            self.availableRoutesSetter(response.routes)
            DebugLogger.shared.log("Found \(response.routes.count) available routes\(isRerouting ? " (Fast Reroute)" : "")")
        } catch {
            DebugLogger.shared.log("Route calculation FAILED: \(error.localizedDescription)")
            print("Route error: \(error)")
        }

        if requestGeneration == routeRequestGeneration {
            self.isRerouting = false
        }
    }

    // MARK: - Navigation Control

    /// Commences turn-by-turn guidance on a specific path. Sets `isNavigating`
    /// is the wrapper's responsibility (host-VM state); this method focuses
    /// on the navigation-tick-readable state.
    @discardableResult
    public func startNavigation(with route: MKRoute, isReroute: Bool = false) async -> Bool {
        DebugLogger.shared.log("Navigation \(isReroute ? "REROUTED" : "STARTED") using Route (\(Int(route.distance))m)")
        // Invalidate any queued intermediate-leg CarPlay handoff before
        // replacing the active route (normal starts and reroutes included).
        // Replacing a normal route invalidates pending multi-stop work. A
        // multi-stop start usually follows a successful calculation whose
        // snapshot must remain valid for intermediate-leg progression.
        if routeStops.isEmpty {
            multiStopStateGeneration &+= 1
        } else {
            // A stop edit leaves the previous route visible while a new
            // calculation is in flight. Never start that stale route.
            guard publishedMultiStopStateGeneration == multiStopStateGeneration else { return false }
        }
        let startWasMultiStop = !routeStops.isEmpty
        let startMultiStopGeneration = multiStopStateGeneration
        let startRouteRequestGeneration = routeRequestGeneration
        // Reserve this start before the first await. A newer start invalidates
        // this token, so an older cache-warmup completion cannot publish a
        // stale route afterward.
        navigationLifecycleGeneration &+= 1
        let startNavigationGeneration = navigationLifecycleGeneration
        arrivalTeardownTask?.cancel()
        arrivalTeardownTask = nil

        // Reset flags so we can re-announce the approach to the first turn
        self.stepStageFlags.removeAll()
        self.lastDistanceToTurn = nil
        self.spokenCameraKeys.removeAll()

        // Cache speed limits for the route points to ensure we stay offline-capable during the drive.
        await cacheRouteSegments(route)

        // Stop edits or a newer navigation start can occur while the cache
        // warmup is suspended. Do not publish this route after either event.
        guard navigationLifecycleGeneration == startNavigationGeneration,
              startRouteRequestGeneration == routeRequestGeneration,
              startMultiStopGeneration == multiStopStateGeneration,
              !startWasMultiStop || (
                  !routeStops.isEmpty &&
                  publishedMultiStopStateGeneration == multiStopStateGeneration
              ) else { return false }

        // Compute ETA from total journey (multi-stop-aware) only after the
        // async validation above. A stale start must not overwrite the active
        // route's ETA/distance while a newer start is in flight.
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
        let initialTrafficDistance = routeStops.isEmpty ? route.distance : max(distanceToDestination, route.distance)
        let initialTrafficTime = routeStops.isEmpty
            ? route.expectedTravelTime
            : max(eta?.timeIntervalSinceNow ?? 0, route.expectedTravelTime)
        self.setTrafficReference(distance: initialTrafficDistance, time: initialTrafficTime)

        // Automatically start recording the drive session if it hasn't been started manually.
        // This is committed only after the route generation survives cache warming.

        // Commit navigation-owned state only after all async validation has
        // passed. This prevents stale starts from leaving a route, timer, or
        // recording session partially active.
        self.currentRoute = route
        self.trafficRefreshGeneration &+= 1
        self.lastMatchedRemainingDistance = route.distance
        self.lastTrafficRefreshDistance = route.distance
        self.currentStepIndex = 0
        self.isCompletingNavigation = false
        self.navigationTeardownInProgress = false
        startRerouteTimer()
        if !self.isRecordingProvider() {
            self.startSession()
            DebugLogger.shared.log("Session AUTO-STARTED with navigation")
        }

        // Inform the CarPlay/UI layer that navigation is moving
        if let dest = self.destination {
            await navigationDelegate?.startNavigationTrigger(to: dest, route: route)
        }

        // A newer navigation start or stop edit may have taken ownership while
        // CarPlay replaced its session. Do not let this stale continuation
        // overwrite maneuver state, speak an old route, or start a duplicate
        // Live Activity.
        guard navigationLifecycleGeneration == startNavigationGeneration,
              startRouteRequestGeneration == routeRequestGeneration,
              startMultiStopGeneration == multiStopStateGeneration,
              !startWasMultiStop || (!routeStops.isEmpty && publishedMultiStopStateGeneration == multiStopStateGeneration) else {
            // The old CarPlay handoff may already have installed this route,
            // but a newer lifecycle now owns future updates. Keep the host in
            // a valid navigating state while that replacement is committing;
            // only report failure when there is no active route left to own.
            return currentRoute != nil && !isCompletingNavigation
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
        return true
    }

    /// Alternative start navigation that triggers the calculation internally
    /// (legacy/direct support). The wrapper on the host VM is responsible
    /// for setting `isNavigating = true` and for starting a recording if
    /// none is in progress.
    @discardableResult
    public func startNavigation(to destination: MKMapItem) async -> Bool {
        // A direct route cannot replace an active multi-stop plan: its
        // destination and route legs have different semantics. Traffic
        // rerouting skips this path for multi-stop sessions as well.
        guard routeStops.isEmpty else { return false }

        // Keep the legacy/direct start path consistent with startNavigation(with:).
        // Calculate before replacing the current destination. That keeps an
        // already-active route coherent while MapKit is still awaiting the
        // replacement route. The request token also invalidates a concurrent
        // destination-search response.
        routeRequestGeneration &+= 1
        let directRouteRequestGeneration = routeRequestGeneration
        navigationLifecycleGeneration &+= 1
        let directStartGeneration = navigationLifecycleGeneration
        arrivalTeardownTask?.cancel()
        arrivalTeardownTask = nil
        isCompletingNavigation = false
        navigationTeardownInProgress = false

        guard let route = await calculateRouteBetween(
            source: MKMapItem.forCurrentLocation(),
            destination: destination
        ) else {
            // Do not tear down a newer route when this request was superseded.
            guard navigationLifecycleGeneration == directStartGeneration else { return false }
            if currentRoute == nil {
                self.setNavigating(false)
            }
            return false
        }

        // The calculation is cancellable by a newer direct start or teardown.
        guard navigationLifecycleGeneration == directStartGeneration,
              routeRequestGeneration == directRouteRequestGeneration else { return false }

        self.destination = destination
        self.destinationItem = destination
        return await startNavigation(with: route)
    }

    /// Terminates the current navigation session. Cleans all nav-owned
    /// state, notifies the navigationDelegate, and ends the Live Activity.
    /// The host VM wrapper is responsible for setting `isNavigating = false`
    /// BEFORE invoking this, for the `endSession()` recording call AFTER,
    /// and for honoring the simulator speaker gate.
    public func endNavigation() async {
        // Completion can be requested by the phone heartbeat and CarPlay in
        // the same GPS tick. The first caller owns teardown; later callers
        // must not end the recording session or notify the delegate twice.
        guard !navigationTeardownInProgress else { return }
        navigationTeardownInProgress = true
        // Invalidate any route search/direct MapKit request that is still
        // suspended. Its response must not repopulate availableRoutes after
        // this navigation session has been torn down.
        routeRequestGeneration &+= 1
        arrivalTeardownTask?.cancel()
        arrivalTeardownTask = nil
        navigationLifecycleGeneration &+= 1
        let teardownGeneration = navigationLifecycleGeneration
        self.currentRoute = nil
        self.lastNavigationLocation = nil
        self.lastMatchedRemainingDistance = 0
        self.lastTrafficRefreshDistance = 0
        self.trafficRefreshGeneration &+= 1
        self.trafficReferenceDistance = 0
        self.trafficReferenceTime = 0
        self.trafficRefreshInFlight = false
        self.isCompletingNavigation = true
        self.destination = nil
        self.destinationItem = nil
        self.nextManeuverInstruction = ""
        self.nextManeuverImageName = "arrow.up"
        self.distanceToNextTurn = 0
        self.distanceToDestination = 0
        self.eta = nil
        // Arrival can invoke this method directly from the location heartbeat,
        // bypassing DriveViewModel.endNavigation(). Keep the host UI and
        // recording lifecycle in sync before notifying CarPlay.
        self.setNavigating(false)
        if self.isRecordingProvider() {
            self.endSession()
        }
        rerouteTimer?.invalidate()
        rerouteTimer = nil
        self.stepStageFlags.removeAll()
        self.spokenCameraKeys.removeAll()
        // Drop maneuver scratch state so the next navigation starts clean.
        // (Look Around scratch state removed in TestFlight 2.2.0 / FB10.)
        self.nextManeuverCoordinate = nil
        // Deactivate the navigation voice audio session so media can
        // resume on the CarPlay audio channel. This is the ONLY place
        // the session is torn down — NOT between individual announcements
        // (which was causing the severe stutter/glitch).
        voiceAnnouncer.deactivateSession()

        await navigationDelegate?.endNavigationTrigger()

        // The delegate call can suspend and allow a new route to start. Do
        // not finish the old route's Live Activity after that new lifecycle
        // has taken ownership of the coordinator.
        guard navigationLifecycleGeneration == teardownGeneration,
              navigationTeardownInProgress else { return }
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
        guard !isCompletingNavigation, let route = currentRoute else { return }
        lastNavigationLocation = location
        let steps = route.steps

        // Arrival must not depend on the driver still moving. A final GPS fix
        // is commonly delivered after braking or at a red light, so checking
        // only inside the "advance while moving" branch leaves the last
        // instruction visible indefinitely. For multi-stop routes, advance
        // the active leg first; only the final leg ends the trip.
        let arrivalLocation: CLLocation?
        if let activeDestination = activeMultiStopDestination {
            arrivalLocation = activeDestination.placemark.location
        } else if routeStops.isEmpty {
            arrivalLocation = destination?.placemark.location
        } else {
            arrivalLocation = nil
        }
        if let arrivalLocation, location.distance(from: arrivalLocation) <= 50 {
            if activeMultiStopDestination != nil,
               activeMultiStopLegIndex + 1 < routeLegs.count {
                _ = advanceToNextMultiStopLeg()
                return
            }

            HapticAlertManager.playNavigationPop()
            let arrivalWasBlockedBySpeech = voiceAnnouncer.isSpeaking
            if !arrivalWasBlockedBySpeech {
                announce("You have arrived at your destination.")
            }
            scheduleArrivalTeardown(announceArrivalWhenAvailable: arrivalWasBlockedBySpeech)
            return
        }

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

            var advancedToNextLeg = false
            if distanceToTurn < advanceThreshold && isMoving {
                advancedToNextLeg = advanceToNextStep(steps, at: location)
            } else if let prevDist = lastDistanceToTurn, distanceToTurn > prevDist + 20 && distanceToTurn < 80 && isMoving {
                // Distance increasing significantly after being very close: we passed the turn
                advancedToNextLeg = advanceToNextStep(steps, at: location)
            }

            // The transition publishes a new route and total remaining ETA.
            // Do not continue this tick with the completed leg's local route.
            if advancedToNextLeg { return }

            lastDistanceToTurn = distanceToTurn
        }

        // 4. ETA REFRESH: Use the latest Apple traffic-aware snapshot,
        //    scaled to the monotonically matched distance on the active
        //    route geometry. Never substitute instantaneous GPS speed.
        let measuredRemainingDistance = actualRemainingDistance(route: route, location: location)
        let activeRemainingDist: CLLocationDistance
        if lastMatchedRemainingDistance > 0 {
            activeRemainingDist = min(measuredRemainingDistance, lastMatchedRemainingDistance)
        } else {
            activeRemainingDist = measuredRemainingDistance
        }
        lastMatchedRemainingDistance = activeRemainingDist
        var remainingDist = activeRemainingDist
        var expectedRemainingTime = route.expectedTravelTime *
            (activeRemainingDist / max(route.distance, 1))

        // `currentRoute` is only the active leg. Include every later leg in
        // the published ETA/distance so a multi-stop route does not appear
        // to finish when the driver reaches the next stop.
        if !routeStops.isEmpty,
           activeMultiStopLegIndex + 1 < routeLegs.count {
            let laterLegs = routeLegs[(activeMultiStopLegIndex + 1)...]
            remainingDist += laterLegs.reduce(0) { $0 + $1.distance }
            expectedRemainingTime += laterLegs.reduce(0) { $0 + $1.travelTime }
        }

        let proportionalEstimate = max(0, expectedRemainingTime)
        let timeRemaining = max(0, trafficAwareRemainingTime(
            forRemainingDistance: remainingDist,
            fallback: proportionalEstimate
        ))

        self.eta = Date().addingTimeInterval(max(5, timeRemaining))
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
            // Only give advance warning if we aren't already right on top of the turn.
            // Do not mark the stage until it was actually accepted by the
            // announcer; this lets the next GPS tick retry after a prior cue
            // finishes instead of silently losing the instruction.
            if distanceToTurn > immediateThreshold + 50 {
                guard !voiceAnnouncer.isSpeaking else {
                    stepStageFlags[stepIndex] = flags
                    return
                }
                let formattedDist = formatDistance(distanceToTurn)
                if distanceToTurn > 3218 { // > 2 miles, give a "continue"
                    let routeName = currentRoute?.name ?? "the road"
                    announce("Continue on \(routeName) for \(formattedDist).")
                } else {
                    announce("In \(formattedDist), \(activeInstruction)")
                }
            }
            flags.insert("initial")
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
            guard !voiceAnnouncer.isSpeaking else {
                stepStageFlags[stepIndex] = flags
                return
            }
            let approachingDist = formatDistance(distanceToTurn)
            let lower = activeInstruction.lowercased()
            if lower.contains("merge onto") || lower.contains("take exit") {
                announce("Merging in \(approachingDist).")
            } else {
                announce("In \(approachingDist), \(activeInstruction)")
            }
            flags.insert("approaching")
        }

        // 2. Immediate Turning Warning (Right before the turn)
        if distanceToTurn <= immediateThreshold && !flags.contains("immediate") {
            guard !voiceAnnouncer.isSpeaking else {
                stepStageFlags[stepIndex] = flags
                return
            }
            announce(activeInstruction)
            flags.insert("immediate")
        }

        stepStageFlags[stepIndex] = flags
    }

    /// Gives the arrival utterance time to reach the CarPlay audio route
    /// before endNavigation tears down the shared AVAudioSession. The old
    /// immediate teardown stopped AVSpeechSynthesizer at .immediate and could
    /// truncate the only confirmation the driver heard.
    private func scheduleArrivalTeardown(announceArrivalWhenAvailable: Bool = false) {
        guard !isCompletingNavigation else { return }
        isCompletingNavigation = true
        // Hide phone and CarPlay directions immediately at arrival. The actual
        // teardown remains delayed so an in-progress navigation announcement
        // can finish without being cut off, but the user must not see another
        // maneuver after reaching the destination.
        setNavigating(false)
        navigationLifecycleGeneration &+= 1
        let generation = navigationLifecycleGeneration
        arrivalTeardownTask?.cancel()
        arrivalTeardownTask = Task { @MainActor [weak self] in
            // Give the current utterance a small head start, then wait for it
            // to finish. If arrival happened while another cue was speaking,
            // speak the arrival cue after that cue instead of silently losing
            // the only completion message the driver should hear.
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }

            let deadline = Date().addingTimeInterval(5)
            while !Task.isCancelled,
                  let self,
                  self.voiceAnnouncer.isSpeaking,
                  Date() < deadline {
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    return
                }
            }

            guard !Task.isCancelled,
                  let self,
                  self.navigationLifecycleGeneration == generation,
                  self.isCompletingNavigation else { return }

            if announceArrivalWhenAvailable {
                self.announce("You have arrived at your destination.")
                let speechDeadline = Date().addingTimeInterval(5)
                while !Task.isCancelled,
                      self.voiceAnnouncer.isSpeaking,
                      Date() < speechDeadline {
                    do {
                        try await Task.sleep(nanoseconds: 100_000_000)
                    } catch {
                        return
                    }
                }
            }

            guard !Task.isCancelled,
                  self.navigationLifecycleGeneration == generation,
                  self.isCompletingNavigation else { return }
            await self.endNavigation()
        }
    }

    /// Updates the index and UI state for the next turn.
    /// `at location` is optional and only used by the final-step arrival
    /// detector so the arrival distance check has a `CLLocation` to use;
    /// callers passing nil (e.g. tests) will skip the arrival cue.
    private func advanceToNextStep(_ steps: [MKRoute.Step], at location: CLLocation? = nil) -> Bool {
        if self.currentStepIndex < steps.count - 1 {
            self.currentStepIndex += 1
            self.lastDistanceToTurn = nil
            return false
        } else {
            // An intermediate stop is an arrival boundary too. Switch to the
            // next precomputed leg before comparing against the final trip
            // destination, which remains stored in `destination`.
            if let nextLeg = advanceToNextMultiStopLeg() {
                announce("Arriving at \(nextLeg.destination.name ?? "stop"), continuing the route.")
                return true
            }

            // We are on the final step — announce arrival when within 50m
            let dist = location.flatMap { loc in
                destination?.placemark.location.map { loc.distance(from: $0) }
            } ?? .greatestFiniteMagnitude
            if dist <= 50 {
                // Haptic: arrival celebration
                HapticAlertManager.playNavigationPop()
                let arrivalWasBlockedBySpeech = voiceAnnouncer.isSpeaking
                if !arrivalWasBlockedBySpeech {
                    announce("You have arrived at your destination.")
                }
                scheduleArrivalTeardown(announceArrivalWhenAvailable: arrivalWasBlockedBySpeech)
            }
        }
        return false
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
        let isMetric = SpeedFormatting.isMetric(SpeedFormatting.measurementSystem())
        if isMetric {
            if meters >= SpeedFormatting.metersPerKilometer {
                let km = meters / SpeedFormatting.metersPerKilometer
                return formatDecimalForSpeech(km) + " kilometers"
            } else {
                // Round to nearest 50m for more natural speech
                return "\(Int(meters / 50) * 50) meters"
            }
        } else {
            let miles = meters / SpeedFormatting.metersPerMile
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
                let feet = meters * SpeedFormatting.feetPerMeter
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
    /// The default announcer owns the shared AVAudioSession so navigation
    /// never competes with a second synthesizer.
    private func announce(_ message: String) {
        voiceAnnouncer.announce(message)
    }

    /// Internal bridge for legacy DriveViewModel call sites. Keeping one
    /// announcer prevents the old synthesizer from deactivating the shared
    /// audio session while coordinator speech is still in progress.
    internal func announceNavigation(_ message: String) {
        announce(message)
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
        // MKDirections returns a one-shot traffic snapshot. Refresh it every
        // 90 seconds while navigating so congestion changes reach both the
        // phone ETA and CarPlay without replacing the active route geometry.
        rerouteTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshTrafficEstimate()
            }
        }
    }

    /// Refreshes the current journey's ETA from Apple's live traffic-aware
    /// directions service without replacing the driver's active geometry.
    private func refreshTrafficEstimate() async {
        guard !trafficRefreshInFlight,
              let location = lastNavigationLocation,
              let target = activeMultiStopDestination ?? destination else { return }

        trafficRefreshInFlight = true
        let refreshGeneration = trafficRefreshGeneration
        let refreshPlanGeneration = multiStopStateGeneration
        let refreshLegIndex = activeMultiStopLegIndex
        let refreshDestination = target
        defer { trafficRefreshInFlight = false }

        let source = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
        var refreshedDistance: CLLocationDistance = 0
        var refreshedTime: TimeInterval = 0

        if routeStops.isEmpty {
            guard let refreshedRoute = await calculateRouteBetween(source: source, destination: target),
                  refreshGeneration == trafficRefreshGeneration,
                  refreshPlanGeneration == multiStopStateGeneration,
                  currentRoute != nil else { return }
            refreshedDistance = refreshedRoute.distance
            refreshedTime = refreshedRoute.expectedTravelTime
        } else {
            // Refresh every remaining leg, not only the active leg. Traffic
            // on a later stop-to-stop segment is just as capable of making
            // the final ETA wrong as traffic immediately ahead.
            guard activeMultiStopLegIndex < multiStopLegDestinations.count else { return }
            for legIndex in activeMultiStopLegIndex..<multiStopLegDestinations.count {
                let legSource = legIndex == activeMultiStopLegIndex
                    ? source
                    : multiStopLegDestinations[legIndex - 1]
                let legDestination = multiStopLegDestinations[legIndex]
                guard let refreshedLeg = await calculateRouteBetween(
                    source: legSource,
                    destination: legDestination
                ),
                refreshGeneration == trafficRefreshGeneration,
                refreshPlanGeneration == multiStopStateGeneration,
                currentRoute != nil else { return }
                refreshedDistance += refreshedLeg.distance
                refreshedTime += refreshedLeg.expectedTravelTime
            }
        }

        guard refreshedDistance > 0, refreshedTime > 0,
              refreshGeneration == trafficRefreshGeneration,
              refreshPlanGeneration == multiStopStateGeneration,
              refreshLegIndex == activeMultiStopLegIndex,
              mapItemsMatch(refreshDestination, activeMultiStopDestination ?? destination) else { return }

        // Keep the active route geometry as the canonical distance source.
        // The refreshed MKRoute is a traffic snapshot, not the route being
        // rendered or matched by the guidance loop. Publishing its distance
        // here caused the next GPS tick to jump back to the old polyline and
        // make phone and CarPlay disagree. Use the live distance on the
        // current geometry as the reference denominator, and use Apple's
        // refreshed travel time as the traffic numerator.
        let measuredLiveDistance = liveRemainingDistance(at: location)
        let liveReferenceDistance = lastTrafficRefreshDistance > 0
            ? min(measuredLiveDistance, lastTrafficRefreshDistance)
            : measuredLiveDistance
        guard liveReferenceDistance > 0 else { return }
        lastTrafficRefreshDistance = liveReferenceDistance
        setTrafficReference(distance: liveReferenceDistance, time: refreshedTime)
        eta = Date().addingTimeInterval(refreshedTime)
        DebugLogger.shared.log("Traffic ETA refreshed: \(Int(refreshedTime))s / \(Int(liveReferenceDistance))m")
    }

    private func setTrafficReference(distance: CLLocationDistance, time: TimeInterval) {
        guard distance > 0, time > 0 else { return }
        trafficReferenceDistance = distance
        trafficReferenceTime = time
        lastTrafficRefreshDistance = distance
    }

    /// Computes the remaining distance on the route geometry currently being
    /// followed, including all later precomputed multi-stop legs. This is used
    /// only as the canonical progress denominator; traffic refresh responses
    /// must not replace the active geometry.
    private func liveRemainingDistance(at location: CLLocation) -> CLLocationDistance {
        guard let route = currentRoute else { return 0 }
        let measured = actualRemainingDistance(route: route, location: location)
        let remainingOnActiveLeg = lastMatchedRemainingDistance > 0
            ? min(measured, lastMatchedRemainingDistance)
            : measured
        var remaining = remainingOnActiveLeg
        if !routeStops.isEmpty,
           activeMultiStopLegIndex + 1 < routeLegs.count {
            let laterLegs = routeLegs[(activeMultiStopLegIndex + 1)...]
            remaining += laterLegs.reduce(0) { $0 + $1.distance }
        }
        return max(0, remaining)
    }

    /// Fallback travel time from the active geometry and all later legs.
    /// Used by CarPlay before the first traffic refresh completes.
    public var proportionalRemainingTravelTime: TimeInterval {
        guard let route = currentRoute else { return 0 }
        var total = route.expectedTravelTime
        if !routeStops.isEmpty,
           activeMultiStopLegIndex + 1 < routeLegs.count {
            total += routeLegs[(activeMultiStopLegIndex + 1)...]
                .reduce(0) { $0 + $1.travelTime }
        }
        return max(0, total)
    }

    /// Scales the most recent Apple traffic-aware journey snapshot to the
    /// distance remaining on the live route. The fallback is used before a
    /// traffic reference exists.
    public func trafficAwareRemainingTime(
        forRemainingDistance distance: CLLocationDistance,
        fallback: TimeInterval
    ) -> TimeInterval {
        guard trafficReferenceDistance > 0, trafficReferenceTime > 0 else {
            return fallback
        }
        let ratio = min(max(distance / trafficReferenceDistance, 0), 1)
        return trafficReferenceTime * ratio
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

        // Warm the active live-provider response cache ahead of the route.
        // Live providers are the same HERE/ArcGIS/Overpass chain used on GPS ticks.
        // Fires
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
@MainActor
public protocol NavigationActionDelegate: AnyObject {
    /// Stops progress callbacks before the coordinator publishes a replacement
    /// route, preventing a mixed old-session/new-route tick.
    func prepareForRouteTransition()
    func startNavigationTrigger(to destination: MKMapItem, route: MKRoute?) async
    func endNavigationTrigger() async
    func searchDestinationTrigger(_ query: String) async -> [MKMapItem]
}
