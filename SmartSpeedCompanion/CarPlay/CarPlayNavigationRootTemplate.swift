// CarPlayNavigationRootTemplate.swift
// Manages the CarPlay 75/25 visual map template layout and navigation components.

import CarPlay
import Combine

@MainActor
class CarPlayNavigationRootTemplate: NSObject, CPSearchTemplateDelegate, CPMapTemplateDelegate {

    @MainActor let mapTemplate: CPMapTemplate
    @MainActor private weak var interfaceController: CPInterfaceController?
    @MainActor private let viewModel: DriveViewModel
    @MainActor private var navigationManager: CarPlayNavigationManager!
    
    private var cancellables = Set<AnyCancellable>()
    @MainActor private var isAlertPresented = false
    /// Guards against re-entrant calls to `startedTrip` in the unlikely
    /// event that `mapTemplate.startNavigationSession(for:)` (called from
    /// the manager's navigation start chain) also fires the delegate.
    /// Without this guard, a re-entrant call could create an infinite
    /// loop: startedTrip → endNavigation → startNavigation → startedTrip...
    @MainActor private var isHandlingCarPlayTrip: Bool = false
    
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

        // Observe CarPlay-started navigation (session restoration, trip preview "Start").
        // Without this delegate, the app never learns about sessions CarPlay starts
        // internally — e.g. after "Session interrupted — restore route?" → Yes.
        // CPMapTemplate exposes `mapDelegate` (not `delegate`) for the
        // CPMapTemplateDelegate protocol.
        mapTemplate.mapDelegate = self

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

        // Add Stop map button — visible when navigating with a destination
        let addStopButton = CPMapButton { [weak self] _ in
            Task { @MainActor in self?.presentAddStopSearch() }
        }
        addStopButton.image = UIImage(systemName: "plus.circle.fill")!

        mapTemplate.mapButtons = [searchButton, reportButton, addStopButton, startButton, endButton, muteButton]
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
    
    // MARK: - Search & Add Stop
    @MainActor
    private func presentSearch() {
        let searchTemplate = CPSearchTemplate()
        searchTemplate.delegate = self
        interfaceController?.pushTemplate(searchTemplate, animated: true, completion: nil)
    }

    @MainActor
    private func presentAddStopSearch() {
        // Show a quick-search list template for adding a stop to the route.
        // Presents gas, coffee, food, parking categories plus a manual search option.
        let gasItem = CPListItem(text: "Gas Station", detailText: "Add a gas stop")
        gasItem.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.searchAndAddStop(query: "Gas Station")
            }
            completion()
        }
        let coffeeItem = CPListItem(text: "Coffee", detailText: "Add a coffee stop")
        coffeeItem.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.searchAndAddStop(query: "Coffee")
            }
            completion()
        }
        let foodItem = CPListItem(text: "Food", detailText: "Add a food stop")
        foodItem.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.searchAndAddStop(query: "Restaurant")
            }
            completion()
        }
        let parkingItem = CPListItem(text: "Parking", detailText: "Add a parking stop")
        parkingItem.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.searchAndAddStop(query: "Parking")
            }
            completion()
        }
        let searchItem = CPListItem(text: "Search…", detailText: "Search for a specific place")
        searchItem.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.presentSearch()
            }
            completion()
        }

        let stopCount = viewModel.routeStops.count
        var items = [gasItem, coffeeItem, foodItem, parkingItem, searchItem]

        if !viewModel.routeStops.isEmpty {
            let viewStopsItem = CPListItem(
                text: "View Stops (\(stopCount))",
                detailText: "Manage current stops"
            )
            viewStopsItem.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.presentStopsList()
                }
                completion()
            }
            items.insert(viewStopsItem, at: 0)
        }

        let section = CPListSection(items: items)
        let listTemplate = CPListTemplate(title: "Add Stop", sections: [section])
        interfaceController?.pushTemplate(listTemplate, animated: true, completion: nil)
    }

    @MainActor
    private func searchAndAddStop(query: String) {
        navigationManager.searchDestination(query: query) { [weak self] results in
            guard let self = self, let first = results.first else { return }
            Task { @MainActor in
                await self.viewModel.addStopToRoute(first)
                // Pop back to the main map after adding
                await self.interfaceController?.popToRootTemplate(animated: true)
            }
        }
    }

    @MainActor
    private func presentStopsList() {
        let items: [CPListItem] = viewModel.routeStops.enumerated().map { index, stop in
            let item = CPListItem(
                text: "\(index + 1). \(stop.name)",
                detailText: stop.address ?? ""
            )
            let stopId = stop.id
            // Delete action via trailing swipe
            item.handler = { _, completion in
                Task { @MainActor in
                    await self.viewModel.removeStopFromRoute(stopId)
                    self.presentStopsList() // Refresh the list
                }
                completion()
            }
            return item
        }

        let section = CPListSection(items: items)
        let listTemplate = CPListTemplate(
            title: "Route Stops (\(viewModel.routeStops.count))",
            sections: [section]
        )
        listTemplate.emptyViewTitleVariants = ["No Stops"]
        listTemplate.emptyViewSubtitleVariants = ["Add stops along your route"]
        interfaceController?.pushTemplate(listTemplate, animated: true, completion: nil)
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
        // "Start" and we now handle that in the CPMapTemplateDelegate
        // callback. Running a full MKDirections call just for display
        // labels would add 2–5 s of unnecessary latency before the
        // preview appears.
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

    // MARK: - CPMapTemplateDelegate
    //
    // These methods bridge CarPlay's internal navigation lifecycle (session
    // restoration, trip preview "Start" button) to the app's NavigationCoordinator
    // and CarPlayNavigationManager so our state stays in sync.

    /// Called when CarPlay starts a navigation session — either because
    /// the user accepted a restoration prompt after a reconnect, or because
    /// they tapped "Start" on a trip preview. We calculate our own route and
    /// run through the full app navigation pipeline so the speed HUD,
    /// turn-by-turn chip, and drive recording all reflect the active trip.
    nonisolated func mapTemplate(_ mapTemplate: CPMapTemplate, startedTrip trip: CPTrip, using routeChoice: CPRouteChoice) {
        Task { @MainActor in
            // Re-entrancy guard: if mapTemplate.startNavigationSession(for:) fires
            // this delegate call back (not expected per Apple docs, but possible),
            // skip processing to prevent an infinite adoption loop.
            guard !isHandlingCarPlayTrip else { return }
            isHandlingCarPlayTrip = true
            defer { isHandlingCarPlayTrip = false }

            // End any previous coordinator state first so the new
            // navigation starts clean (reroute timer, step flags, etc.).
            if viewModel.isNavigating {
                await viewModel.navigationCoordinator.endNavigation()
            }
            // Have the manager adopt the CarPlay-started trip.
            await navigationManager.handleCarPlayStartedTrip(trip)
        }
    }

    /// Called when CarPlay stops navigating (user tapped "End" or arrived).
    /// Pushes the cleanup through the coordinator so our state mirrors
    /// what CarPlay's UI is doing.
    nonisolated func mapTemplateDidStopNavigating(_ mapTemplate: CPMapTemplate) {
        Task { @MainActor in
            if viewModel.isNavigating {
                await viewModel.navigationCoordinator.endNavigation()
                // navigationManager.endNavigation() is called inside
                // the coordinator's endNavigation flow via the delegate.
            }
        }
    }
}