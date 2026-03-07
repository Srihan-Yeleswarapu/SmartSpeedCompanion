// Path: CarPlay/CarPlaySpeedTemplate.swift
import CarPlay
import MapKit
import Combine

class CarPlaySpeedTemplate {
    let mapTemplate: CPMapTemplate
    weak var interfaceController: CPInterfaceController?
    private let viewModel: DriveViewModel
    private var cancellables = Set<AnyCancellable>()
    private var speedBarButton: CPBarButton!
    private var isAlertPresented = false
    
    init(viewModel: DriveViewModel) {
        self.viewModel = viewModel
        self.mapTemplate = CPMapTemplate()
        setupTemplate()
        bindViewModel()
    }
    
    private func setupTemplate() {
        mapTemplate.showsCompass = true
        mapTemplate.showsSpeedLimit = true
        // Fix for CPTravelEstimates crash: Suppress the estimates panel entirely
        mapTemplate.tripEstimateStyle = .overview
        
        // Custom CPBarButton in the navigation bar
        speedBarButton = CPBarButton(title: "Speed: -- mph") { _ in }
        mapTemplate.leadingNavigationBarButtons = [speedBarButton]
        
        let startButton = CPMapButton { [weak self] _ in self?.viewModel.startSession() }
        startButton.image = UIImage(systemName: "play.fill")
        
        let endButton = CPMapButton { [weak self] _ in self?.viewModel.endSession() }
        endButton.image = UIImage(systemName: "stop.fill")
        
        mapTemplate.mapButtons = [startButton, endButton]
    }
    
    private func bindViewModel() {
        viewModel.$speed.combineLatest(viewModel.$limit, viewModel.$status)
            .receive(on: RunLoop.main)
            .sink { [weak self] speed, limit, status in
                self?.updateDisplay(speed: speed, limit: limit, status: status)
            }
            .store(in: &cancellables)
    }
    
    private func updateDisplay(speed: Double, limit: Int, status: SpeedStatus) {
        let formattedSpeed = Int(speed)
        speedBarButton.title = "Speed: \(formattedSpeed) mph / Limit: \(limit) mph"
        
        // Guidance background color
        if status == .over {
            mapTemplate.guidanceBackgroundColor = UIColor(red: 1.0, green: 0.24, blue: 0.44, alpha: 1.0)
        } else if status == .warning {
            mapTemplate.guidanceBackgroundColor = UIColor(red: 1.0, green: 0.72, blue: 0.0, alpha: 1.0)
        } else {
            mapTemplate.guidanceBackgroundColor = UIColor(red: 0.0, green: 1.0, blue: 0.62, alpha: 1.0)
        }
        
        handleAlerts(speed: speed, limit: limit, status: status)
    }
    
    private func handleAlerts(speed: Double, limit: Int, status: SpeedStatus) {
        if status == .over {
            if !isAlertPresented {
                presentAlert(speed: speed, limit: limit)
            }
        } else {
            if isAlertPresented {
                dismissAlert()
            }
        }
    }
    
    @MainActor
    private func presentAlert(speed: Double, limit: Int) {
        guard let interfaceController = interfaceController else { return }
        
        let overAmount = Int(speed - Double(limit + viewModel.speedEngine.userBuffer))
        let message = "You are \(overAmount) mph over the limit"
        
        let action = CPAlertAction(title: "Acknowledged", style: .cancel) { [weak self] _ in
            self?.dismissAlert()
        }
        
        let alert = CPAlertTemplate(titleVariants: ["⚠ SPEED ALERT"], actions: [action])
        
        // The CPAlertTemplate subtitle is technically not supported without internal APIs, so we use titleVariants or a text string
        let textAlert = CPAlertTemplate(titleVariants: ["⚠ SPEED ALERT\n\(message)"], actions: [action])
        
        interfaceController.presentTemplate(textAlert, animated: true)
        isAlertPresented = true
    }
    
    private func dismissAlert() {
        guard isAlertPresented, let interfaceController = interfaceController else { return }
        interfaceController.dismissTemplate(animated: true)
        isAlertPresented = false
    }
}
