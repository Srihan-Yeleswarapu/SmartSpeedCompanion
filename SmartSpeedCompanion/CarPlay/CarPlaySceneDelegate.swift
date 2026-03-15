// CarPlaySceneDelegate.swift
// CarPlay is the PRIMARY interface for Speed Sense.
// The entire driving experience lives here.

import CarPlay
import UIKit
import Combine

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPTemplateApplicationDashboardSceneDelegate {
    var interfaceController: CPInterfaceController?
    var dashboardController: CPDashboardController?
    var navigationRoot: CarPlayNavigationRootTemplate?
    private var dashboardManager: CarPlayDashboardController?
    private var cancellables = Set<AnyCancellable>()
    
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
    
    // DASHBOARD Support
    func templateApplicationDashboardScene(
        _ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
        didConnect dashboardController: CPDashboardController,
        to window: CPWindow
    ) {
        self.dashboardController = dashboardController
        let vm = AppDelegate.sharedDriveViewModel
        self.dashboardManager = CarPlayDashboardController(dashboardController: dashboardController, viewModel: vm)
    }
    
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
        
        self.interfaceController = nil
        self.navigationRoot = nil
    }

    // Responding to User Actions (Guidance Taps)
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didSelect maneuver: CPManeuver) {
        navigationRoot?.showTurnByTurnList()
    }
}
