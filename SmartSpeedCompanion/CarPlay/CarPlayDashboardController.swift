// CarPlayDashboardController.swift
// Displays speed status in the CarPlay dashboard shortcut buttons.

import CarPlay
import Combine

@MainActor
class CarPlayDashboardController {

    private weak var dashboardController: CPDashboardController?
    private let viewModel: DriveViewModel
    private var cancellables = Set<AnyCancellable>()

    init(dashboardController: CPDashboardController, viewModel: DriveViewModel) {
        self.dashboardController = dashboardController
        self.viewModel = viewModel
        bindViewModel()
    }

    private func bindViewModel() {
        viewModel.$speed
            .combineLatest(viewModel.$limit, viewModel.$status)
            .receive(on: RunLoop.main)
            .sink { [weak self] speed, limit, status in
                self?.updateButtons(speed: speed, limit: limit, status: status)
            }
            .store(in: &cancellables)
    }

    private func updateButtons(speed: Double, limit: Int, status: SpeedStatus) {
        let formattedSpeed = String(format: "%.0f mph", speed)
        let speedShortcut: CPDashboardButton

        switch status {
        case .over:
            speedShortcut = CPDashboardButton(
                titleVariants: ["OVERSPEED"],
                subtitleVariants: [formattedSpeed],
                image: UIImage(systemName: "exclamationmark.triangle.fill")!
            ) { _ in }
        case .warning:
            speedShortcut = CPDashboardButton(
                titleVariants: ["Warning"],
                subtitleVariants: [formattedSpeed],
                image: UIImage(systemName: "exclamationmark.circle")!
            ) { _ in }
        case .safe:
            speedShortcut = CPDashboardButton(
                titleVariants: ["Safe"],
                subtitleVariants: [formattedSpeed],
                image: UIImage(systemName: "checkmark.circle")!
            ) { _ in }
        }

        dashboardController?.shortcutButtons = [speedShortcut]
    }
}
