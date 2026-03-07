// CarPlaySceneDelegate.swift
// CarPlay is the PRIMARY interface for Smart Speed Companion.
// The entire driving experience lives here.

import CarPlay
import UIKit
import Combine

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?
    var navigationRoot: CarPlayNavigationRootTemplate?
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
}
