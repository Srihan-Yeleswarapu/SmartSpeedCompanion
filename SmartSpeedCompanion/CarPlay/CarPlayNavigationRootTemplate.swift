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
        
        // Show the user's blue dot on the CarPlay map so the driver
        // always sees their current location.
        mapTemplate.showCurrentLocation = true
        
        // ── Pan gesture handlers ─────────────────────────────────────
        // Detect when the user manually pans the map so the system can
        // differentiate between auto-tracking and manual interaction.
        // When the user pans, we set isMapDetached = true; when they
        // stop and the camera settles, the DriveViewModel or LiveMapView
        // can re-engage tracking after a timeout.
        mapTemplate.panBeganHandler = { [weak self] _ in
            Task { @MainActor in
                self?.viewModel.isMapDetached = true
            }
        }
        mapTemplate.panEndedHandler = { [weak self] _ in
            // The map stops auto-following until the user taps the
            // "re-center" button. DriveViewModel's existing
            // isMapDetached property is observed by LiveMapView.
            Task { @MainActor in
                // No immediate action — the next camera update will
                // respect isMapDetached. A future "re-center" button
                // can set isMapDetached back to false.
            }
        }

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
                            self?.interfaceController?.popTemplate(animated: true) { _ in
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
        // Show a trip preview with route choices before starting navigation.
        // This is the standard CarPlay UX pattern: the user sees the route
        // overview and can confirm before guidance begins, matching the
        // behavior of Apple Maps and Google Maps on CarPlay.
        Task {
            do {
                let route = try await navigationManager.calculateRoute(to: destination)
                let routeChoice = CPRouteChoice(
                    summaryVariants: ["Fastest Route — \(formatDuration(route.expectedTravelTime))"],
                    additionalInformationVariants: ["\(formatDistance(route.distance))"],
                    selectionSummaryVariants: ["Start Navigation"]
                )
                let trip = CPTrip(
                    origin: MKMapItem.forCurrentLocation(),
                    destination: destination,
                    routeChoices: [routeChoice]
                )
                // Trip preview text config: instructional labels before the
                // trip starts so the user knows what they're confirming.
                let previewText = CPTripPreviewTextConfiguration(
                    startButtonTitle: "Start",
                    additionalRoutesButtonTitle: nil,
                    overviewButtonTitle: "Overview"
                )

                // Register handlers BEFORE showing the preview to avoid any
                // race where CarPlay invokes the handlers during presentation
                // setup before they're assigned.
                mapTemplate.tripPreviewsSelectedHandler = { [weak self] _, _ in
                    Task { @MainActor in
                        self?.mapTemplate.hideTripPreviews()
                        self?.navigationManager.startNavigation(route: route, destination: destination)
                    }
                }
                mapTemplate.tripPreviewsCanceledHandler = { [weak self] in
                    Task { @MainActor in
                        self?.mapTemplate.hideTripPreviews()
                    }
                }

                // Present the trip preview on the map template.
                // This shows the route overview with "Start" and "Overview"
                // buttons. The map zooms out to show the full route.
                mapTemplate.showTripPreviews(
                    [trip],
                    textConfiguration: previewText
                )
            } catch {
                // Fallback: start navigation directly without preview
                navigationManager.startNavigation(to: destination)
            }
        }
    }

    private func formatDuration(_ timeInterval: TimeInterval) -> String {
        let minutes = Int(timeInterval / 60)
        if minutes < 60 {
            return "\(minutes) min"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if remainingMinutes == 0 {
            return "\(hours) hr"
        }
        return "\(hours) hr \(remainingMinutes) min"
    }

    private func formatDistance(_ meters: Double) -> String {
        let system = SpeedFormatting.measurementSystem()
        let display = SpeedFormatting.distanceDisplay(forMeters: meters, measurementSystem: system)
        // Use a tolerance-based check instead of exact equality to avoid
        // floating-point truncation issues for large distances
        // (e.g. 500.0 km stored as 499.99999999999994).
        let isWhole = abs(display.value - display.value.rounded()) < 0.001
        let valueStr = isWhole
            ? "\(Int(display.value.rounded()))"
            : String(format: "%.1f", display.value)
        return "\(valueStr) \(display.unit)"
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