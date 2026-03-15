// CarPlayNavigationRootTemplate.swift
// Manages the CarPlay 75/25 visual map template layout and navigation components.

import CarPlay
import Combine

class CarPlayNavigationRootTemplate: NSObject, CPSearchTemplateDelegate {

    @MainActor let mapTemplate: CPMapTemplate
    @MainActor private weak var interfaceController: CPInterfaceController?
    @MainActor private let viewModel: DriveViewModel
    @MainActor private var navigationManager: CarPlayNavigationManager!
    
    private var cancellables = Set<AnyCancellable>()
    @MainActor private var isAlertPresented = false
    
    // Top bar elements
    @MainActor private var speedButton: CPBarButton!
    @MainActor private var limitButton: CPBarButton!

    @MainActor
    init(interfaceController: CPInterfaceController, viewModel: DriveViewModel) {
        self.interfaceController = interfaceController
        self.viewModel = viewModel
        self.mapTemplate = CPMapTemplate()
        
        super.init()
        
        self.navigationManager = CarPlayNavigationManager(viewModel: viewModel, mapTemplate: mapTemplate)
        
        setupTemplate()
        bindViewModel()
    }

    @MainActor
    private func setupTemplate() {
        // Navigation Bar Buttons (Top - Representing the 25% overlay conceptually)
        speedButton = CPBarButton(title: "0 MPH") { _ in }
        limitButton = CPBarButton(title: "LIMIT 0") { _ in }
        mapTemplate.leadingNavigationBarButtons = [speedButton]
        mapTemplate.trailingNavigationBarButtons = [limitButton]
        
        // Map Buttons (Right Side)
        let searchButton = CPMapButton { [weak self] _ in
            Task { @MainActor in self?.presentSearch() }
        }
        searchButton.image = UIImage(systemName: "magnifyingglass")!
        
        let startButton = CPMapButton { [weak self] _ in
            Task { @MainActor in self?.viewModel.startSession() }
        }
        startButton.image = UIImage(systemName: "play.fill")!

        let endButton = CPMapButton { [weak self] _ in
            Task { @MainActor in self?.viewModel.endSession() }
        }
        endButton.image = UIImage(systemName: "stop.fill")!

        let muteButton = CPMapButton { [weak self] button in
            Task { @MainActor in 
                guard let self = self else { return }
                let newMuted = !self.navigationManager.getMuted()
                self.navigationManager.setMuted(newMuted)
                // Update icon to show current state
                button.image = UIImage(systemName: newMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")!
            }
        }
        muteButton.image = UIImage(systemName: "speaker.wave.2.fill")!

        mapTemplate.mapButtons = [searchButton, startButton, endButton, muteButton]
    }

    @MainActor
    private func bindViewModel() {
        viewModel.$speed
            .combineLatest(viewModel.$limit, viewModel.$status)
            .receive(on: RunLoop.main)
            .sink { [weak self] speed, limit, status in
                self?.updateHUD(speed: speed, limit: limit, status: status)
                self?.handleAlerts(speed: speed, limit: limit, status: status)
            }
            .store(in: &cancellables)
    }

    @MainActor
    private func updateHUD(speed: Double, limit: Int, status: SpeedStatus) {
        speedButton.title = "\(Int(speed)) MPH"
        limitButton.title = "LIMIT \(limit)"
        
        let circleColor: UIColor
        switch status {
        case .over: circleColor = UIColor(red: 1.0, green: 0.24, blue: 0.44, alpha: 1.0) // red
        case .warning: circleColor = UIColor(red: 1.0, green: 0.72, blue: 0.0, alpha: 1.0) // amber
        case .safe: circleColor = UIColor(red: 0.0, green: 1.0, blue: 0.62, alpha: 1.0) // green
        }
        
        limitButton.image = statusCircleImage(color: circleColor, size: 20)
    }
    
    private func statusCircleImage(color: UIColor, size: CGFloat = 44) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            color.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 2, y: 2, width: size-4, height: size-4))
        }
    }

    @MainActor
    private func handleAlerts(speed: Double, limit: Int, status: SpeedStatus) {
        if status == .over && !isAlertPresented {
            presentAlert(speed: speed, limit: limit)
        } else if status != .over && isAlertPresented {
            interfaceController?.dismissTemplate(animated: true, completion: nil)
            isAlertPresented = false
        }
    }

    @MainActor
    private func presentAlert(speed: Double, limit: Int) {
        _ = Int(speed) - limit
        let action = CPAlertAction(title: "Got It", style: .cancel) { [weak self] _ in
            Task { @MainActor in self?.isAlertPresented = false }
        }
        let alert = CPAlertTemplate(
            titleVariants: ["⚠ SPEED ALERT", "SPEED ALERT"],
            actions: [action]
        )
        isAlertPresented = true
        interfaceController?.presentTemplate(alert, animated: true, completion: nil)
    }
    
    // MARK: - Search
    @MainActor
    private func presentSearch() {
        let searchTemplate = CPSearchTemplate()
        searchTemplate.delegate = self
        interfaceController?.pushTemplate(searchTemplate, animated: true, completion: nil)
    }
    
    public func searchTemplate(_ searchTemplate: CPSearchTemplate, updatedSearchText searchText: String, completionHandler: @escaping ([CPListItem]) -> Void) {
        Task { @MainActor in
            self.navigationManager.searchDestination(query: searchText) { results in
                let listItems = results.map { mapItem in
                    let item = CPListItem(text: mapItem.name, detailText: mapItem.placemark.title)
                    item.handler = { [weak self] _, completion in
                        Task { @MainActor in
                            self?.interfaceController?.popTemplate(animated: true, completion: nil)
                            self?.navigationManager.startNavigation(to: mapItem)
                        }
                        completion()
                    }
                    return item
                }
                completionHandler(listItems)
            }
        }
    }

    public func searchTemplate(_ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem, completionHandler: @escaping () -> Void) {
        // If the item.handler is set, it will be called automatically by CarPlay.
        // We implement this to satisfy protocol requirements.
        completionHandler()
    }
}
