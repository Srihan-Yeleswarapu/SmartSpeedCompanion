// CarPlaySceneDelegate.swift
// CarPlay is the PRIMARY interface for Speed Sense.
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
    
    // MARK: - Primary Scene Connection
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        
        // Pass shared ViewModel to CarPlay
        let vm = AppDelegate.sharedDriveViewModel
        
        // Configure Primary Root Layout
        navigationRoot = CarPlayNavigationRootTemplate(interfaceController: interfaceController, viewModel: vm)
        
        guard let speedMapTemplate = navigationRoot?.mapTemplate else { return }
        
        // Establish as primary
        interfaceController.setRootTemplate(speedMapTemplate, animated: true, completion: nil)
    }
    
    // MARK: - Window-Aware Connection (Modern CarPlay)
    // Called on newer CarPlay systems that provide a CPWindow for direct view embedding
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        self.interfaceController = interfaceController
        
        let vm = AppDelegate.sharedDriveViewModel
        
        // Configure a dedicated MKMapView for the CarPlay window
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
        
        // Clean POI filter for driving
        mapView.pointOfInterestFilter = MKPointOfInterestFilter(including: [
            .gasStation, .parking, .hospital, .police
        ])
        
        self.carPlayMapView = mapView
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(mapView)
        
        // Configure Primary Root Layout
        navigationRoot = CarPlayNavigationRootTemplate(interfaceController: interfaceController, viewModel: vm)
        
        guard let speedMapTemplate = navigationRoot?.mapTemplate else { return }
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
    
    // MARK: - Disconnection
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        // Handle Disconnect logic (e.g., stop nav, pausing recorders)
        let vm = AppDelegate.sharedDriveViewModel
        if vm.isRecording {
            vm.endSession()
        }
        if vm.isNavigating {
            Task {
                await vm.endNavigation()
            }
        }
        
        self.carPlayMapView = nil
        self.interfaceController = nil
        self.navigationRoot = nil
    }
    
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        // Clean up the window-based connection
        self.carPlayMapView?.removeFromSuperview()
        self.carPlayMapView = nil
        self.interfaceController = nil
        self.navigationRoot = nil
    }

    // MARK: - User Actions
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didSelect maneuver: CPManeuver) {
        navigationRoot?.showTurnByTurnList()
    }
}

