// CarPlayNavigationRootTemplate.swift
// Enhanced root template — comprehensive HUD, settings, profiles, named locations.

import CarPlay
import Combine
import MapKit
import UIKit

@MainActor
class CarPlayNavigationRootTemplate: NSObject, CPSearchTemplateDelegate, CPMapTemplateDelegate {

    @MainActor let mapTemplate: CPMapTemplate
    @MainActor private weak var interfaceController: CPInterfaceController?
    @MainActor private let viewModel: DriveViewModel
    @MainActor private var navigationManager: CarPlayNavigationManager!

    // Sub-controllers
    @MainActor private lazy var settingsController = CarPlaySettingsController(
        interfaceController: interfaceController, viewModel: viewModel
    )
    @MainActor private lazy var namedLocationsController = CarPlayNamedLocationsController(
        interfaceController: interfaceController, viewModel: viewModel
    )

    private var cancellables = Set<AnyCancellable>()
    @MainActor private var isAlertPresented = false
    @MainActor private var isHandlingCarPlayTrip: Bool = false

    // HUD Bar Buttons
    @MainActor private var speedButton: CPBarButton!
    @MainActor private var limitButton: CPBarButton!
    @MainActor private var roadNameButton: CPBarButton!
    @MainActor private var sessionTimerButton: CPBarButton!

    // Map Buttons
    @MainActor private var settingsButton: CPMapButton!
    @MainActor private var searchButton: CPMapButton!
    @MainActor private var savedPlacesButton: CPMapButton!
    @MainActor private var addStopButton: CPMapButton!
    @MainActor private var startStopButton: CPMapButton!
    @MainActor private var muteButton: CPMapButton!
    @MainActor private var snoozeButton: CPMapButton!
    @MainActor private var wasSnoozeVisible: Bool = false

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
        mapTemplate.automaticallyHidesNavigationBar = false
        mapTemplate.mapDelegate = self

        let system = SpeedFormatting.measurementSystem()
        let unitShort = SpeedFormatting.unitLabelShort(measurementSystem: system)

        speedButton = CPBarButton(title: "0 \(unitShort)") { [weak self] _ in
            Task { @MainActor in self?.presentTripInfo() }
        }
        roadNameButton = CPBarButton(title: "") { _ in }
        limitButton = CPBarButton(title: "LIMIT --") { _ in }
        sessionTimerButton = CPBarButton(title: "") { [weak self] _ in
            Task { @MainActor in self?.presentDriveDetails() }
        }

        mapTemplate.leadingNavigationBarButtons = [speedButton, roadNameButton]
        mapTemplate.trailingNavigationBarButtons = [limitButton, sessionTimerButton]

        // Map buttons
        settingsButton = CPMapButton { [weak self] _ in
            Task { @MainActor in self?.settingsController.showSettings() }
        }
        settingsButton.image = UIImage(systemName: "gearshape.fill")!

        searchButton = CPMapButton { [weak self] _ in
            Task { @MainActor in self?.presentSearch() }
        }
        searchButton.image = UIImage(systemName: "magnifyingglass")!

        savedPlacesButton = CPMapButton { [weak self] _ in
            Task { @MainActor in self?.namedLocationsController.showSavedPlaces() }
        }
        savedPlacesButton.image = UIImage(systemName: "bookmark.fill")!

        addStopButton = CPMapButton { [weak self] _ in
            Task { @MainActor in self?.presentAddStopSearch() }
        }
        addStopButton.image = UIImage(systemName: "plus.circle.fill")!

        startStopButton = CPMapButton { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.viewModel.isRecording { self.viewModel.endSession() }
                else { self.viewModel.startSession() }
            }
        }
        startStopButton.image = UIImage(systemName: "play.fill")!

        muteButton = CPMapButton { [weak self] button in
            Task { @MainActor in
                guard let self = self else { return }
                let newMuted = !self.navigationManager.getMuted()
                self.navigationManager.setMuted(newMuted)
                button.image = UIImage(systemName: newMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")!
            }
        }
        muteButton.image = UIImage(systemName: "speaker.wave.2.fill")!

        snoozeButton = CPMapButton { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.viewModel.alertEngine.snoozeFor(15)
                self.updateMapButtons()
            }
        }
        snoozeButton.image = UIImage(systemName: "hand.raised.fill")!

        mapTemplate.mapButtons = [
            settingsButton, searchButton, savedPlacesButton,
            addStopButton, startStopButton, muteButton
        ]

        Task { @MainActor in
            let context = AppDelegate.sharedModelContainer.mainContext
            viewModel.loadVehicleProfiles(context: context)
            viewModel.loadAlertProfiles(context: context)
        }
    }

    @MainActor
    private func bindViewModel() {
        viewModel.$speed
            .combineLatest(viewModel.$limit, viewModel.$status, viewModel.$currentRoadName)
            .receive(on: RunLoop.main)
            .sink { [weak self] speed, limit, status, roadName in
                self?.updateHUD(speed: speed, limit: limit, status: status, roadName: roadName)
                self?.handleAlerts(speed: speed, limit: limit, status: status)
            }
            .store(in: &cancellables)

        viewModel.$sessionDuration
            .combineLatest(viewModel.$isRecording)
            .receive(on: RunLoop.main)
            .sink { [weak self] duration, isRecording in
                self?.updateSessionTimer(duration: duration, isRecording: isRecording)
            }
            .store(in: &cancellables)

        viewModel.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] isRecording in
                guard let self = self else { return }
                self.startStopButton.image = UIImage(systemName: isRecording ? "stop.fill" : "play.fill")!
            }
            .store(in: &cancellables)

        // 1-second timer re-evaluates the snooze button visibility so the
        // snooze button correctly reappears when the 15-second snooze window
        // expires (the @Published `$snoozedUntil` only fires on explicit .set,
        // not when time passes and the Date becomes stale).
        Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.updateMapButtons() }
            .store(in: &cancellables)

        // The add-stop button is always enabled — category search (gas/coffee/food)
        // works without an active route; a route is only needed when confirming a stop.
    }

    @MainActor
    private func updateHUD(speed: Double, limit: Int, status: SpeedStatus, roadName: String?) {
        let system = SpeedFormatting.measurementSystem()
        let unitShort = SpeedFormatting.unitLabelShort(measurementSystem: system)
        let displayLimit = SpeedFormatting.displayLimit(forMph: limit, measurementSystem: system)
        speedButton.title = "\(Int(speed)) \(unitShort)"
        limitButton.title = limit == 0 ? "LIMIT --" : "LIMIT \(displayLimit) \(unitShort)"
        let c: UIColor
        switch status {
        case .over:    c = UIColor(red: 1.0, green: 0.24, blue: 0.44, alpha: 1.0)
        case .warning: c = UIColor(red: 1.0, green: 0.72, blue: 0.0, alpha: 1.0)
        case .safe:    c = UIColor(red: 0.0, green: 1.0, blue: 0.62, alpha: 1.0)
        }
        limitButton.image = statusCircleImage(color: c, size: 20)
        roadNameButton.title = (roadName?.isEmpty == false) ? roadName! : ""
    }

    @MainActor
    private func updateSessionTimer(duration: TimeInterval, isRecording: Bool) {
        if !isRecording {
            sessionTimerButton.title = ""
            if mapTemplate.trailingNavigationBarButtons.contains(sessionTimerButton) {
                mapTemplate.trailingNavigationBarButtons = [limitButton]
            }
            return
        }
        let t = Int(duration)
        if t >= 3600 {
            sessionTimerButton.title = String(format: "%d:%02d:%02d", t/3600, (t%3600)/60, t%60)
        } else {
            sessionTimerButton.title = String(format: "%02d:%02d", t/60, t%60)
        }
        if !mapTemplate.trailingNavigationBarButtons.contains(sessionTimerButton) {
            mapTemplate.trailingNavigationBarButtons = [limitButton, sessionTimerButton]
        }
    }

    @MainActor
    private func updateMapButtons() {
        let showSnooze = viewModel.status == .over && !viewModel.alertEngine.isSnoozed
        if showSnooze && !wasSnoozeVisible {
            var b = mapTemplate.mapButtons; b.append(snoozeButton); mapTemplate.mapButtons = b
            wasSnoozeVisible = true
        } else if !showSnooze && wasSnoozeVisible {
            var b = mapTemplate.mapButtons; b.removeAll { $0 === snoozeButton }; mapTemplate.mapButtons = b
            wasSnoozeVisible = false
        }
    }

    @MainActor
    private func handleAlerts(speed: Double, limit: Int, status: SpeedStatus) {
        if status == .over && !isAlertPresented { presentNavigationAlert(speed: speed, limit: limit) }
        else if status != .over && isAlertPresented { isAlertPresented = false }
        updateMapButtons()
    }

    @MainActor
    private func presentNavigationAlert(speed: Double, limit: Int) {
        let system = SpeedFormatting.measurementSystem()
        let unitShort = SpeedFormatting.unitLabelShort(measurementSystem: system)
        let displayLimit = SpeedFormatting.displayLimit(forMph: limit, measurementSystem: system)
        let diff = Int(speed) - displayLimit
        let ok = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
            Task { @MainActor in self?.isAlertPresented = false }
        }
        let snooze = CPAlertAction(title: "I Know (15s)", style: .default) { [weak self] _ in
            Task { @MainActor in
                self?.viewModel.alertEngine.snoozeFor(15)
                self?.isAlertPresented = false
            }
        }
        let alert = CPNavigationAlert(
            titleVariants: ["⚠ SLOW DOWN", "Speeding +\(diff) \(unitShort)"],
            subtitleVariants: ["Limit is \(displayLimit) \(unitShort). Watch your speed."],
            image: nil, primaryAction: ok, secondaryAction: snooze, duration: 5.0
        )
        isAlertPresented = true
        mapTemplate.present(navigationAlert: alert, animated: true)
    }

    // MARK: - Info Cards

    @MainActor
    private func presentTripInfo() {
        let system = SpeedFormatting.measurementSystem()
        let unitShort = SpeedFormatting.unitLabelShort(measurementSystem: system)
        let unitLong = SpeedFormatting.unitLabelLong(measurementSystem: system)
        let displayLimit = SpeedFormatting.displayLimit(forMph: viewModel.limit, measurementSystem: system)
        let displayBuffer = Int(SpeedFormatting.displayBuffer(forMph: Double(viewModel.speedEngine.userBuffer), measurementSystem: system))
        let activeProfile = viewModel.alertProfiles.first(where: { $0.isActive })?.name ?? "Default"
        let activeVehicle = viewModel.vehicleProfiles.first(where: { $0.isActive })?.name ?? "Primary"

        var items: [CPInformationItem] = [
            CPInformationItem(title: "Speed", detail: "\(Int(viewModel.speed)) \(unitShort)"),
            CPInformationItem(title: "Speed Limit", detail: "\(displayLimit) \(unitShort)"),
            CPInformationItem(title: "Buffer", detail: "+\(displayBuffer) \(unitLong)"),
            CPInformationItem(title: "Alert Profile", detail: activeProfile),
        ]
        if let road = viewModel.currentRoadName, !road.isEmpty {
            items.append(CPInformationItem(title: "Road", detail: road))
        }
        items += [
            CPInformationItem(title: "Vehicle", detail: activeVehicle),
            CPInformationItem(title: "Status", detail: viewModel.status.rawValue.uppercased()),
        ]
        let template = CPInformationTemplate(title: "Current Drive", layout: .twoColumn, items: items,
            actions: [CPTextButton(title: "Dismiss", textStyle: .cancel, handler: { [weak self] _ in
                self?.interfaceController?.popTemplate(animated: true, completion: nil) })]
        )
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    @MainActor
    private func presentDriveDetails() {
        guard viewModel.isRecording else { return }
        let system = SpeedFormatting.measurementSystem()
        let unitShort = SpeedFormatting.unitLabelShort(measurementSystem: system)
        let t = Int(viewModel.sessionDuration)
        let durStr = t >= 3600 ? String(format: "%d h %02d m", t/3600, (t%3600)/60) : String(format: "%d min %02d s", t/60, t%60)
        let distMi = viewModel.sessionDuration > 0 ? viewModel.speed * (viewModel.sessionDuration / 3600.0) : 0
        let distStr: String
        if SpeedFormatting.isMetric(SpeedFormatting.measurementSystem()) {
            distStr = String(format: "%.1f km", distMi * 1.60934)
        } else {
            distStr = String(format: "%.1f mi", distMi)
        }
        let items: [CPInformationItem] = [
            CPInformationItem(title: "Duration", detail: durStr),
            CPInformationItem(title: "Distance", detail: distStr),
            CPInformationItem(title: "Current Speed", detail: "\(Int(viewModel.speed)) \(unitShort)"),
            CPInformationItem(title: "Status", detail: viewModel.isRecording ? "Recording" : "Stopped"),
        ]
        let template = CPInformationTemplate(title: "Drive Session", layout: .twoColumn, items: items,
            actions: [
                CPTextButton(title: "End Session", textStyle: .normal, handler: { [weak self] _ in
                    self?.interfaceController?.dismissTemplate(animated: true) { _, _ in
                        Task { @MainActor in self?.viewModel.endSession() }
                    }
                }),
                CPTextButton(title: "Dismiss", textStyle: .cancel, handler: { [weak self] _ in
                    self?.interfaceController?.popTemplate(animated: true, completion: nil)
                })
            ]
        )
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func statusCircleImage(color: UIColor, size: CGFloat = 44) -> UIImage {
        let r = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return r.image { ctx in
            color.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 2, y: 2, width: size-4, height: size-4))
        }
    }

    // MARK: - Search & Add Stop

    @MainActor
    private func presentSearch() {
        let t = CPSearchTemplate(); t.delegate = self
        interfaceController?.pushTemplate(t, animated: true, completion: nil)
    }

    @MainActor
    private func presentAddStopSearch() {
        let gas = CPListItem(text: "Gas Station", detailText: "Add a gas stop")
        gas.handler = { [weak self] _, c in Task { @MainActor in self?.searchAndAddStop(query: "Gas Station") }; c() }
        let coffee = CPListItem(text: "Coffee", detailText: "Add a coffee stop")
        coffee.handler = { [weak self] _, c in Task { @MainActor in self?.searchAndAddStop(query: "Coffee") }; c() }
        let food = CPListItem(text: "Food", detailText: "Add a food stop")
        food.handler = { [weak self] _, c in Task { @MainActor in self?.searchAndAddStop(query: "Restaurant") }; c() }
        let parking = CPListItem(text: "Parking", detailText: "Add a parking stop")
        parking.handler = { [weak self] _, c in Task { @MainActor in self?.searchAndAddStop(query: "Parking") }; c() }
        let search = CPListItem(text: "Search\u{2026}", detailText: "Search for a specific place")
        search.handler = { [weak self] _, c in Task { @MainActor in self?.presentSearch() }; c() }
        var items = [gas, coffee, food, parking, search]
        if !viewModel.routeStops.isEmpty {
            let vs = CPListItem(text: "View Stops (\(viewModel.routeStops.count))", detailText: "Manage current stops")
            vs.handler = { [weak self] _, c in Task { @MainActor in self?.presentStopsList() }; c() }
            items.insert(vs, at: 0)
        }
        interfaceController?.pushTemplate(CPListTemplate(title: "Add Stop", sections: [CPListSection(items: items, header: nil, sectionIndexTitle: nil)]), animated: true, completion: nil)
    }

    @MainActor
    private func searchAndAddStop(query: String) {
        navigationManager.searchDestination(query: query) { [weak self] results in
            guard let self = self, let first = results.first else { return }
            Task { @MainActor in
                await self.viewModel.addStopToRoute(first)
                self.interfaceController?.popToRootTemplate(animated: true, completion: nil)
            }
        }
    }

    @MainActor
    private func presentStopsList() {
        let items: [CPListItem] = viewModel.routeStops.enumerated().map { i, stop in
            let item = CPListItem(text: "\(i+1). \(stop.name)", detailText: stop.address ?? "")
            let sid = stop.id
            item.handler = { _, c in
                Task { @MainActor in await self.viewModel.removeStopFromRoute(sid); self.presentStopsList() }
                c()
            }
            return item
        }
        let t = CPListTemplate(title: "Route Stops (\(viewModel.routeStops.count))", sections: [CPListSection(items: items, header: nil, sectionIndexTitle: nil)])
        t.emptyViewTitleVariants = ["No Stops"]
        t.emptyViewSubtitleVariants = ["Add stops along your route"]
        interfaceController?.pushTemplate(t, animated: true, completion: nil)
    }

    // MARK: - CPSearchTemplateDelegate

    func searchTemplate(_ searchTemplate: CPSearchTemplate, updatedSearchText searchText: String, completionHandler: @escaping ([CPListItem]) -> Void) {
        Task { @MainActor in
            self.navigationManager.searchDestination(query: searchText) { results in
                let items = results.map { mi in
                    let item = CPListItem(text: mi.name, detailText: mi.placemark.title)
                    item.handler = { [weak self] _, c in
                        Task { @MainActor in
                            self?.interfaceController?.popTemplate(animated: true) { _, _ in self?.presentTripPreview(for: mi) }
                        }
                        c()
                    }
                    return item
                }
                completionHandler(items)
            }
        }
    }
    func searchTemplate(_ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem, completionHandler: @escaping () -> Void) { completionHandler() }

    // MARK: - Trip Preview

    @MainActor func showTurnByTurnList() { navigationManager.showManeuversList(interfaceController: interfaceController) }

    @MainActor
    private func presentTripPreview(for destination: MKMapItem) {
        let rc = CPRouteChoice(summaryVariants: [destination.name ?? "Destination"],
            additionalInformationVariants: [destination.placemark.title ?? ""],
            selectionSummaryVariants: ["Start Navigation"])
        let trip = CPTrip(origin: MKMapItem.forCurrentLocation(), destination: destination, routeChoices: [rc])
        let pt = CPTripPreviewTextConfiguration(startButtonTitle: "Start",
            additionalRoutesButtonTitle: nil, overviewButtonTitle: "Overview")
        mapTemplate.showTripPreviews([trip], textConfiguration: pt)
    }

    // MARK: - CPMapTemplateDelegate

    nonisolated func mapTemplate(_ mapTemplate: CPMapTemplate, startedTrip trip: CPTrip, using routeChoice: CPRouteChoice) {
        Task { @MainActor in
            guard !isHandlingCarPlayTrip else { return }
            isHandlingCarPlayTrip = true; defer { isHandlingCarPlayTrip = false }
            if viewModel.isNavigating { await viewModel.navigationCoordinator.endNavigation() }
            await navigationManager.handleCarPlayStartedTrip(trip)
        }
    }
    nonisolated func mapTemplateDidStopNavigating(_ mapTemplate: CPMapTemplate) {
        Task { @MainActor in
            if viewModel.isNavigating { await viewModel.navigationCoordinator.endNavigation() }
        }
    }
}
