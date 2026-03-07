// CarPlaySpeedTemplate.swift
// Manages the CarPlay map template and speed alert display.

import CarPlay
import Combine

@MainActor
class CarPlaySpeedTemplate {

    let mapTemplate: CPMapTemplate
    private weak var interfaceController: CPInterfaceController?
    private let viewModel: DriveViewModel
    private var cancellables = Set<AnyCancellable>()
    private var isAlertPresented = false

    init(interfaceController: CPInterfaceController, viewModel: DriveViewModel) {
        self.interfaceController = interfaceController
        self.viewModel = viewModel
        self.mapTemplate = CPMapTemplate()
        setupTemplate()
        bindViewModel()
    }

    private func setupTemplate() {
        let startButton = CPMapButton { [weak self] _ in
            Task { @MainActor in self?.viewModel.startSession() }
        }
        startButton.image = UIImage(systemName: "play.fill")!

        let endButton = CPMapButton { [weak self] _ in
            Task { @MainActor in self?.viewModel.endSession() }
        }
        endButton.image = UIImage(systemName: "stop.fill")!

        let muteButton = CPMapButton { _ in }
        muteButton.image = UIImage(systemName: "speaker.slash.fill")!

        mapTemplate.mapButtons = [startButton, endButton, muteButton]
    }

    private func bindViewModel() {
        viewModel.$speed
            .combineLatest(viewModel.$limit, viewModel.$status)
            .receive(on: RunLoop.main)
            .sink { [weak self] speed, limit, status in
                self?.handleAlerts(speed: speed, limit: limit, status: status)
            }
            .store(in: &cancellables)
    }

    private func handleAlerts(speed: Double, limit: Int, status: SpeedStatus) {
        if status == .over && !isAlertPresented {
            presentAlert(speed: speed, limit: limit)
        } else if status != .over && isAlertPresented {
            interfaceController?.dismissTemplate(animated: true, completion: nil)
            isAlertPresented = false
        }
    }

    private func presentAlert(speed: Double, limit: Int) {
        let overAmount = Int(speed) - limit
        let action = CPAlertAction(title: "Acknowledged", style: .cancel) { [weak self] _ in
            self?.isAlertPresented = false
        }
        let alert = CPAlertTemplate(
            titleVariants: ["⚠ SPEED ALERT: +\(overAmount) mph over limit"],
            actions: [action]
        )
        isAlertPresented = true
        interfaceController?.presentTemplate(alert, animated: true, completion: nil)
    }
}
