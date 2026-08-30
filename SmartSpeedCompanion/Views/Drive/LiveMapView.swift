import SwiftUI
import MapKit

public struct LiveMapView: UIViewRepresentable {
    @EnvironmentObject var viewModel: DriveViewModel

    public init() {}

    /// Keep the map north-up during recording-only drives, but rotate it into
    /// the vehicle's direction during turn-by-turn navigation so the road
    /// ahead stays vertically readable.
    internal static func trackingMode(isNavigating: Bool) -> MKUserTrackingMode {
        isNavigating ? .followWithHeading : .follow
    }

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

        // Use plain follow mode while free-driving. Active navigation uses
        // `.followWithHeading` so the route ahead stays upright on screen;
        // CameraAnimator continues to own only pitch and altitude.
        map.userTrackingMode = Self.trackingMode(isNavigating: viewModel.isNavigating)

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
            context.coordinator.cameraAnimator.suspend()
            context.coordinator.updateOverlaysIfNeeded(uiView, viewModel: viewModel)
            return
        }

        // If user has manually detached, just release any zoom restriction and stop.
        // Suspending the camera animator here (instead of letting its stale-context
        // watchdog catch up 3 s later) guarantees zero camera writes while the
        // user owns the viewport.
        if viewModel.isMapDetached {
            if uiView.userTrackingMode != .none {
                uiView.userTrackingMode = .none
            }
            context.coordinator.cameraAnimator.suspend()
            return
        }

        // Remember this transition so the tracking controller can be
        // re-engaged first and the camera can then be restored to the current
        // driving target. Merely switching tracking back on preserves the
        // user's manual zoom, which is the wide framing reported in
        // TestFlight after the 10-second auto-resume.
        let isReattachingFromManualDetach = context.coordinator.wasMapDetached

        // Re-engage native tracking if it was released. During navigation,
        // MapKit owns heading rotation so the vehicle's road stays upright;
        // CameraAnimator only changes altitude and pitch, preserving the
        // heading selected by the tracking controller. Recording-only drives
        // remain north-up to avoid compass noise rotating the map needlessly.
        let desiredTrackingMode = Self.trackingMode(isNavigating: viewModel.isNavigating)
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

        // Route preview owns the viewport until navigation begins. The
        // overview fit in rebuildOverlays must not be overwritten by the
        // speed-based driving camera while the route picker is open.
        if viewModel.isSelectingRoute {
            context.coordinator.cameraAnimator.suspend()
            context.coordinator.updateOverlaysIfNeeded(uiView, viewModel: viewModel)
            return
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
        if isReattachingFromManualDetach {
            // An active route may still need its first overlay rebuild while
            // the map is detached. Let that route-fit operation finish first,
            // then restore the close camera so the overview fit cannot win the
            // same update pass.
            if viewModel.isNavigating {
                context.coordinator.updateOverlaysIfNeeded(uiView, viewModel: viewModel)
            }

            // A re-center is a camera restore, not just a tracking-mode
            // change. Apply the same speed/turn-aware target used during
            // normal guidance so a map that was manually zoomed out returns
            // to the close navigation framing immediately.
            context.coordinator.cameraAnimator.restoreCamera(
                on: uiView,
                context: cameraCtx,
                centerCoordinate: viewModel.locationManager.latestLocation?.coordinate
            )
            context.coordinator.wasMapDetached = false

            // Preserve route-preview framing when the user re-centers before
            // starting navigation; active guidance was handled above.
            if !viewModel.isNavigating {
                context.coordinator.updateOverlaysIfNeeded(uiView, viewModel: viewModel)
            }
        } else {
            context.coordinator.cameraAnimator.update(mapView: uiView, context: cameraCtx)
            // MapKit's heading tracker can be displaced by a direct camera
            // assignment. Reassert heading-follow after the custom altitude /
            // pitch update, but only during navigation and only when the map
            // is still attached. This keeps the vehicle's current course as
            // the camera bearing instead of silently falling back to north-up.
            if viewModel.isNavigating,
               uiView.userTrackingMode != .followWithHeading {
                uiView.setUserTrackingMode(.followWithHeading, animated: false)
            }
            // Update overlays only when necessary (not every single frame)
            context.coordinator.updateOverlaysIfNeeded(uiView, viewModel: viewModel)
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: LiveMapView
        private var interactionTimer: Timer?

        /// Set when the user manually detaches (pan/pinch). Cleared on the
        /// first `updateUIView` pass after `isMapDetached` flips back to
        /// false, so we can sync the camera animator with the real camera
        /// before it resumes auto-zoom.
        var wasMapDetached: Bool = false

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

        // Overlay state tracking to avoid redundant remove/add cycles.
        // Progress is rendered in coarse distance-sized steps instead of every
        // GPS tick. Rebuilding a long MKPolyline is synchronous MapKit work;
        // the previous 25 m cadence could remove/re-add three large overlays
        // every second on an iPhone XR and starve the UIKit run loop.
        private var lastIsNavigating: Bool = false
        private var lastRenderedRouteProgress: CLLocationDistance = -1
        private let routeProgressRenderStep: CLLocationDistance = 250
        private var lastRouteDistance: Double = 0
        /// Geometry fingerprint catches a reroute that has the same distance
        /// as the previous route. Distance-only invalidation left old route
        /// lines on screen, which looked like random trailing geometry.
        private var lastRouteFingerprint: Int? = nil
        private var hasAutoFramedRoute: Bool = false
        private var lastStopFingerprint: Int = 0
        /// Forces one cleanup pass after history-trail rendering was disabled,
        /// so a map instance cannot retain trails created by an older code path.
        private var hasClearedDisabledHistoryOverlays = false

        #if DEBUG || DEVELOPER_BUILD
        private var simulatedCarAnnotation: MKPointAnnotation?
        #endif

        init(_ parent: LiveMapView) {
            self.parent = parent
        }

        deinit {
            interactionTimer?.invalidate()
        }

        @objc func handleManualInteraction(_ gesture: UIGestureRecognizer) {
            // Stop the custom display-link before MapKit processes the user's
            // pan/pinch/rotation. A camera write in the same run-loop turn as
            // a gesture update causes the fast zoom-in strobe reported by
            // TestFlight.
            if gesture.state == .began {
                cameraAnimator.suspend()
            }
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
                cameraAnimator.suspend()
                wasMapDetached = true
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
        // Progress updates replace only Speedio-owned route overlays; they do
        // not tear down camera/POI/stop annotations or unrelated MapKit layers.
        func updateOverlaysIfNeeded(_ mapView: MKMapView, viewModel: DriveViewModel) {
            let vm = viewModel
            let currentRouteDistance = vm.currentRoute?.distance ?? 0
            let currentRouteFingerprint = vm.currentRoute.map(Self.routeFingerprint(for:))
            let isNavigating = vm.isNavigating
            let currentStopFP = Self.stopFingerprint(for: vm.routeStops)
            let currentRouteProgress = isNavigating
                ? vm.currentRoute.map { renderedProgress(for: $0, viewModel: vm) }
                : nil

            let routeChanged = isNavigating != lastIsNavigating
                || abs(currentRouteDistance - lastRouteDistance) > 1.0
                || currentRouteFingerprint != lastRouteFingerprint
            let progressChanged: Bool
            if let currentRouteProgress {
                progressChanged = lastRenderedRouteProgress < 0
                    || abs(currentRouteProgress - lastRenderedRouteProgress) >= routeProgressRenderStep
            } else {
                progressChanged = lastRenderedRouteProgress >= 0
            }
            let stopsChanged = currentStopFP != lastStopFingerprint
            let routePickerDismissed = lastIsSelectingRoute && !vm.isSelectingRoute
            let routePickerOpened = !lastIsSelectingRoute && vm.isSelectingRoute
            let previewRouteCleared = !vm.isSelectingRoute
                && !vm.isNavigating
                && (!vm.availableRoutes.isEmpty || currentRouteDistance > 0)
            let alternativeFingerprint = vm.isSelectingRoute
                ? Self.altRouteFingerprint(for: vm.availableRoutes)
                : nil
            let alternativesChanged = vm.isSelectingRoute
                && alternativeFingerprint != lastAltRouteFingerprint

            let needsFullRebuild = routeChanged
                || stopsChanged
                || routePickerDismissed
                || routePickerOpened
                || alternativesChanged
                || previewRouteCleared
                || !hasClearedDisabledHistoryOverlays

            if needsFullRebuild {
                rebuildOverlays(mapView, viewModel: vm)
                hasClearedDisabledHistoryOverlays = true
                lastIsNavigating = isNavigating
                lastIsSelectingRoute = vm.isSelectingRoute
                lastRouteDistance = currentRouteDistance
                lastRouteFingerprint = currentRouteFingerprint
                lastRenderedRouteProgress = currentRouteProgress ?? -1
                lastStopFingerprint = currentStopFP
                lastAltRouteFingerprint = alternativeFingerprint
                return
            }

            // A progress refresh is intentionally narrow. The old path called
            // `rebuildOverlays`, which removed every overlay and annotation and
            // synchronously re-added the full route geometry on every 25 m
            // movement. That is the `MKMapView.addOverlay` run-loop hang seen
            // repeatedly in the XR reports.
            if progressChanged, isNavigating, vm.currentRoute != nil {
                updateActiveRouteProgressOverlay(mapView, viewModel: vm)
                lastRenderedRouteProgress = currentRouteProgress ?? -1
            }

            lastIsSelectingRoute = vm.isSelectingRoute
            if previewRouteCleared {
                lastRouteDistance = 0
                lastRouteFingerprint = nil
                lastAltRouteFingerprint = nil
            }
        }

        private func removeRenderedRouteOverlays(_ mapView: MKMapView) {
            let routeOverlays = mapView.overlays.filter {
                $0 is NavPolyline
                    || $0 is GlowPolyline
                    || $0 is AltRoutePolyline
                    || $0 is DimmedLegPolyline
            }
            guard !routeOverlays.isEmpty else { return }
            mapView.removeOverlays(routeOverlays)
        }

        private func updateActiveRouteProgressOverlay(
            _ mapView: MKMapView,
            viewModel: DriveViewModel
        ) {
            guard viewModel.isNavigating, viewModel.currentRoute != nil else { return }
            removeRenderedRouteOverlays(mapView)
            renderActiveRouteGeometry(mapView, viewModel: viewModel)
        }

        private func renderActiveRouteGeometry(_ mapView: MKMapView, viewModel: DriveViewModel) {
            guard let route = viewModel.currentRoute else { return }
            let legs = viewModel.routeLegs
            let hasLegRoutes = !viewModel.routeStops.isEmpty
                && legs.count > 1
                && legs.allSatisfy({ $0.route != nil })

            if hasLegRoutes {
                let activeIndex = min(
                    max(viewModel.navigationCoordinator.activeMultiStopLegIndexForDisplay, 0),
                    legs.count - 1
                )
                if let activeRoute = legs[activeIndex].route {
                    renderProgressRoute(mapView, route: activeRoute, viewModel: viewModel)
                }
                for (index, leg) in legs.enumerated() where index != activeIndex {
                    if let legRoute = leg.route {
                        let dimmed = DimmedLegPolyline(points: legRoute.polyline.points(), count: legRoute.polyline.pointCount)
                        mapView.addOverlay(dimmed, level: .aboveRoads)
                    }
                }
            } else {
                renderProgressRoute(mapView, route: route, viewModel: viewModel)
            }
        }

        private func rebuildOverlays(_ mapView: MKMapView, viewModel: DriveViewModel) {
            // Clear unknown legacy overlays once after an app update, then
            // remove only the route overlays owned by this coordinator. Never
            // remove unrelated MapKit overlays during a progress tick.
            if !hasClearedDisabledHistoryOverlays {
                mapView.removeOverlays(mapView.overlays)
            } else {
                removeRenderedRouteOverlays(mapView)
            }
            mapView.removeAnnotations(mapView.annotations.filter { !($0 is MKUserLocation) })
            // `removeAnnotations` also removes the maneuver annotation. Do
            // not retain a reference to an annotation that is no longer on
            // the map; the next rebuild must create it again.
            maneuverAnnotation = nil

            // Has any route work to render at all?
            let hasAvailableRoutes = viewModel.isSelectingRoute && !viewModel.availableRoutes.isEmpty
            let hasActiveRoute = viewModel.isNavigating && viewModel.currentRoute != nil

            // Route polyline + destination
            if hasActiveRoute, let route = viewModel.currentRoute {
                // Draw the active leg and any later legs without touching
                // annotations or unrelated overlays. Progress-only updates
                // use the same helper after removing just these route lines.
                renderActiveRouteGeometry(mapView, viewModel: viewModel)

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
                    // route-fit camera position so the normal driving target
                    // starts from the actual map position without a stale
                    // altitude jump on the first frame.
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
                    // Keep the preview as an overview. Do not let the normal
                    // camera animator run against this fit until navigation
                    // actually starts; otherwise its speed-based close target
                    // immediately zooms the map back into a small route slice.
                    let paddedRect = rect.insetBy(dx: -rect.size.width * 0.08, dy: -rect.size.height * 0.08)
                    mapView.setVisibleMapRect(
                        paddedRect,
                        edgePadding: UIEdgeInsets(top: 200, left: 60, bottom: 60, right: 60),
                        animated: false
                    )
                    cameraAnimator.reset(to: mapView)
                    hasAutoFramedRoute = true
                }
            } else {
                // Drop both fit latches when the route picker closes so the
                // next destination gets a fresh overview and navigation gets
                // its own driving framing.
                removeRenderedRouteOverlays(mapView)
                hasAutoFramedRoute = false
                lastRouteFingerprint = nil
                lastRenderedRouteProgress = -1
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

            // The HUD already provides the active maneuver. Do not render a
            // second passive "Next turn" pin on the route; it remains visible
            // while the card changes and is easy to mistake for a pending
            // action. Keep the annotation code disabled and remove any pin
            // left by an older map state.
            if let existing = maneuverAnnotation {
                mapView.removeAnnotation(existing)
                maneuverAnnotation = nil
            }
            /*
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
            }
            }
            */

            // Historical GPS trails are intentionally not rendered. The
            // active route itself provides the only path overlay: its
            // travelled portion is greyed and its remaining portion is blue.
        }

        /// Renders the active route as two slices of the original MKRoute
        /// geometry: a muted travelled-behind segment and a cyan remaining
        /// segment. The split is based on route progress, never a line drawn
        /// between raw GPS fixes.
        private func renderProgressRoute(_ mapView: MKMapView, route: MKRoute, viewModel: DriveViewModel) {
            let routeProgress = renderedProgress(for: route, viewModel: viewModel)
            let geometryLength = polylineLength(route.polyline)
            let geometryProgress = route.distance > 0
                ? routeProgress / route.distance * geometryLength
                : 0
            let segments = splitRoutePolyline(route.polyline, progressDistance: geometryProgress)

            if let travelled = segments.travelled, travelled.pointCount > 1 {
                let line = NavPolyline(points: travelled.points(), count: travelled.pointCount)
                line.statusColor = UIColor(white: 0.42, alpha: 0.72)
                line.isRouteOverlay = false
                mapView.addOverlay(line, level: .aboveRoads)
            }

            if let remaining = segments.remaining, remaining.pointCount > 1 {
                let glow = GlowPolyline(points: remaining.points(), count: remaining.pointCount)
                glow.glowColor = UIColor(DesignSystem.cyan)
                mapView.addOverlay(glow, level: .aboveRoads)

                let line = NavPolyline(points: remaining.points(), count: remaining.pointCount)
                line.statusColor = UIColor(DesignSystem.cyan)
                line.isRouteOverlay = true
                line.useGradient = viewModel.gradientRouteEnabled
                mapView.addOverlay(line, level: .aboveRoads)
            }
        }

        /// Returns the travelled distance on the active leg. `distanceToDestination`
        /// includes later multi-stop legs, so subtract those legs before using
        /// it to split the active leg's geometry.
        private func renderedProgress(for route: MKRoute, viewModel: DriveViewModel) -> CLLocationDistance {
            let laterLegDistance: CLLocationDistance
            let coordinator = viewModel.navigationCoordinator
            if coordinator.routeStops.isEmpty {
                laterLegDistance = 0
            } else {
                let activeIndex = coordinator.activeMultiStopLegIndexForDisplay
                laterLegDistance = coordinator.routeLegs.dropFirst(activeIndex + 1)
                    .reduce(0) { $0 + $1.distance }
            }

            if viewModel.distanceToDestination > 0 {
                let activeRemaining = min(
                    route.distance,
                    max(0, viewModel.distanceToDestination - laterLegDistance)
                )
                return max(0, route.distance - activeRemaining)
            }

            // Before the first navigation tick publishes a remaining distance,
            // keep the whole route visible. The first location fix will cause
            // the coordinator's canonical value to be used on the next pass.
            return 0
        }

        private func polylineLength(_ polyline: MKPolyline) -> CLLocationDistance {
            guard polyline.pointCount > 1 else { return 0 }
            let points = polyline.points()
            var length: CLLocationDistance = 0
            for index in 0..<(polyline.pointCount - 1) {
                let first = CLLocation(latitude: points[index].coordinate.latitude, longitude: points[index].coordinate.longitude)
                let second = CLLocation(latitude: points[index + 1].coordinate.latitude, longitude: points[index + 1].coordinate.longitude)
                length += first.distance(from: second)
            }
            return length
        }

        /// Splits the route's own vertices and inserts one boundary point. It
        /// never uses the live GPS coordinate as a vertex, so a bad location
        /// fix cannot create a line back to the route origin.
        private func splitRoutePolyline(
            _ polyline: MKPolyline,
            progressDistance: CLLocationDistance
        ) -> (travelled: MKPolyline?, remaining: MKPolyline?) {
            let count = polyline.pointCount
            guard count > 1 else { return (nil, nil) }
            let source = polyline.points()
            let coordinates = (0..<count).map { source[$0].coordinate }
            var segmentLengths: [CLLocationDistance] = []
            segmentLengths.reserveCapacity(count - 1)
            var totalLength: CLLocationDistance = 0
            for index in 0..<(count - 1) {
                let first = CLLocation(latitude: coordinates[index].latitude, longitude: coordinates[index].longitude)
                let second = CLLocation(latitude: coordinates[index + 1].latitude, longitude: coordinates[index + 1].longitude)
                let length = first.distance(from: second)
                segmentLengths.append(length)
                totalLength += length
            }

            let target = min(max(0, progressDistance), totalLength)
            guard target > 0 else { return (nil, MKPolyline(coordinates: coordinates, count: count)) }
            guard target < totalLength else { return (MKPolyline(coordinates: coordinates, count: count), nil) }

            var cumulative: CLLocationDistance = 0
            var splitIndex = 0
            var splitFraction: Double = 0
            for (index, length) in segmentLengths.enumerated() {
                if target <= cumulative + length {
                    splitIndex = index
                    splitFraction = length > 0
                        ? min(1, max(0, (target - cumulative) / length))
                        : 0
                    break
                }
                cumulative += length
            }

            let firstPoint = MKMapPoint(coordinates[splitIndex])
            let secondPoint = MKMapPoint(coordinates[splitIndex + 1])
            let splitPoint = MKMapPoint(
                x: firstPoint.x + (secondPoint.x - firstPoint.x) * splitFraction,
                y: firstPoint.y + (secondPoint.y - firstPoint.y) * splitFraction
            ).coordinate
            var travelled = Array(coordinates.prefix(splitIndex + 1))
            var remaining = Array(coordinates.suffix(from: splitIndex + 1))
            if let last = travelled.last,
               abs(last.latitude - splitPoint.latitude) > 0.0000001
                    || abs(last.longitude - splitPoint.longitude) > 0.0000001 {
                travelled.append(splitPoint)
            }
            if let first = remaining.first,
               abs(first.latitude - splitPoint.latitude) > 0.0000001
                    || abs(first.longitude - splitPoint.longitude) > 0.0000001 {
                remaining.insert(splitPoint, at: 0)
            }

            let travelledLine = travelled.count > 1 ? MKPolyline(coordinates: travelled, count: travelled.count) : nil
            let remainingLine = remaining.count > 1 ? MKPolyline(coordinates: remaining, count: remaining.count) : nil
            return (travelledLine, remainingLine)
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

        // MARK: - MKMapViewDelegate

        public func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? NavPolyline {
                // GRADIENT ROUTE: only the ROUTE polyline upgrades to
                // MKGradientPolylineRenderer. The travelled-behind segment
                // uses the flat renderer below so its muted grey remains
                // visually distinct from the active route gradient.
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

        /// Converts a native MapKit POI tap into the same destination flow as
        /// text search. `MKMapFeatureAnnotation` is the annotation type used
        /// by Apple's rendered map for restaurants, stores, roads, and other
        /// places; it must be resolved with `MKMapItemRequest` before routing.
        public func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let feature = view.annotation as? MKMapFeatureAnnotation else { return }

            // Remove the native callout before presenting our route picker so
            // the tap has one clear result instead of leaving a POI card
            // underneath the app's route-selection card.
            mapView.deselectAnnotation(feature, animated: true)
            let request = MKMapItemRequest(mapFeatureAnnotation: feature)
            request.getMapItem { [weak self] mapItem, error in
                guard let self else { return }
                guard let mapItem else {
                    if let error {
                        DebugLogger.shared.log("Map POI selection failed: \(error.localizedDescription)")
                    }
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.parent.viewModel.selectDestinationAndCalculateRoutes(to: mapItem)
                }
            }
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
