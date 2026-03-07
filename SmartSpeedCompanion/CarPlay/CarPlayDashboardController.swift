import CarPlay
import UIKit
import Combine

class CarPlayDashboardController: NSObject, CPDashboardControllerDelegate {
    private var dashboardController: CPDashboardController?
    private let viewModel = AppDelegate.sharedDriveViewModel
    private var cancellables = Set<AnyCancellable>()
    
    // A dashboard shortcut button
    private lazy var speedShortcut: CPDashboardButton = {
        let btn = CPDashboardButton(titleVariants: ["Speed"], subtitleVariants: ["---"], image: UIImage(systemName: "speedometer")) { [weak self] _ in
            // Action when tapped in the dashboard
            self?.viewModel.startSession()
        }
        return btn
    }()
    
    init(dashboardController: CPDashboardController) {
        self.dashboardController = dashboardController
        super.init()
        self.dashboardController?.delegate = self
        setupDashboard()
        bindViewModel()
    }
    
    private func setupDashboard() {
        dashboardController?.shortcutButtons = [speedShortcut]
    }
    
    private func bindViewModel() {
        viewModel.$speed.combineLatest(viewModel.$limit, viewModel.$status)
            .receive(on: RunLoop.main)
            .sink { [weak self] speed, limit, status in
                self?.updateDashboardState(speed: speed, limit: limit, status: status)
            }
            .store(in: &cancellables)
    }
    
    private func updateDashboardState(speed: Double, limit: Int, status: SpeedStatus) {
        // Update the subtitle with current speed
        let formattedSpeed = String(format: "%.0f mph", speed)
        
        switch status {
        case .over:
            // Highlighting red for overspeed warning if supported
            speedShortcut = CPDashboardButton(titleVariants: ["OVERSPEED"], subtitleVariants: [formattedSpeed], image: UIImage(systemName: "exclamationmark.triangle.fill")) { _ in }
        case .warning:
            speedShortcut = CPDashboardButton(titleVariants: ["Warning"], subtitleVariants: [formattedSpeed], image: UIImage(systemName: "exclamationmark.circle")) { _ in }
        case .safe:
            speedShortcut = CPDashboardButton(titleVariants: ["Safe"], subtitleVariants: [formattedSpeed], image: UIImage(systemName: "checkmark.circle")) { _ in }
        }
        
        dashboardController?.shortcutButtons = [speedShortcut]
    }
}
