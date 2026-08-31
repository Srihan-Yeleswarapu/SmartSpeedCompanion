// CarPlayMapController.swift
//
// The CPMapTemplate supplies CarPlay's navigation chrome, but the map surface
// itself is the MKMapView installed in the CPWindow. Keep the route geometry on
// that map so the blue guidance line is visible on the head unit as well as on
// the iPhone map.

import CarPlay
import Combine
import MapKit
import UIKit

@MainActor
final class CarPlayMapController: NSObject, MKMapViewDelegate {
    private let mapView: MKMapView
    private let viewModel: DriveViewModel
    private var cancellables = Set<AnyCancellable>()
    private let cameraAnimator = CameraAnimator()
    private var hasReceivedLocationFix = false
    private var scheduledRender = false
    private var lastRenderFingerprint: Int?
    private var lastNavigationCameraFingerprint: Int?
    private var hasInitializedNavigationCamera = false

    init(mapView: MKMapView, viewModel: DriveViewModel) {
        self.mapView = mapView
        self.viewModel = viewModel
        super.init()

        mapView.delegate = self

        // DriveViewModel forwards NavigationCoordinator changes through its
        // objectWillChange publisher. Schedule the render on the next main-queue
        // turn because @Published emits before the new value is assigned.
        viewModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleRender()
            }
            .store(in: &cancellables)

        // DriveViewModel publishes navigation state, but the location manager
        // owns the GPS publisher. Subscribe to both so the CarPlay camera keeps
        // following the vehicle even when the route geometry itself has not
        // changed.
        viewModel.locationManager.$latestLocation
            .receive(on: RunLoop.main)
            .sink { [weak self] location in
                guard let self else { return }
                if location != nil {
                    self.hasReceivedLocationFix = true
                }
                self.scheduleRender()
            }
            .store(in: &cancellables)

        renderIfNeeded()
    }

    /// Stop observing before the CarPlay window is released. This also prevents
    /// a late navigation update from touching an MKMapView that is no longer
    /// attached to the head-unit window.
    func stop() {
        cancellables.removeAll()
        mapView.delegate = nil
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations.filter { !($0 is MKUserLocation) })
    }

    private func scheduleRender() {
        guard !scheduledRender else { return }
        scheduledRender = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduledRender = false
            self.renderIfNeeded()
        }
    }

    private func renderIfNeeded() {
        let fingerprint = renderFingerprint()
        let navigationCameraFingerprint = activeNavigationCameraFingerprint()
        if navigationCameraFingerprint != lastNavigationCameraFingerprint {
            lastNavigationCameraFingerprint = navigationCameraFingerprint
            hasInitializedNavigationCamera = false
        }

        if fingerprint != lastRenderFingerprint {
            lastRenderFingerprint = fingerprint
            mapView.removeOverlays(mapView.overlays)
            mapView.removeAnnotations(mapView.annotations.filter { !($0 is MKUserLocation) })

            if viewModel.isNavigating, let route = viewModel.navigationCoordinator.currentRoute {
                renderActiveRoute(route)
                addDestinationAnnotation(for: viewModel.destination)
                // Do not fit the entire route during active guidance. That
                // produces the broad city-wide framing visible in the
                // TestFlight screenshot and leaves the custom MKMapView in an
                // overview camera indefinitely. The navigation camera below
                // owns the close, vehicle-centered framing instead.
            } else if viewModel.isSelectingRoute, !viewModel.availableRoutes.isEmpty {
                // Route previews should still show the complete alternatives so
                // the driver can compare them before starting navigation.
                renderPreviewRoutes(viewModel.availableRoutes)
                addDestinationAnnotation(for: viewModel.destination)
                frameMapIfNeeded(for: viewModel.availableRoutes)
            }
        }

        if viewModel.isNavigating, viewModel.navigationCoordinator.currentRoute != nil {
            updateNavigationCamera()
        } else {
            hasInitializedNavigationCamera = false
        }
    }

    private func renderActiveRoute(_ route: MKRoute) {
        addRouteOverlay(for: route, style: .active)

        // Multi-stop navigation keeps the active leg in currentRoute while
        // retaining later legs in routeLegs. Draw those legs dimmed so the
        // driver can see the complete journey without confusing them with the
        // leg currently receiving turn-by-turn guidance.
        let activeIndex = viewModel.navigationCoordinator.activeMultiStopLegIndexForDisplay
        for (index, leg) in viewModel.routeLegs.enumerated() where index != activeIndex {
            guard let laterRoute = leg.route else { continue }
            addRouteOverlay(for: laterRoute, style: .dimmed)
        }
    }

    private func renderPreviewRoutes(_ routes: [MKRoute]) {
        for (index, route) in routes.enumerated() {
            addRouteOverlay(for: route, style: index == 0 ? .active : .alternate)
        }
    }

    private func addRouteOverlay(for route: MKRoute, style: RouteOverlayStyle) {
        guard route.polyline.pointCount > 1 else { return }
        let points = route.polyline.points()

        switch style {
        case .active:
            let glow = CarPlayRouteGlowPolyline(points: points, count: route.polyline.pointCount)
            mapView.addOverlay(glow, level: .aboveRoads)

            let line = CarPlayRoutePolyline(points: points, count: route.polyline.pointCount)
            mapView.addOverlay(line, level: .aboveRoads)
        case .alternate:
            let line = CarPlayAlternateRoutePolyline(points: points, count: route.polyline.pointCount)
            mapView.addOverlay(line, level: .aboveRoads)
        case .dimmed:
            let line = CarPlayDimmedRoutePolyline(points: points, count: route.polyline.pointCount)
            mapView.addOverlay(line, level: .aboveRoads)
        }
    }

    private func addDestinationAnnotation(for destination: MKMapItem?) {
        guard let destination else { return }
        let annotation = MKPointAnnotation()
        annotation.coordinate = destination.placemark.coordinate
        annotation.title = destination.name
        mapView.addAnnotation(annotation)
    }

    private func frameMapIfNeeded(for routes: [MKRoute]) {
        var rect = MKMapRect.null
        for route in routes {
            rect = rect.union(route.polyline.boundingMapRect)
        }

        if let location = viewModel.locationManager.latestLocation {
            let point = MKMapPoint(location.coordinate)
            let userRect = MKMapRect(
                x: point.x - 1_000,
                y: point.y - 1_000,
                width: 2_000,
                height: 2_000
            )
            rect = rect.union(userRect)
        }

        guard !rect.isNull else { return }
        mapView.setVisibleMapRect(
            rect,
            edgePadding: UIEdgeInsets(top: 100, left: 60, bottom: 150, right: 60),
            animated: false
        )
    }

    /// Returns a stable key for the active route/destination. Speed, turn
    /// distance, and location are intentionally excluded so a progressing
    /// vehicle updates the camera without repeatedly resetting its animation.
    private func activeNavigationCameraFingerprint() -> Int? {
        guard viewModel.isNavigating,
              let route = viewModel.navigationCoordinator.currentRoute else { return nil }

        var hasher = Hasher()
        hasher.combine(Self.routeFingerprint(for: route))
        hasher.combine(Self.destinationFingerprint(for: viewModel.destination))
        return hasher.finalize()
    }

    /// Maintains the same turn-aware camera policy used by the iPhone map,
    /// but applies it to the dedicated CarPlay MKMapView. The route renderer
    /// must not call `setVisibleMapRect` for active guidance: that operation
    /// fits the entire trip and overrides the close vehicle-following camera.
    private func updateNavigationCamera() {
        guard viewModel.isNavigating,
              viewModel.navigationCoordinator.currentRoute != nil else { return }

        let context = navigationCameraContext()
        if !hasInitializedNavigationCamera {
            // If CarPlay connects before Core Location has delivered a fix,
            // keep the system's follow camera temporarily. Applying a camera
            // centered on MapKit's default coordinate (or a stale old fix)
            // would create a second framing bug during handoff. Initialize the
            // close camera on the first real location update instead.
            guard hasReceivedLocationFix,
                  viewModel.locationManager.latestLocation != nil else { return }

            // CarPlay orientates the map to the vehicle's GPS course so the
            // road ahead points up. We use `.follow` (MapKit centers on the
            // vehicle) and drive `camera.heading` ourselves — head units do not
            // provide a reliable compass heading, and `.followWithHeading` can
            // pin the map at a sideways heading in the car.
            mapView.userTrackingMode = .follow

            let target = CameraDecisionEngine.computeTarget(from: context)
            let camera = mapView.camera.copy() as! MKMapCamera
            if let location = viewModel.locationManager.latestLocation {
                camera.centerCoordinate = location.coordinate
            }
            camera.heading = currentCourseDegrees
            camera.centerCoordinateDistance = target.altitude
            camera.pitch = CGFloat(target.pitch)
            mapView.camera = camera

            // Start the EMA from the close camera we just installed instead of
            // from CarPlay's stale/default overview altitude.
            cameraAnimator.reset(to: mapView)
            hasInitializedNavigationCamera = true
        }

        cameraAnimator.update(mapView: mapView, context: context, course: currentCourseDegrees)
    }

    /// Vehicle direction of travel (degrees, 0 = north). CarPlay head units do
    /// not expose a trustworthy compass heading, so orientation comes from the
    /// GPS course of travel. Falls back to the published heading, then to north.
    private var currentCourseDegrees: Double {
        if let location = viewModel.locationManager.latestLocation, location.course >= 0 {
            return location.course
        }
        return viewModel.currentHeading ?? 0
    }

    private func navigationCameraContext() -> CameraContext {
        let measurementSystem = SpeedFormatting.measurementSystem()
        let cameraSpeedMph = SpeedFormatting.isMetric(measurementSystem)
            ? viewModel.speed * 0.621371
            : viewModel.speed

        return CameraContext(
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
    }

    private func renderFingerprint() -> Int {
        var hasher = Hasher()
        hasher.combine(viewModel.isNavigating)
        hasher.combine(viewModel.isSelectingRoute)

        if viewModel.isNavigating, let route = viewModel.navigationCoordinator.currentRoute {
            hasher.combine(Self.routeFingerprint(for: route))
            hasher.combine(Self.destinationFingerprint(for: viewModel.destination))
            hasher.combine(viewModel.routeStops.count)
            for leg in viewModel.routeLegs {
                hasher.combine(leg.route.map(Self.routeFingerprint(for:)))
            }
        } else if viewModel.isSelectingRoute {
            hasher.combine(viewModel.availableRoutes.count)
            for route in viewModel.availableRoutes {
                hasher.combine(Self.routeFingerprint(for: route))
            }
            hasher.combine(Self.destinationFingerprint(for: viewModel.destination))
        }

        return hasher.finalize()
    }

    private static func routeFingerprint(for route: MKRoute) -> Int {
        var hasher = Hasher()
        hasher.combine(route.polyline.pointCount)
        hasher.combine(Int(route.distance))
        hasher.combine(Int(route.expectedTravelTime))

        let count = route.polyline.pointCount
        guard count > 0 else { return hasher.finalize() }
        let points = route.polyline.points()
        let sampleCount = min(9, count)
        for sample in 0..<sampleCount {
            let index = sampleCount == 1 ? 0 : (sample * (count - 1)) / (sampleCount - 1)
            let coordinate = points[index].coordinate
            hasher.combine(Int(coordinate.latitude * 100_000))
            hasher.combine(Int(coordinate.longitude * 100_000))
        }
        return hasher.finalize()
    }

    private static func destinationFingerprint(for destination: MKMapItem?) -> Int {
        guard let destination else { return 0 }
        let coordinate = destination.placemark.coordinate
        var hasher = Hasher()
        hasher.combine(Int(coordinate.latitude * 100_000))
        hasher.combine(Int(coordinate.longitude * 100_000))
        hasher.combine(destination.name)
        return hasher.finalize()
    }

    // MARK: - MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        switch overlay {
        case let glow as CarPlayRouteGlowPolyline:
            let renderer = MKPolylineRenderer(polyline: glow)
            renderer.strokeColor = CarPlayUI.blue.withAlphaComponent(0.28)
            renderer.lineWidth = 18
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        case let route as CarPlayRoutePolyline:
            let renderer = MKPolylineRenderer(polyline: route)
            renderer.strokeColor = CarPlayUI.blue.withAlphaComponent(0.95)
            renderer.lineWidth = 8
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        case let alternate as CarPlayAlternateRoutePolyline:
            let renderer = MKPolylineRenderer(polyline: alternate)
            renderer.strokeColor = UIColor.white.withAlphaComponent(0.58)
            renderer.lineWidth = 4
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        case let dimmed as CarPlayDimmedRoutePolyline:
            let renderer = MKPolylineRenderer(polyline: dimmed)
            renderer.strokeColor = UIColor.white.withAlphaComponent(0.35)
            renderer.lineWidth = 5
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        default:
            return MKOverlayRenderer(overlay: overlay)
        }
    }

    private enum RouteOverlayStyle {
        case active
        case alternate
        case dimmed
    }
}

private final class CarPlayRoutePolyline: MKPolyline {}
private final class CarPlayRouteGlowPolyline: MKPolyline {}
private final class CarPlayAlternateRoutePolyline: MKPolyline {}
private final class CarPlayDimmedRoutePolyline: MKPolyline {}
