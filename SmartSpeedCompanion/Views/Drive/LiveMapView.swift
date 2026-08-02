import SwiftUI
import MapKit

public struct LiveMapView: UIViewRepresentable {
    @EnvironmentObject var viewModel: DriveViewModel

    public init() {}

    public func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        // Use system appearance only when the chosen MapStyleChoice is the dark
        // .mutedDark default; lighter styles should respect the user's iOS theme.
        let style = viewModel.mapStyle
        map.overrideUserInterfaceStyle = (style == .mutedDark) ? .dark : .unspecified

        // Apply the user's chosen MapStyleChoice. Each branch maps to a native
        // MKMapConfiguration subclass — 100% free, no token required.
        applyMapStyle(style, to: map)

        #if DEBUG || DEVELOPER_BUILD
        if viewModel.locationManager.isMockMode {
            map.showsUserLocation = false
        } else {
            map.showsUserLocation = true
        }
        #else
        map.showsUserLocation = true
        #endif

        map.showsCompass = false // We'll surface a native MKCompassButton instead.
        map.showsScale = false   // We'll surface MKScaleView (preserved).

        // Native controls setup — scale + compass + tracking + pitch-toggle.
        setupNativeControls(for: map)

        map.isPitchEnabled = true
        map.isRotateEnabled = true
        map.isZoomEnabled = true
        map.isScrollEnabled = true

        // MapKit's native pitch toggle is intentionally HIDDEN — we
        // surface our own SwiftUI 2D/3D pill in
        // `MapWithHUDView.MapPitchToggleButton` so it sits squeezed next
        // to the search bar in the top row (the user wants the chrome
        // to read "[thin search bar][2D/3D pill]" with the toggle
        // directly adjacent to the search input). The native button
        // auto-positions in the top-right corner regardless of layout —
        // hiding it gives us full control of placement. The native
        // pinch gesture still works for free perspective pitch when
        // the user's mode is `.auto`. MKPitchToggle is still not a
        // MapKit class (the SwiftUI analog is `MapPitchToggle(view:)`),
        // but we no longer need it since our SwiftUI pill owns the
        // toggle surface.
        map.pitchButtonVisibility = .hidden

        // MKUserTrackingButton is added as an explicit subview in
        // setupNativeControls(for:) — we deliberately do NOT also set
        // `map.showsUserTrackingButton = true` here, otherwise the system
        // would add a duplicate at its default location.

        // Use plain follow mode while free-driving. MapKit's heading tracker
        // continuously reacts to compass noise; the custom CameraAnimator owns
        // pitch/altitude, so combining that tracker with camera updates makes
        // the map appear to zoom/settle repeatedly. Navigation switches to
        // `.followWithHeading` below when turn-by-turn guidance needs heading.
        map.userTrackingMode = .follow

        // Add gesture detection for manual mode.
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleManualInteraction(_:)))
        pan.delegate = context.coordinator
        map.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleManualInteraction(_:)))
        pinch.delegate = context.coordinator
        map.addGestureRecognizer(pinch)
        
        // Long-press gesture for naming locations.
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.6
        longPress.delegate = context.coordinator
        map.addGestureRecognizer(longPress)

        // Honor the persisted POI toggle from Settings — on by default for
        // .gasStation / .parking / .hospital / .police / .restaurant / .cafe.
        applyPOIFilter(viewModel.showApplePOIs, to: map)

        // Initialize the camera system with the current camera state.
        context.coordinator.cameraAnimator.reset(to: map)

        return map
    }

    /// Swap the active MKMapConfiguration to match the user's MapStyleChoice.
    /// Called on `makeUIView` and whenever `viewModel.mapStyleRaw` changes.
    private func applyMapStyle(_ style: DriveViewModel.MapStyleChoice, to map: MKMapView) {
        if #available(iOS 17.0, *) {
            switch style {
            case .mutedDark:
                let cfg = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .muted)
                cfg.showsTraffic = true
                map.preferredConfiguration = cfg
            case .standard:
                let cfg = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .default)
                cfg.showsTraffic = true
                map.preferredConfiguration = cfg
            case .satellite:
                let cfg = MKImageryMapConfiguration(elevationStyle: .realistic)
                map.preferredConfiguration = cfg
            case .hybridFlyover:
                let cfg = MKHybridMapConfiguration(elevationStyle: .realistic)
                map.preferredConfiguration = cfg
            }
        } else if #available(iOS 16.0, *) {
            // iOS 16 fallback (we deploy 18+ but keep guard for safety).
            let cfg = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .muted)
            cfg.showsTraffic = true
            map.preferredConfiguration = cfg
        } else {
            map.mapType = (style == .satellite || style == .hybridFlyover) ? .satellite : .mutedStandard
        }
    }

    /// Toggles Apple's native POI glyphs (gas / food / hospital / parking).
    /// Empty include-list = nothing shown (the right "off" behavior).
    private func applyPOIFilter(_ show: Bool, to map: MKMapView) {
        if show {
            map.pointOfInterestFilter = MKPointOfInterestFilter(including: [
                .gasStation, .parking, .hospital, .police, .restaurant, .cafe, .pharmacy, .atm, .evCharger
            ])
        } else {
            // MKPointOfInterestFilter(including: []) hides all POI glyphs.
            // Previously we used excludingAll:[] which actually shows ALL 50+
            // categories — a regression flagged by code review.
            map.pointOfInterestFilter = MKPointOfInterestFilter(including: [])
        }
    }

    // Note: tint resolution now lives on `VehicleIconTint.uiColor` /
    // `VehicleIconTint.color` so the SwiftUI picker and the UIKit
    // annotation view share one source of truth. The previous
    // `swiftUIColor(for:)` mirror function was deleted during the
    // FB25 cleanup (code review flagged the duplication).

    private func setupNativeControls(for map: MKMapView) {
        // MARK: - Native MKScaleView
        // Apple's own scale legend that updates automatically with the camera.
        let scale = MKScaleView(mapView: map)
        scale.scaleVisibility = .adaptive
        scale.legendAlignment = .leading
        scale.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(scale)

        // Top-trailing stack below the search row: compass + explicit
        // user-tracking button positioned under the SwiftUI 3D toggle
        // button so all chrome controls sit near each other in the top
        // right. Per TestFlight 2.2.0 (b397) feedback from
        // srihan.yeleswarapu@gmail.com: "Bring the compass and direction
        // buttons right below the 3D button with some padding ofc."
        // The 3D pill sits in the search HStack at safeAreaInsets.top + 8
        // + 48pt search bar height; we start the compass at +72 to clear
        // the row with ~16pt gap.
        guard #available(iOS 17.0, *) else {
            NSLayoutConstraint.activate([
                scale.topAnchor.constraint(equalTo: map.safeAreaLayoutGuide.topAnchor, constant: 10),
                scale.leadingAnchor.constraint(equalTo: map.leadingAnchor, constant: 16)
            ])
            return
        }

        // MKCompassButton — appears only when the user has rotated the map
        // away from true north so we don't clutter the chrome otherwise.
        // We capture the reference on the coordinator so FB28 can hide
        // it via `compassVisibility = .hidden` while the search bar is
        // focused (then restore to `.adaptive` once the search closes).
        let compass = MKCompassButton(mapView: map)
        compass.compassVisibility = .adaptive
        compass.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(compass)

        // MKUserTrackingButton — explicit recenter. The system one
        // (`map.showsUserTrackingButton = true`) is disabled below so the
        // user only sees this single pinned instance. The captured
        // reference supports FB28: hide via `isHidden` while searching.
        let trackingButton = MKUserTrackingButton(mapView: map)
        trackingButton.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(trackingButton)

        NSLayoutConstraint.activate([
            scale.topAnchor.constraint(equalTo: map.safeAreaLayoutGuide.topAnchor, constant: 10),
            scale.leadingAnchor.constraint(equalTo: map.leadingAnchor, constant: 16),

            // Compass + tracking button repositioned to top-right, below
            // the SwiftUI search bar / 3D toggle row.
            compass.trailingAnchor.constraint(equalTo: map.trailingAnchor, constant: -16),
            compass.topAnchor.constraint(equalTo: map.safeAreaLayoutGuide.topAnchor, constant: 72),

            trackingButton.trailingAnchor.constraint(equalTo: map.trailingAnchor, constant: -16),
            trackingButton.topAnchor.constraint(equalTo: compass.bottomAnchor, constant: 8)
        ])

        // Stash the buttons on the coordinator so `updateUIView` can
        // toggle their visibility against `isSearchingLocally` without
        // walking the subview tree each render.
        if let coordinator = map.delegate as? Coordinator {
            coordinator.compassButton = compass
            coordinator.trackingButton = trackingButton
        }
    }

    public func updateUIView(_ uiView: MKMapView, context: Context) {
        // Swap in the map style / POI filter ASAP after the underlying UserDefaults
        // value mutates from the Settings screen. Comparing via a coordinator
        // cache avoids rebuilding the MKMapConfiguration (and the camera
        // animation that comes with it) on every UIViewRepresentable invalidate.
        let currentStyle = viewModel.mapStyle
        if context.coordinator.lastAppliedMapStyle != currentStyle {
            applyMapStyle(currentStyle, to: uiView)
            context.coordinator.lastAppliedMapStyle = currentStyle
        }
        if context.coordinator.lastAppliedShowPOIs != viewModel.showApplePOIs {
            applyPOIFilter(viewModel.showApplePOIs, to: uiView)
            context.coordinator.lastAppliedShowPOIs = viewModel.showApplePOIs
        }

        // FB28 — COLLAPSE chrome while the search bar is focused.
        // The native compass + tracking buttons live as subviews on the
        // MKMapView; we hold references on the coordinator so we can
        // flip `compassVisibility` / `isHidden` without walking the
        // subview tree on every updateUIView pass. The SwiftUI 3D pill
        // is hidden in MapWithHUDView against the same flag so the
        // search row visually reads as a single expanded bar.
        let isSearching = viewModel.isSearching || viewModel.isSearchingLocally
        if #available(iOS 17.0, *) {
            context.coordinator.compassButton?.compassVisibility = isSearching ? .hidden : .adaptive
            context.coordinator.trackingButton?.isHidden = isSearching
        }

        // Limit camera updates during search to prevent unwanted "jumping"
        // while the keyboard is up.
        if viewModel.isSearching || viewModel.isSearchingLocally {
            // We still want to update overlays (status line), but we skip camera changes.
            context.coordinator.updateOverlaysIfNeeded(uiView, viewModel: viewModel)
            return
        }

        // If user has manually detached, just release any zoom restriction and stop
        if viewModel.isMapDetached {
            if uiView.userTrackingMode != .none {
                uiView.userTrackingMode = .none
            }
            return
        }

        // Re-engage native tracking if it was released, and keep compass
        // tracking out of free-drive camera updates. The custom animator owns
        // altitude/pitch; MapKit should only own centering unless navigation
        // explicitly needs heading-following.
        let desiredTrackingMode: MKUserTrackingMode =
            viewModel.isNavigating ? .followWithHeading : .follow
        if uiView.userTrackingMode != desiredTrackingMode {
            #if DEBUG || DEVELOPER_BUILD
            if !viewModel.locationManager.isMockMode {
                uiView.setUserTrackingMode(desiredTrackingMode, animated: false)
            }
            #else
            uiView.setUserTrackingMode(desiredTrackingMode, animated: false)
            #endif
        }

        #if DEBUG || DEVELOPER_BUILD
        if viewModel.locationManager.isMockMode {
            // Update Simulated Car position and camera manually
            context.coordinator.updateSimulatedCar(uiView, viewModel: viewModel)
        }
        #endif

        // PITCH OVERRIDE — instant short-circuit for user-pinned 2D/3D.
        //
        // Runs BEFORE the camera system so a freshly-tapped `.forced3D`
        // flips the camera immediately even while stationary. The
        // `CameraAnimator` / `CameraDecisionEngine` below then maintains
        // the pinned pitch on subsequent ticks via the
        // `userPitchOverride` field in `CameraContext`. Only fires when
        // the mode actually changed; equality check is what made the
        // pill's repeat-tap no-op the previous implementation.
        //
        // CRITICAL: animated:false (NOT animated:true) on the setCamera.
        // The camera system below fires setCamera(animated:false) on the
        // same updateUIView pass — animated:true would queue a MapKit
        // spring animation mid-frame, then the animator's animated:false
        // call would abort it, leaving the camera altitude/pitch in a
        // half-way state that manifested as random zooming-in/zooming-out
        // pulses during TestFlight b462. With animated:false the snap
        // completes synchronously, the animator's reset() reads the
        // snapped value into displayPitch/displayAltitude, and the
        // animator's subsequent EMA update sees no disparity to fix.
        let userPitchMode = viewModel.mapPitchMode
        if userPitchMode != .auto, userPitchMode != context.coordinator.lastAppliedPitchMode {
            let target = userPitchMode.targetPitch
            if Double(uiView.camera.pitch) != target {
                let cam = uiView.camera.copy() as! MKMapCamera
                cam.pitch = CGFloat(target)
                // CRITICAL: Use property setter (iOS 13+) instead of
                // setCamera(_:animated:) to avoid disabling user tracking
                // mode. See CameraAnimator.update() for full explanation.
                uiView.camera = cam
            }
            context.coordinator.lastAppliedPitchMode = userPitchMode
            // Reset the camera animator's internal state so the next tick
            // starts from the new pinned camera position rather than
            // trying to interpolate from the old one.
            context.coordinator.cameraAnimator.reset(to: uiView)
        } else if userPitchMode == .auto {
            // Releasing back to auto: clear the latch so a future pin to
            // the same mode re-applies (otherwise tapping
            // 3D → auto → 3D would no-op the third tap).
            context.coordinator.lastAppliedPitchMode = .auto
        }

        // Camera system: build context and let the decision engine + animator
        // smoothly update altitude and pitch without breaking tracking mode.
        // Camera tuning tables are expressed in MPH, while the published HUD
        // speed is KM/H when the user selects Metric.
        let cameraSpeedMph = SpeedFormatting.isMetric(SpeedFormatting.measurementSystem())
            ? viewModel.speed * 0.621371
            : viewModel.speed
        let cameraCtx = CameraContext(
            speed: cameraSpeedMph,
            speedLimit: viewModel.limit,
            isNavigating: viewModel.isNavigating,
            isRecording: viewModel.isRecording,
            distanceToNextTurn: viewModel.distanceToNextTurn,
            instruction: viewModel.nextManeuverInstruction,
            maneuverImageName: viewModel.nextManeuverImageName,
            destinationDistance: viewModel.distanceToDestination,
            hasRoute: viewModel.currentRoute != nil,
            userPitchOverride: viewModel.mapPitchMode
        )
        context.coordinator.cameraAnimator.update(mapView: uiView, context: cameraCtx)

        // Update overlays only when necessary (not every single frame)
        context.coordinator.updateOverlaysIfNeeded(uiView, viewModel: viewModel)
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: LiveMapView
        private var interactionTimer: Timer?

        /// The camera system — replaces all previous `updateSmartAltitude`
        /// logic, cooldown timers, and altitude thresholds.
        let cameraAnimator = CameraAnimator()

        // FB28 — captured by `setupNativeControls(_:)` so `updateUIView`
        // can flip `.compassVisibility` / `.isHidden` against the
        // `isSearchingLocally` flag without walking the subview tree on
        // every render.
        weak var compassButton: MKCompassButton? = nil
        weak var trackingButton: MKUserTrackingButton? = nil

        // FB25 — last-applied vehicle icon id so `updateUIView` knows
        // when the user picked a new icon and needs the user-location
        // annotation re-rendered. `Optional<String>` (not empty-string
        // sentinel) so a literal "" id cannot silently match a no-icon
        // initial value and produce a "no change needed" verdict.
        // Cache the last-applied map style / POI filter / pitch mode so
        // we don't rebuild the MKMapConfiguration (and trigger a fresh
        // camera animation) on every UIViewRepresentable invalidate.
        var lastAppliedMapStyle: DriveViewModel.MapStyleChoice? = nil
        var lastAppliedShowPOIs: Bool? = nil
        // Tracks the last `DriveViewModel.MapPitchMode` we forwarded to
        // `MKMapView.setCamera`. Used by the pitch-override short-circuit
        // in `updateUIView` so a repeat-tap on the same mode (e.g. user
        // taps 3D → auto → 3D again) re-applies the camera change
        // rather than no-op'ing the equality check.
        var lastAppliedPitchMode: DriveViewModel.MapPitchMode? = nil
        // Last-known fingerprint of the alternative-routes list (count +
        // hash of distances + isSelectingRoute). Used by
        // `updateOverlaysIfNeeded` to decide when to rebuild the
        // alternative-route polylines — we deliberately do NOT rebuild
        // them on every 500 ms GPS tick, only when the route list
        // actually changes.
        //
        // `Optional<Int>` (not `Int` with sentinel `-1`) so a Hasher
        // collision that happens to hash to exactly `-1` cannot silently
        // match our reset sentinel and produce a stale "no rebuild
        // needed" verdict.
        var lastAltRouteFingerprint: Int? = nil

        /// Tracks whether `isSelectingRoute` was true on the previous
        /// `updateOverlaysIfNeeded` call. When the user dismisses the
        /// route-picker (X button), `isSelectingRoute` flips to false
        /// and the fingerprint check short-circuits — without this
        /// tracker the stale route polylines stay on the map.
        var lastIsSelectingRoute: Bool = false

        /// Stable fingerprint of the alternative-routes list. We hash
        /// count + (distance, expectedTravelTime, name) per route so the
        /// signature flips whenever the user re-runs
        /// `MKDirections.calculate()`. `name` matters because in dense
        /// city grids two entirely different route geometries can
        /// coincidentally have identical distance + ETA to the second,
        /// and we want the polyline set to actually rebuild in that
        /// case (instead of silently reusing the stale overlay set).
        static func altRouteFingerprint(for routes: [MKRoute]) -> Int {
            var hasher = Hasher()
            hasher.combine(routes.count)
            for r in routes {
                hasher.combine(Int(r.distance))
                hasher.combine(Int(r.expectedTravelTime))
                hasher.combine(r.name)
            }
            return hasher.finalize()
        }

        /// Fingerprint for the stops list so the map rebuilds stop annotations
        /// when the user adds, removes, or reorders stops.
        static func stopFingerprint(for stops: [RouteStop]) -> Int {
            var hasher = Hasher()
            hasher.combine(stops.count)
            for stop in stops {
                hasher.combine(stop.id)
                hasher.combine(Int(stop.latitude * 1000))
                hasher.combine(Int(stop.longitude * 1000))
            }
            return hasher.finalize()
        }

        /// Cheap geometry signature for route invalidation. Sampling the
        /// endpoints and midpoint is sufficient to detect normal reroutes
        /// without walking every polyline point on each SwiftUI update.
        static func routeFingerprint(for route: MKRoute) -> Int {
            var hasher = Hasher()
            hasher.combine(route.polyline.pointCount)
            hasher.combine(Int(route.distance))
            let count = route.polyline.pointCount
            guard count > 0 else { return hasher.finalize() }
            let points = route.polyline.points()
            // Fixed order is important: Hasher combines values sequentially,
            // so iterating a Set would make an unchanged route appear to
            // have a new fingerprint and rebuild every overlay on every tick.
            // Sample evenly across the complete geometry rather than only a
            // midpoint. A reroute can preserve endpoints and total distance
            // while changing a long interior section. A bounded 17-point
            // sample catches those changes without hashing every GPS vertex
            // on every SwiftUI update.
            let sampleCount = min(17, count)
            let sampledIndices = (0..<sampleCount).map { sample in
                sampleCount == 1 ? 0 : (sample * (count - 1)) / (sampleCount - 1)
            }
            for index in sampledIndices {
                let coordinate = points[index].coordinate
                hasher.combine(Int(coordinate.latitude * 100_000))
                hasher.combine(Int(coordinate.longitude * 100_000))
            }
            return hasher.finalize()
        }
        // Maneuver annotation we own — ref so we don't churn annotations on
        // every GPS ping.
        private var maneuverAnnotation: ManeuverAnnotation? = nil

        // Overlay state tracking to avoid redundant remove/add cycles
        private var lastRoutePolylineCount: Int = 0
        private var lastHistoryCounts: (safeCount: Int, overCount: Int) = (0, 0)
        private var lastIsNavigating: Bool = false
        private var lastRouteDistance: Double = 0
        /// Geometry fingerprint catches a reroute that has the same distance
        /// as the previous route. Distance-only invalidation left old route
        /// lines on screen, which looked like random trailing geometry.
        private var lastRouteFingerprint: Int? = nil
        private var lastSessionReadingCount: Int = 0
        private var lastHistorySessionID: UUID?
        private var hasAutoFramedRoute: Bool = false
        private var lastStopFingerprint: Int = 0

        #if DEBUG || DEVELOPER_BUILD
        private var simulatedCarAnnotation: MKPointAnnotation?
        #endif

        init(_ parent: LiveMapView) {
            self.parent = parent
        }

        @objc func handleManualInteraction(_ gesture: UIGestureRecognizer) {
            if gesture.state == .began || gesture.state == .changed {
                startManualMode(gesture.view as? MKMapView)
            }
        }
        
        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            parent.viewModel.presentNameLocationSheet(for: coordinate)
        }

        public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }

        public func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            // No-op here. We only detach on actual gesture recognizers to avoid
            // detaching when the system updates the altitude or follows the user.
        }

        private func startManualMode(_ mapView: MKMapView?) {
            // First, kill any existing resume timer
            interactionTimer?.invalidate()

            if !parent.viewModel.isMapDetached {
                parent.viewModel.isMapDetached = true
                mapView?.userTrackingMode = .none
                DebugLogger.shared.log("MAP DETACHED: Manual Control")
            }

            // Auto-resume after 10 seconds of inactivity (longer to be safe)
            interactionTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.parent.viewModel.isMapDetached = false
                    DebugLogger.shared.log("MAP ATTACHED: Tracking Resumed")
                }
            }
        }

        #if DEBUG || DEVELOPER_BUILD
        // MARK: - Simulation Management
        func updateSimulatedCar(_ mapView: MKMapView, viewModel: DriveViewModel) {
            guard let mockLocation = viewModel.locationManager.latestLocation else { return }

            // Rebuild annotation if missing
            if simulatedCarAnnotation == nil {
                let ann = MKPointAnnotation()
                ann.title = "SIMULATED_CAR"
                mapView.addAnnotation(ann)
                simulatedCarAnnotation = ann
            }

            // Update coordinate
            simulatedCarAnnotation?.coordinate = mockLocation.coordinate

            // Sync map showsUserLocation state
            if mapView.showsUserLocation != false {
                mapView.showsUserLocation = false
            }

            // If following, re-center map manually
            if !viewModel.isMapDetached {
                mapView.setCenter(mockLocation.coordinate, animated: true)
            }
        }
        #endif

        // MARK: - Smart Overlay Management
        // Only rebuild overlays when the underlying data actually changes.
        // This was the primary cause of 0.5 fps — removing and re-adding overlays every frame.
        func updateOverlaysIfNeeded(_ mapView: MKMapView, viewModel: DriveViewModel) {
            let vm = viewModel
            let currentRouteDistance = vm.currentRoute?.distance ?? 0
            let currentRouteFingerprint = vm.currentRoute.map(Self.routeFingerprint(for:))
            let currentSession = vm.sessionRecorder.currentSession
            let currentSessionID = currentSession?.id
            let currentReadingCount = currentSession?.readings.count ?? 0
            let isNavigating = vm.isNavigating
            let currentStopFP = Self.stopFingerprint(for: vm.routeStops)

            let routeChanged = isNavigating != lastIsNavigating
                || abs(currentRouteDistance - lastRouteDistance) > 1.0
                || currentRouteFingerprint != lastRouteFingerprint
            // Throttling: only rebuild history every 5 points to save battery.
            // SAFETY: never trigger a history-based rebuild while navigating
            // or selecting a route. During these states we draw route
            // polylines (not history), so rebuilding overlays every 5 GPS
            // ticks is pure waste — and worse, the removeOverlays() call
            // at the top of rebuildOverlays creates a brief flicker where
            // stale history polylines from the pre-navigation recording
            // phase flash on-screen before the route polyline is redrawn.
            //
            // A session identity change is also a rebuild trigger. Count-only
            // tracking misses a reset to zero, and it cannot distinguish a
            // newly-created session with the same number of readings. Both
            // cases previously left the old session's lines on the map.
            let previousReadingCount = lastHistoryCounts.safeCount + lastHistoryCounts.overCount
            let historyChanged = !isNavigating && !vm.isSelectingRoute && (
                currentSessionID != lastHistorySessionID
                || currentReadingCount < previousReadingCount
                || currentReadingCount >= previousReadingCount + 5
            )
            let stopsChanged = currentStopFP != lastStopFingerprint

            // Detect when the user dismissed the route picker (isSelectingRoute
            // transitioned true→false). When this happens the overlay fingerprint
            // check short-circuits because vm.isSelectingRoute is now false, so
            // stale route polylines would remain drawn on the map. We jump to
            // rebuildOverlays which calls removeOverlays(…) first, clearing them.
            let routePickerDismissed = lastIsSelectingRoute && !vm.isSelectingRoute
            // Also detect new route-selection step so the initial fingerprint
            // rebuild fires (new routes from a fresh search).
            let routePickerOpened = !lastIsSelectingRoute && vm.isSelectingRoute

            guard routeChanged || historyChanged || stopsChanged || (isNavigating && lastRouteDistance == 0) || routePickerDismissed || routePickerOpened else {
                // ALTERNATIVE-ROUTE FINGERPRINT: rebuild when availableRoutes
                // count changes during the route-selection step. We hash
                // count + a stable signature (sum of distances) so the check
                // doesn't fire on every 500 ms GPS tick.
                let fp = vm.isSelectingRoute ? Self.altRouteFingerprint(for: vm.availableRoutes) : -1
                if vm.isSelectingRoute && fp != lastAltRouteFingerprint {
                    rebuildOverlays(mapView, viewModel: vm)
                    lastAltRouteFingerprint = fp
                }
                // Always sync lastIsSelectingRoute even when the guard
                // short-circuits, otherwise the dismissed-picker detection
                // fires a stale rebuild on the next pass.
                lastIsSelectingRoute = vm.isSelectingRoute
                return
            }

            // Perform the overlay rebuild only when data changed
            rebuildOverlays(mapView, viewModel: vm)

            // Update tracking state
            lastIsNavigating = isNavigating
            lastIsSelectingRoute = vm.isSelectingRoute
            lastRouteDistance = currentRouteDistance
            lastRouteFingerprint = currentRouteFingerprint
            lastStopFingerprint = currentStopFP
            let readings = vm.sessionRecorder.currentSession?.readings ?? []
            let safeCount = readings.filter { !$0.overLimit }.count
            let overCount = readings.filter { $0.overLimit }.count
            lastHistoryCounts = (safeCount, overCount)
            lastHistorySessionID = currentSessionID
        }

        private func rebuildOverlays(_ mapView: MKMapView, viewModel: DriveViewModel) {
            // Remove all overlays and non-user annotations
            mapView.removeOverlays(mapView.overlays)
            mapView.removeAnnotations(mapView.annotations.filter { !($0 is MKUserLocation) })

            // Has any route work to render at all?
            let hasAvailableRoutes = viewModel.isSelectingRoute && !viewModel.availableRoutes.isEmpty
            let hasActiveRoute = viewModel.isNavigating && viewModel.currentRoute != nil

            // Route polyline + destination
            if hasActiveRoute, let route = viewModel.currentRoute {
                let legs = viewModel.routeLegs
                let hasLegRoutes = !viewModel.routeStops.isEmpty
                    && legs.count > 1
                    && legs.allSatisfy({ $0.route != nil })

                if hasLegRoutes {
                    // MULTI-STOP: draw the coordinator's active leg bold,
                    // not always leg zero. The old behavior kept the first
                    // leg cyan after reaching a stop, so the visible line no
                    // longer matched the spoken directions.
                    let activeIndex = min(
                        max(viewModel.navigationCoordinator.activeMultiStopLegIndexForDisplay, 0),
                        legs.count - 1
                    )
                    if let activeRoute = legs[activeIndex].route {
                        let glowLine = GlowPolyline(points: activeRoute.polyline.points(), count: activeRoute.polyline.pointCount)
                        glowLine.glowColor = UIColor(DesignSystem.cyan)
                        mapView.addOverlay(glowLine, level: .aboveRoads)

                        let activeLine = NavPolyline(points: activeRoute.polyline.points(), count: activeRoute.polyline.pointCount)
                        activeLine.statusColor = UIColor(DesignSystem.cyan)
                        activeLine.isRouteOverlay = true
                        activeLine.useGradient = viewModel.gradientRouteEnabled
                        mapView.addOverlay(activeLine, level: .aboveRoads)
                    }

                    for (index, leg) in legs.enumerated() where index != activeIndex {
                        if let legRoute = leg.route {
                            let dimmed = DimmedLegPolyline(points: legRoute.polyline.points(), count: legRoute.polyline.pointCount)
                            mapView.addOverlay(dimmed, level: .aboveRoads)
                        }
                    }
                } else {
                    // SINGLE-ROUTE: existing behavior — draw everything bold cyan
                    let glowLine = GlowPolyline(points: route.polyline.points(), count: route.polyline.pointCount)
                    glowLine.glowColor = UIColor(DesignSystem.cyan)
                    mapView.addOverlay(glowLine, level: .aboveRoads)

                    let polyline = NavPolyline(points: route.polyline.points(), count: route.polyline.pointCount)
                    polyline.statusColor = UIColor(DesignSystem.cyan)
                    polyline.isRouteOverlay = true
                    polyline.useGradient = viewModel.gradientRouteEnabled
                    mapView.addOverlay(polyline, level: .aboveRoads)
                }

                if let dest = viewModel.destination {
                    let destinationAnnotation = MKPointAnnotation()
                    destinationAnnotation.coordinate = dest.placemark.coordinate
                    destinationAnnotation.title = dest.name
                    mapView.addAnnotation(destinationAnnotation)
                }

                // MKMapRect auto-fit: when a fresh route appears and we
                // haven't already framed it, animate to a rect that contains
                // the entire polyline plus the current location so the user
                // sees the full trip before zoom-in kicks off.
                if !hasAutoFramedRoute {
                    var rect = route.polyline.boundingMapRect
                    if let userLoc = viewModel.locationManager.latestLocation {
                        let userRect = MKMapRect(
                            x: MKMapPoint(userLoc.coordinate).x - 1_000,
                            y: MKMapPoint(userLoc.coordinate).y - 1_000,
                            width: 2_000,
                            height: 2_000
                        )
                        rect = rect.union(userRect)
                    }
                    mapView.setVisibleMapRect(
                        rect,
                        edgePadding: UIEdgeInsets(top: 80, left: 60, bottom: 200, right: 60),
                        animated: false
                    )
                    // Sync the camera animator's display altitude with the
                    // route-fit camera position so it doesn't jump on the
                    // first frame. The animator's route-init fly-out
                    // (2.5× boost) re-triggers on the next tick because
                    // reset() clears `wasNavigating`, and `detectTransitions`
                    // will re-detect route initiation.
                    cameraAnimator.reset(to: mapView)
                    hasAutoFramedRoute = true
                }
            } else if hasAvailableRoutes {
                // ROUTE-SELECTION STEP — user is choosing between routes.
                // MKDirections returns routes sorted by `expectedTravelTime`
                // ascending, so [0] is always the "suggested" (fastest).
                // Draw that one bold (cyan glow + cyan stroke, same look as
                // the in-progress navigation line) and every other route
                // lighter (white-with-opacity, thinner) so the user
                // visually understands which is the recommended one and
                // how much extra time/distance each alternative costs.
                renderAlternativeRoutes(mapView, routes: viewModel.availableRoutes, viewModel: viewModel)
                // Auto-frame to fit the union of all routes + the user
                // once on first appearance, so the user sees all options
                // on screen simultaneously. PICKER-STATE EDGE PADDING:
                // top:200 / bottom:60 (inverted from the active-nav path
                // because the `RouteSelectionCard` is at the top — it sits
                // in `geo.safeAreaInsets.top + 12 ... +16` blocks plus its
                // own ~120pt intrinsic height — while the BOTTOM HUD is
                // hidden by the parent's `if !driveViewModel.isSelectingRoute`
                // gate. Using the active-nav padding (top:80, bottom:200)
                // here would frame the route directly underneath the
                // picker card while leaving the bottom wasted. Apple's
                // Maps app uses a roughly 165/55 split for this exact
                // scenario; we round to 200/60 for a tiny safety margin.
                if !hasAutoFramedRoute {
                    var rect: MKMapRect = .null
                    for r in viewModel.availableRoutes {
                        rect = rect.union(r.polyline.boundingMapRect)
                    }
                    if let userLoc = viewModel.locationManager.latestLocation {
                        let userRect = MKMapRect(
                            x: MKMapPoint(userLoc.coordinate).x - 1_000,
                            y: MKMapPoint(userLoc.coordinate).y - 1_000,
                            width: 2_000,
                            height: 2_000
                        )
                        rect = rect.union(userRect)
                    }
                    // A route selection can publish several SwiftUI updates
                    // while MapKit is still settling. Do not enqueue an
                    // animated camera transition here; the camera animator
                    // owns subsequent changes and an animated fit creates the
                    // zoom-in/zoom-out jitter reported in TestFlight.
                    mapView.setVisibleMapRect(
                        rect,
                        edgePadding: UIEdgeInsets(top: 200, left: 60, bottom: 60, right: 60),
                        animated: false
                    )
                    hasAutoFramedRoute = true
                }
            } else {
                // Drop the auto-fit latch when navigation ends so the next
                // navigation re-frames the polyline.
                hasAutoFramedRoute = false
                lastRouteFingerprint = nil
                // Also clear the alt-route fingerprint so a fresh
                // `selectDestinationAndCalculateRoutes` call triggers a
                // rebuild next time the user opens the picker.
                lastAltRouteFingerprint = nil
            }

            // Speed-camera annotations cluster normally under either state
            // (navigating AND selecting-route both show real-world camera
            // POIs around the user). Pull them out of the navig-only path
            // so the picker state still respects the same camera map.
            if !SpeedCameraService.shared.cameras.isEmpty {
                let nearby = SpeedCameraService.shared.getNearbyCameras(
                    to: viewModel.locationManager.latestLocation ?? CLLocation()
                )
                for camera in nearby.prefix(60) {
                    let ann = SpeedCameraAnnotation(camera: camera)
                    mapView.addAnnotation(ann)
                }
            }

            // Route stop annotations — numbered pins for each intermediate stop
            // so the driver can see them on the map even with the HUD card
            // occluded (e.g. when panning the map manually).
            if !viewModel.routeStops.isEmpty {
                let existingStopIDs = Set(
                    mapView.annotations.compactMap { $0 as? StopAnnotation }.map(\.stopID)
                )
                for (index, stop) in viewModel.routeStops.enumerated() {
                    if !existingStopIDs.contains(stop.id) {
                        let ann = StopAnnotation(stop: stop, index: index + 1)
                        mapView.addAnnotation(ann)
                    }
                }
                // Remove stale stop annotations
                let currentIDs = Set(viewModel.routeStops.map(\.id))
                for ann in mapView.annotations {
                    if let stopAnn = ann as? StopAnnotation, !currentIDs.contains(stopAnn.stopID) {
                        mapView.removeAnnotation(stopAnn)
                    }
                }
            } else {
                // Remove all stop annotations when there are no stops
                for ann in mapView.annotations {
                    if ann is StopAnnotation {
                        mapView.removeAnnotation(ann)
                    }
                }
            }

            // Maneuver annotation — a large arrow dropped at the upcoming
            // turn point so the driver sees the exact spot even with the HUD
            // card occluded (e.g. when panning the map manually).
            if let coord = viewModel.nextManeuverCoordinate {
                if let existing = maneuverAnnotation {
                    // glyph is a plain Swift var (no KVO), so MapKit doesn't
                    // re-call viewFor: when only the arrow type changes
                    // mid-route. Push the new glyphImage directly to the
                    // live view so the user sees "left" -> "right" flips
                    // without panning first.
                    let glyphChanged = existing.glyph != viewModel.nextManeuverImageName
                    existing.coordinate = coord
                    existing.glyph = viewModel.nextManeuverImageName
                    if glyphChanged, let view = mapView.view(for: existing) as? MKMarkerAnnotationView {
                        view.glyphImage = UIImage(systemName: viewModel.nextManeuverImageName)
                            ?? UIImage(systemName: "arrow.up")
                        view.glyphTintColor = .white
                    }
                } else {
                    let ann = ManeuverAnnotation(
                        coordinate: coord,
                        glyph: viewModel.nextManeuverImageName
                    )
                    mapView.addAnnotation(ann)
                    maneuverAnnotation = ann
                }
            } else if let existing = maneuverAnnotation {
                mapView.removeAnnotation(existing)
                maneuverAnnotation = nil
            }

            // History line (color-coded by speed status).
            // DEFENSE-IN-DEPTH: skip the call entirely when navigating or
            // selecting a route. The inner guard in buildHistoryOverlays
            // already checks isNavigating, but during reroute flows there
            // can be a transient window where isNavigating flips false
            // briefly — if historyChanged fires in that gap the full
            // session trail gets drawn as red over-limit polylines.
            // Gating here eliminates that race.
            if !viewModel.isNavigating && !viewModel.isSelectingRoute {
                buildHistoryOverlays(mapView, viewModel: viewModel)
            }
        }

        /// Renders ALL of `routes` as map polylines during the route-selection
        /// step (`isSelectingRoute == true`). Routes[0] — the one
        /// `MKDirections` returns as the fastest / recommended — gets the
        /// same BOLD cyan-glow look as the in-progress navigation line so
        /// the user immediately understands which is "the suggested one".
        /// Routes 1..n — typically slower or longer — get a LIGHTER
        /// muted-white stroke at ~half the line weight so visually they
        /// read as "alternatives" without stealing attention from the
        /// suggested route.
        ///
        /// We deliberately do NOT use dashed lines for alternatives so the
        /// visual hierarchy reads unambiguously: bold = pick me, light =
        /// ok if you insist. (TestFlight 2.2.x user feedback: "show the
        /// routes on the map ... show the suggested one in a more bold
        /// way, and show the slower ones or more distance in lighter
        /// way").
        private func renderAlternativeRoutes(_ mapView: MKMapView, routes: [MKRoute], viewModel: DriveViewModel) {
            for (idx, route) in routes.enumerated() {
                let pts = route.polyline.points()
                let cnt = route.polyline.pointCount
                if idx == 0 {
                    // BOLD: same cyan glow + cyan stroke as the active
                    // navigation line so the "suggested" route is visually
                    // identical to what the user will see once they tap GO.
                    let glow = GlowPolyline(points: pts, count: cnt)
                    glow.glowColor = UIColor(DesignSystem.cyan)
                    mapView.addOverlay(glow, level: .aboveRoads)
                    let polyline = NavPolyline(points: pts, count: cnt)
                    polyline.statusColor = UIColor(DesignSystem.cyan)
                    polyline.isRouteOverlay = true
                    polyline.useGradient = viewModel.gradientRouteEnabled
                    mapView.addOverlay(polyline, level: .aboveRoads)
                } else {
                    // LIGHT: muted white-with-opacity, thinner. Visible on
                    // both the dark (mutedDark) and light (standard /
                    // satellite) map styles without competing with the
                    // bold cyan route for attention.
                    let alt = AltRoutePolyline(points: pts, count: cnt)
                    alt.routeIndex = idx
                    mapView.addOverlay(alt, level: .aboveRoads)
                }
            }

            // Single destination annotation. We previously re-added this
            // per-route in earlier revision cycles which produced duplicate
            // map pins; one pin is correct here since all alternatives
            // share the same destination.
            if let dest = viewModel.destination {
                let destAnn = MKPointAnnotation()
                destAnn.coordinate = dest.placemark.coordinate
                destAnn.title = dest.name
                mapView.addAnnotation(destAnn)
            }
        }

        private func buildHistoryOverlays(_ mapView: MKMapView, viewModel: DriveViewModel) {
            // Hide history trail when actively navigating or selecting a route
            // — the route polylines already show the path, and the grey
            // history trail overlaps them causing visual glitches
            // (TestFlight feedback: "Distorted trailing map").
            guard !viewModel.isNavigating, !viewModel.isSelectingRoute else { return }
            guard let session = viewModel.sessionRecorder.currentSession, !session.readings.isEmpty else { return }

            var safeCoords: [CLLocationCoordinate2D] = []
            var overCoords: [CLLocationCoordinate2D] = []

            // Never draw a fabricated straight line across a GPS outage or
            // location jump. A 250 m cap is above normal one-second highway
            // travel while still rejecting a snapped fix on a distant road.
            let maximumHistoryGap: CLLocationDistance = 250

            func addHistoryPolyline(_ coordinates: [CLLocationCoordinate2D], color: UIColor) {
                guard coordinates.count >= 2 else { return }
                let polyline = NavPolyline(coordinates: coordinates, count: coordinates.count)
                polyline.statusColor = color
                mapView.addOverlay(polyline, level: .aboveRoads)
            }

            func flushHistorySegments() {
                addHistoryPolyline(safeCoords, color: UIColor(white: 0.5, alpha: 0.5))
                addHistoryPolyline(overCoords, color: UIColor(DesignSystem.alertRed))
                safeCoords.removeAll(keepingCapacity: true)
                overCoords.removeAll(keepingCapacity: true)
            }

            var previousReading: SpeedReading?
            for reading in session.readings {
                let coordinate = CLLocationCoordinate2D(latitude: reading.latitude, longitude: reading.longitude)
                let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

                if let previousReading {
                    let previousCoordinate = CLLocationCoordinate2D(
                        latitude: previousReading.latitude,
                        longitude: previousReading.longitude
                    )
                    let previousLocation = CLLocation(
                        latitude: previousCoordinate.latitude,
                        longitude: previousCoordinate.longitude
                    )
                    let elapsed = reading.timestamp.timeIntervalSince(previousReading.timestamp)
                    if elapsed < 0 || elapsed > 10 || location.distance(from: previousLocation) > maximumHistoryGap {
                        flushHistorySegments()
                    }
                }

                if reading.overLimit {
                    if !safeCoords.isEmpty {
                        addHistoryPolyline(safeCoords, color: UIColor(white: 0.5, alpha: 0.5))
                        safeCoords.removeAll(keepingCapacity: true)
                    }
                    overCoords.append(coordinate)
                } else {
                    if !overCoords.isEmpty {
                        addHistoryPolyline(overCoords, color: UIColor(DesignSystem.alertRed))
                        overCoords.removeAll(keepingCapacity: true)
                    }
                    safeCoords.append(coordinate)
                }
                previousReading = reading
            }

            flushHistorySegments()
        }

        // MARK: - MKMapViewDelegate

        public func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? NavPolyline {
                // GRADIENT ROUTE: only the ROUTE polyline upgrades to
                // MKGradientPolylineRenderer. History polylines get the flat
                // MKPolylineRenderer below (the previous behavior) since
                // passing identical cyan-cyan stops renders as a flat color.
                if #available(iOS 17.0, *), polyline.useGradient, polyline.isRouteOverlay {
                    let renderer = MKGradientPolylineRenderer(polyline: polyline)
                    let colors: [UIColor] = [
                        UIColor(DesignSystem.cyan),
                        UIColor(DesignSystem.neonGreen)
                    ]
                    let stops: [CGFloat] = [0.0, 1.0]
                    renderer.setColors(colors, locations: stops)
                    renderer.lineWidth = 7.0
                    renderer.lineCap = .round
                    renderer.lineJoin = .round
                    return renderer
                }

                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = polyline.statusColor
                renderer.lineWidth = polyline.isRouteOverlay ? 7.0 : 5.0
                renderer.lineCap = .round
                renderer.lineJoin = .round
                if polyline.isRouteOverlay {
                    renderer.strokeColor = polyline.statusColor.withAlphaComponent(0.85)
                }
                return renderer
            }

            // Shadow/glow polyline rendered underneath the main route
            if let polyline = overlay as? GlowPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = polyline.glowColor.withAlphaComponent(0.3)
                renderer.lineWidth = 14.0
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }

            // ALTERNATIVE-ROUTE POLYLINE — drawn noticeably thinner and
            // with reduced opacity so the user visually reads it as
            // "secondary" against the bold cyan "suggested" line drawn
            // above. We use white-with-opacity on purpose so the
            // contrast holds across `muteDark`, `standard`, and
            // `satellite` map styles — a desaturated cyan vanishes on
            // satellite imagery, and pure dark gray vanishes on the
            // dark map. The 0.65 alpha is just high enough for legibility
            // against neutral-white road colors on Standard; the 4.0 pt
            // lineWidth (vs 7.0 for the bold suggested route) reinforces
            // "lighter" weight even when the color contrast is low.
            if let polyline = overlay as? AltRoutePolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor.white.withAlphaComponent(0.65)
                renderer.lineWidth = 4.0
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }

            // DIMMED LEG POLYLINE — used for route legs beyond the first
            // stop on a multi-stop route. Rendered as a muted grey line so
            // the driver can still see the route to the final destination,
            // but it's visually clear that only the first leg is the active
            // guidance. 0.40 alpha ensures legibility on both dark
            // (mutedDark) and light (standard / satellite) map styles.
            if let dimmed = overlay as? DimmedLegPolyline {
                let renderer = MKPolylineRenderer(polyline: dimmed)
                renderer.strokeColor = UIColor.white.withAlphaComponent(0.40)
                renderer.lineWidth = 5.0
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }

            return MKOverlayRenderer(overlay: overlay)
        }

        public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                // Return nil to use the default iOS blue dot.
                return nil
            }

            #if DEBUG || DEVELOPER_BUILD
            if annotation.title == "SIMULATED_CAR" {
                let id = "SimCar"
                var view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKUserLocationView
                if view == nil {
                    view = MKUserLocationView(annotation: annotation, reuseIdentifier: id)
                } else {
                    view?.annotation = annotation
                }
                return view
            }
            #endif

            // Native clustering identifier for all speed cameras. MapKit
            // automatically collapses them into a single numeric badge when
            // zoomed out (Apple Maps behavior) — this is the user's "pinch
            // out to see clusters" experience, free.
            if annotation is SpeedCameraAnnotation {
                let id = SpeedCameraAnnotation.clusterIdentifier
                var view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                if view == nil {
                    view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                    view?.markerTintColor = UIColor(DesignSystem.alertRed)
                    view?.glyphImage = UIImage(systemName: "camera.fill")
                    view?.canShowCallout = true
                    view?.clusteringIdentifier = id
                } else {
                    view?.annotation = annotation
                    view?.clusteringIdentifier = id
                }
                return view
            }

            // Stop annotation: rendered as a numbered badge on a cyan
            // marker to mirror Apple Maps' waypoint pins. The number is
            // the stop order (1, 2, 3...) shown as the glyph.
            if let stopAnno = annotation as? StopAnnotation {
                let id = StopAnnotation.reuseIdentifier
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.canShowCallout = true
                view.isEnabled = true
                view.markerTintColor = UIColor(DesignSystem.amber)
                view.glyphText = "\(stopAnno.index)"
                view.glyphTintColor = .white
                view.displayPriority = .required
                view.titleVisibility = .visible
                return view
            }

            // Maneuver annotation: rendered with a giant arrow glyph inside
            // a glassy disc so the upcoming turn is impossible to miss.
            // NOTE: glyphImage must be re-set on EVERY viewFor call — the
            // dequeued view's glyphImage is sticky across reuse, so without
            // setting it the user would see the old arrow after the maneuver
            // type changes mid-route.
            if let maneuver = annotation as? ManeuverAnnotation {
                let id = ManeuverAnnotation.reuseIdentifier
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.canShowCallout = false
                view.isEnabled = true
                view.centerOffset = CGPoint(x: 0, y: -8)
                view.markerTintColor = UIColor(DesignSystem.alertRed)
                view.glyphImage = UIImage(systemName: maneuver.glyph)
                    ?? UIImage(systemName: "arrow.up")
                view.glyphTintColor = .white
                view.displayPriority = .required
                return view
            }

            let identifier = "Destination"
            var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
            if view == nil {
                view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view?.canShowCallout = true
                view?.markerTintColor = UIColor(DesignSystem.cyan)
                view?.glyphImage = UIImage(systemName: "mappin")
            } else {
                view?.annotation = annotation
            }
            return view
        }

        public func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            // If the system changed tracking mode (e.g. user rotated device), log it
            DebugLogger.shared.log("Tracking mode changed to: \(mode.rawValue)")
        }
    }
}

class NavPolyline: MKPolyline {
    var statusColor: UIColor = .systemBlue
    var isRouteOverlay: Bool = false
    /// Drive from Settings. When true on iOS 17+, the renderer upgrades to
    /// MKGradientPolylineRenderer to give the polyline the colored gradient
    /// stroke Apple Maps ships by default.
    var useGradient: Bool = false
}

class GlowPolyline: MKPolyline {
    var glowColor: UIColor = .systemCyan
}

/// Lighter-weight polyline used for ALTERNATIVE routes during the
/// route-selection step (`isSelectingRoute == true`). MKDirections
/// returns routes sorted by `expectedTravelTime` ascending, so the
/// first route is always the "suggested" one — we render it with the
/// bold cyan-glow `NavPolyline` + `GlowPolyline` pair (same look as the
/// active navigation line). Every other route in the list is rendered
/// with this alternative subtype so the renderer can paint it
/// thinner and with reduced opacity.
///
/// `routeIndex` is the position in `availableRoutes` (1 for the first
/// alternative, 2 for the second, …). We don't use it for style right
/// now, but we keep it around so future iterations can stratify
/// further (e.g. draw the second-faster route slightly less opaque
/// than the slower one).
class AltRoutePolyline: MKPolyline {
    var routeIndex: Int = 1
}

/// Polyline used for route legs BEYOND the first stop on a multi-stop
/// route. Rendered as a dimmed/greyed overlay so the driver can still
/// see the remaining path (stops 2+, final destination) while the
/// currently active leg (origin → first stop) stays bold cyan.
class DimmedLegPolyline: MKPolyline {}

/// Marker annotation for the upcoming turn point. MKMarkerAnnotationView picks
/// up our SF Symbol `glyph` so the arrow type (left/right/U-turn/exit) mirrors
/// the HUD card without any duplicated drawing code.
final class ManeuverAnnotation: NSObject, MKAnnotation {
    static let reuseIdentifier = "ManeuverArrow"
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var glyph: String
    var title: String? = "Next turn"

    init(coordinate: CLLocationCoordinate2D, glyph: String) {
        self.coordinate = coordinate
        self.glyph = glyph
        super.init()
    }
}

/// Marker annotation for a Speed Camera. The view for this annotation sets
/// `clusteringIdentifier = SpeedCameraAnnotation.clusterIdentifier` so when
/// the user has 200+ cameras on screen, MapKit groups them into a single
/// numeric badge automatically — free native feature.
final class SpeedCameraAnnotation: NSObject, MKAnnotation {
    static let clusterIdentifier = "SpeedCamera"
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var camera: SpeedCamera

    init(camera: SpeedCamera) {
        self.camera = camera
        self.coordinate = CLLocationCoordinate2D(
            latitude: camera.latitude,
            longitude: camera.longitude
        )
        super.init()
    }
}

// MARK: - StopAnnotation
//
/// Marker annotation for an intermediate stop on a multi-stop route.
/// Rendered as a numbered badge so the driver sees each stop's order
/// directly on the map, matching Apple Maps' waypoint behavior.
final class StopAnnotation: NSObject, MKAnnotation {
    static let reuseIdentifier = "StopPin"
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let stopID: UUID
    let index: Int
    let title: String?
    let subtitle: String?

    init(stop: RouteStop, index: Int) {
        self.stopID = stop.id
        self.index = index
        self.coordinate = stop.coordinate
        self.title = stop.name
        self.subtitle = "Stop \(index)"
        super.init()
    }
}
