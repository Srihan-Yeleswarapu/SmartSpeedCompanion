import CarPlay
import UIKit
import Combine

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?
    var drivingTemplate: CarPlaySpeedTemplate?
    private var cancellables = Set<AnyCancellable>()
    
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        
        // Pass shared ViewModel to CarPlay
        let vm = AppDelegate.sharedDriveViewModel
        drivingTemplate = CarPlaySpeedTemplate(viewModel: vm)
        
        // Root Template
        guard let speedTemplate = drivingTemplate?.mapTemplate else { return }
        interfaceController.setRootTemplate(speedTemplate, animated: true)
        
        // Observe Alert State
        vm.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                if status == .over && vm.alertActive {
                    self?.presentOverspeedAlert()
                }
            }
            .store(in: &cancellables)
    }
    
    private func presentOverspeedAlert() {
        guard interfaceController?.presentedTemplate == nil else { return }
        
        let action = CPAlertAction(title: "I'm Aware", style: .default) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true)
        }
        
        let alert = CPAlertTemplate(
            titleVariants: ["Speed Limit Exceeded"],
            actions: [action]
        )
        interfaceController?.presentTemplate(alert, animated: true)
    }
    
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
        self.drivingTemplate = nil
    }
}
