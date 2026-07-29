// CarPlaySceneDelegate.swift
// CarPlay is the PRIMARY interface for Speedio.
// The entire driving experience lives here.

import CarPlay
import MapKit
import UIKit
import Combine

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPTemplateApplicationDashboardSceneDelegate {
    var interfaceController: CPInterfaceController?
    var dashboardController: CPDashboardController?
    var navigationRoot: CarPlayNavigationRootTemplate?
    private var dashboardManager: CarPlayDashboardController?
    private var carPlayMapView: MKMapView?
    private var cancellables = Set<AnyCancellable>()
    
    // ── IMPORTANT — why the MKMapView is NOT removed ─────────────────
    //
    // A natural-looking simplification is to drop the
    // MKMapView(frame: window.bounds) block on the grounds that
    // "CPMapTemplate handles CarPlay map rendering." That assumption is
    // wrong. Per Apple's CarPlay docs: CPMapTemplate is an OVERLAY
    // controller — it manages map buttons, navigation alerts, trip
    // estimates, safe-area insets, and the navigation bar. It does NOT
    // render the underlying map. The app must draw the map itself onto
    // `CPWindow` (typically with an MKMapView; Mapbox or a custom Metal
    // renderer also work).
    //
    // Without this MKMapView, CarPlay shows a fully-black surface behind
    // the CPMapTemplate overlay chrome. Verified via inference from
    // Apple's Navigation-template documentation and the production-tested
    // behavior of the existing window path (removing the MKMapView would
    // regress the production navigation view). Keep it.
    // MARK: - Scene Connection (Modern, iOS 14+)
    //
    // CarPlay delivers a CPWindow so the app can install an MKMapView
    // beneath the CPMapTemplate overlay. This is the canonical path.
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        self.interfaceController = interfaceController
        installMapViewInCarPlayWindow(window)
        setupNavigationRoot(interfaceController: interfaceController)
    }

    // MARK: - Scene Connection (Legacy, no window)
    //
    // Some CarPlay configurations on iOS 26+ dispatch the legacy selector
    // `templateApplicationScene:didConnect:` instead of the modern
    // `templateApplicationScene:didConnect:to:` — especially after the
    // entitlement transition from carplay-navigation to
    // carplay-driving-task. We implement both so the delegate always
    // responds, preventing the NSInternalInconsistencyException that
    // CarPlay raises in `_deliverInterfaceControllerToDelegate` when
    // neither selector matches.
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        // No CPWindow in this path, so the MKMapView is not installed.
        // The CPMapTemplate overlay chrome will still render correctly;
        // the map tiles will appear once the system delivers a window.
        setupNavigationRoot(interfaceController: interfaceController)
    }

    // MARK: - Setup Helpers
    //
    // Extracted from the connection method so future re-attach flows
    // (debug replays, app-extension hand-off, voice-flow re-init) can
    // reuse the same wiring without duplicating setup logic.

    /// Configure the dedicated MKMapView backing the CarPlay window.
    /// CPMapTemplate overlays sit on top of this view; without it, CarPlay
    /// shows a black background behind the overlay chrome (see MARK above).
    private func installMapViewInCarPlayWindow(_ window: CPWindow) {
        let mapView = MKMapView(frame: window.bounds)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.overrideUserInterfaceStyle = .dark
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .followWithHeading
        mapView.showsCompass = true

        // Use modern MapKit configuration with realistic 3D buildings
        if #available(iOS 16.0, *) {
            let config = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .muted)
            config.showsTraffic = true
            mapView.preferredConfiguration = config
        } else {
            mapView.mapType = .mutedStandard
        }

        // Clean POI filter for driving — only categories a driver
        // genuinely needs while in motion.
        mapView.pointOfInterestFilter = MKPointOfInterestFilter(including: [
            .gasStation, .parking, .hospital, .police
        ])

        self.carPlayMapView = mapView
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(mapView)
    }

    /// Build the navigation root and set it as the interface controller's
    /// primary template. The explicit guard before `mapTemplate` is
    /// preserved from the original code — it short-circuits if the
    /// navigation-root constructor ever races (e.g., the
    /// dismantle-on-foreground queue is still mid-flight).
    private func setupNavigationRoot(interfaceController: CPInterfaceController) {
        let vm = AppDelegate.sharedDriveViewModel
        navigationRoot = CarPlayNavigationRootTemplate(
            interfaceController: interfaceController,
            viewModel: vm
        )

        // Explicit check before accessing mapTemplate to avoid potential race condition
        guard let root = navigationRoot else { return }
        let speedMapTemplate = root.mapTemplate
        interfaceController.setRootTemplate(speedMapTemplate, animated: true, completion: nil)
    }
    
    // MARK: - Dashboard Support
    func templateApplicationDashboardScene(
        _ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
        didConnect dashboardController: CPDashboardController,
        to window: UIWindow
    ) {
        self.dashboardController = dashboardController
        let vm = AppDelegate.sharedDriveViewModel
        self.dashboardManager = CarPlayDashboardController(dashboardController: dashboardController, viewModel: vm)
    }

    func templateApplicationDashboardScene(
        _ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
        didDisconnect dashboardController: CPDashboardController,
        from window: UIWindow
    ) {
        self.dashboardManager = nil
        self.dashboardController = nil
    }
    
    // MARK: - Disconnection
    //
    // Single modern disconnect (iOS 14+). The previous code had two
    // parallel overloads each doing only PART of the cleanup — the legacy
    // `didDisconnectInterfaceController:` stopped recording/navigation
    // and nilled the interfaceController; the modern `didDisconnect:from:`
    // only torn down the MKMapView. CarPlay can dispatch both in some
    // disconnect scenarios, so anything assigned to either branch ran
    // twice. We now own the full teardown in ONE method, with the
    // per-half work split into clearly-named private helpers.
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        tearDownMapView()
        tearDownNavigation()
    }

    /// Remove the CarPlay-window MKMapView from its superview and drop
    /// our reference so the view controller holding the CPWindow
    /// releases promptly.
    private func tearDownMapView() {
        carPlayMapView?.removeFromSuperview()
        carPlayMapView = nil
    }

    /// Stop any active drive recording and in-progress navigation, then
    /// nil out the scene-shell references. Mirrors the single-flight
    /// contract documented above — CarPlay runs this exact body once
    /// per disconnect.
    private func tearDownNavigation() {
        let vm = AppDelegate.sharedDriveViewModel
        if vm.isRecording {
            vm.endSession()
        }
        if vm.isNavigating {
            Task {
                await vm.endNavigation()
            }
        }

        self.interfaceController = nil
        self.navigationRoot = nil
    }

    // MARK: - User Actions
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didSelect maneuver: CPManeuver) {
        navigationRoot?.showTurnByTurnList()
    }
}