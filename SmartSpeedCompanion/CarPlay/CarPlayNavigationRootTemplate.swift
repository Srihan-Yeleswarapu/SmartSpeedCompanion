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
        // ── Map template configuration ───────────────────────────────
        // Keep the navigation bar visible at all times so the speed/limit
        // buttons are always accessible. This matches Apple Maps' CarPlay
        // behavior where the HUD never auto-hides during guidance.
        mapTemplate.automaticallyHidesNavigationBar = false

        // Navigation Bar Buttons (Top - Representing the 25% overlay conceptually).
        // Placeholder labels honor Settings → UNITS so a metric user's first
        // frame never flashes "0 MPH" before the publisher fires (TestFlight
        // 2.1.4 feedback about MPH bleeding through the toggle).
        let initialSystem = SpeedFormatting.measurementSystem()
        let initialUnitShort = SpeedFormatting.unitLabelShort(measurementSystem: initialSystem)
        speedButton = CPBarButton(title: "0 \(initialUnitShort)") { _ in }
        limitButton = CPBarButton(title: "LIMIT 0 \(initialUnitShort)") { _ in }
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

        let reportButton = CPMapButton { [weak self] _ in
            Task { @MainActor in self?.presentSafetyReport() }
        }
        reportButton.image = UIImage(systemName: "chart.bar.fill")!

        mapTemplate.mapButtons = [searchButton, reportButton, startButton, endButton, muteButton]
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
        // Both bar buttons honor Settings → UNITS. `speed` is already
        // in the active display unit (SpeedEngine converts mph→km/h before
        // publishing); the limit is still stored in mph so we route it
        // through `SpeedFormatting.displayLimit(forMph:…)` for the value.
        let system = SpeedFormatting.measurementSystem()
        let unitShort = SpeedFormatting.unitLabelShort(measurementSystem: system)
        let displayLimit = SpeedFormatting.displayLimit(forMph: limit, measurementSystem: system)

        speedButton.title = "\(Int(speed)) \(unitShort)"
        limitButton.title = limit == 0
            ? "LIMIT --"
            : "LIMIT \(displayLimit) \(unitShort)"

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
            presentNavigationAlert(speed: speed, limit: limit)
        } else if status != .over && isAlertPresented {
            isAlertPresented = false
        }
    }

    @MainActor
    private func presentNavigationAlert(speed: Double, limit: Int) {
        // Diff is computed in display units: `speed` is already in the
        // active display unit (SpeedEngine converts mph→km/h before
        // publishing), so we subtract the DISPLAY-converted limit to keep
        // both operands in the same unit. Otherwise a Metric user would
        // see "Speeding +5 KMH" for a 70-km/h car against a 65-mph limit
        // (which is actually under the limit, since 70 km/h ≈ 43 mph).
        let system = SpeedFormatting.measurementSystem()
        let unitShort = SpeedFormatting.unitLabelShort(measurementSystem: system)
        let displayLimit = SpeedFormatting.displayLimit(forMph: limit, measurementSystem: system)
        let diff = Int(speed) - displayLimit

        let action = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
            Task { @MainActor in self?.isAlertPresented = false }
        }

        // Use CPNavigationAlert so the map is never blocked. Both
        // subtitle variants honor UNITS so the alert text never reads
        // "Limit is 65 MPH" for a metric user.
        let alert = CPNavigationAlert(
            titleVariants: ["⚠ SLOW DOWN", "Speeding +\(diff) \(unitShort)"],
            subtitleVariants: ["Limit is \(displayLimit) \(unitShort). Watch your speed."],
            image: nil,
            primaryAction: action,
            secondaryAction: nil,
            duration: 5.0
        )

        isAlertPresented = true
        mapTemplate.present(navigationAlert: alert, animated: true)
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
                            // Pop the search template first, and only show the
                            // trip preview AFTER the pop completes. CarPlay's
                            // template stack requires sequential transitions —
                            // pushing a preview (showTripPreviews) while a pop
                            // is still in-flight can leave the stack in an
                            // inconsistent state.
                            self?.interfaceController?.popTemplate(animated: true) { _, _ in
                                self?.presentTripPreview(for: mapItem)
                            }
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

    @MainActor
    public func showTurnByTurnList() {
        navigationManager.showManeuversList(interfaceController: interfaceController)
    }

    // MARK: - Trip Preview

    @MainActor
    private func presentTripPreview(for destination: MKMapItem) {
        // Show a trip preview before starting navigation — the standard
        // CarPlay UX pattern for route confirmation.
        //
        // NOTE: We do NOT call navigationManager.calculateRoute(to:) here
        // because CarPlay recalculates its own route when the user taps
        // "Start" (no delegate intercepts it). Running a full MKDirections
        // call just for display labels would add 2–5 s of unnecessary
        // latency before the preview appears.
        let routeChoice = CPRouteChoice(
            summaryVariants: [destination.name ?? "Destination"],
            additionalInformationVariants: [destination.placemark.title ?? ""],
            selectionSummaryVariants: ["Start Navigation"]
        )
        let trip = CPTrip(
            origin: MKMapItem.forCurrentLocation(),
            destination: destination,
            routeChoices: [routeChoice]
        )
        let previewText = CPTripPreviewTextConfiguration(
            startButtonTitle: "Start",
            additionalRoutesButtonTitle: nil,
            overviewButtonTitle: "Overview"
        )

        // Present the trip preview immediately.
        // CarPlay auto-manages the "Start"/"Overview" buttons and
        // starts navigation with its own route calculation when the
        // user taps "Start".
        mapTemplate.showTripPreviews(
            [trip],
            textConfiguration: previewText
        )
    }

    @MainActor
    private func presentSafetyReport() {
        // Information Template for professional session summaries.
        // CarPlay "Current Speed" detail honors Settings → UNITS too —
        // the previous hardcoded "MPH" was caught by TestFlight 2.1.4
        // feedback on the same mph/kmh toggle.
        let system = SpeedFormatting.measurementSystem()
        let unitShort = SpeedFormatting.unitLabelShort(measurementSystem: system)

        let items = [
            CPInformationItem(title: "Current Speed", detail: "\(Int(viewModel.speed)) \(unitShort)"),
            CPInformationItem(title: "Drive Time", detail: "\(Int(viewModel.sessionDuration / 60)) min"),
            CPInformationItem(title: "Status", detail: viewModel.status.rawValue.uppercased())
        ]      
        
        let report = CPInformationTemplate(
            title: "Safety Report",
            layout: .twoColumn,
            items: items,
            actions: [CPTextButton(title: "Dismiss", textStyle: .cancel, handler: { [weak self] _ in
                self?.interfaceController?.popTemplate(animated: true, completion: nil)
            })]
        )
        
        interfaceController?.pushTemplate(report, animated: true, completion: nil)
    }
}