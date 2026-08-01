// CarPlayNavigationRootTemplate.swift
// Enhanced root template — comprehensive HUD, navigation, and named locations.
// Settings are intentionally NOT shown on CarPlay; they live only in the iPhone app.

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
    @MainActor private var searchButton: CPMapButton!
    @MainActor private var savedPlacesButton: CPMapButton!
    @MainActor private var addStopButton: CPMapButton!
    @MainActor private var startStopButton: CPMapButton!
    @MainActor private var muteButton: CPMapButton!
    @MainActor private var snoozeButton: CPMapButton!
    @MainActor private var wasSnoozeVisible: Bool = false
    // Incremented on every + category tap; results only push if they belong
    // to the latest request, so a slow earlier search can't overwrite a
    // newer category's results (mirrors PlanB's searchGeneration pattern).
    @MainActor private var stopSearchGeneration: UInt64 = 0
    // Same guard for the live search box: each keystroke bumps this, and only
    // the newest query's results may be delivered to the CPSearchTemplate.
    @MainActor private var searchGeneration: UInt64 = 0
    // Maps CPListItem → MKMapItem for the current CPSearchTemplate results
    // so the selectedResult delegate can identify which item was tapped.
    @MainActor private var searchItemMap: [ObjectIdentifier: MKMapItem] = [:]

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

        // Map buttons — colored circular badges for a Google/Apple Maps look.
        // NOTE: No Settings button — settings are phone-only by design.
        searchButton = CPMapButton { [weak self] _ in
            Task { @MainActor in self?.presentSearch() }
        }
        searchButton.image = CarPlayUI.circleBadge(systemName: "magnifyingglass", color: CarPlayUI.cyan)
        searchButton.focusedImage = CarPlayUI.circleBadge(systemName: "magnifyingglass", color: CarPlayUI.cyan, size: 52)

        savedPlacesButton = CPMapButton { [weak self] _ in
            Task { @MainActor in self?.namedLocationsController.showSavedPlaces() }
        }
        savedPlacesButton.image = CarPlayUI.circleBadge(systemName: "bookmark.fill", color: CarPlayUI.pink)
        savedPlacesButton.focusedImage = CarPlayUI.circleBadge(systemName: "bookmark.fill", color: CarPlayUI.pink, size: 52)

        addStopButton = CPMapButton { [weak self] _ in
            Task { @MainActor in self?.presentAddStopSearch() }
        }
        addStopButton.image = CarPlayUI.circleBadge(systemName: "plus", color: CarPlayUI.orange)
        addStopButton.focusedImage = CarPlayUI.circleBadge(systemName: "plus", color: CarPlayUI.orange, size: 52)

        startStopButton = CPMapButton { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.viewModel.isRecording { self.viewModel.endSession() }
                else { self.viewModel.startSession() }
            }
        }
        startStopButton.image = CarPlayUI.circleBadge(systemName: "play.fill", color: CarPlayUI.neonGreen)
        startStopButton.focusedImage = CarPlayUI.circleBadge(systemName: "play.fill", color: CarPlayUI.neonGreen, size: 52)

        muteButton = CPMapButton { [weak self] button in
            Task { @MainActor in
                guard let self = self else { return }
                let newMuted = !self.navigationManager.getMuted()
                self.navigationManager.setMuted(newMuted)
                button.image = CarPlayUI.circleBadge(systemName: newMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                                     color: newMuted ? CarPlayUI.amber : CarPlayUI.blue)
                button.focusedImage = button.image
            }
        }
        muteButton.image = CarPlayUI.circleBadge(systemName: "speaker.wave.2.fill", color: CarPlayUI.blue)
        muteButton.focusedImage = CarPlayUI.circleBadge(systemName: "speaker.wave.2.fill", color: CarPlayUI.blue, size: 52)

        snoozeButton = CPMapButton { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.viewModel.alertEngine.snoozeFor(15)
                self.updateMapButtons()
            }
        }
        snoozeButton.image = CarPlayUI.circleBadge(systemName: "hand.raised.fill", color: CarPlayUI.alertRed)
        snoozeButton.focusedImage = CarPlayUI.circleBadge(systemName: "hand.raised.fill", color: CarPlayUI.alertRed, size: 52)

        mapTemplate.mapButtons = [
            searchButton, addStopButton, savedPlacesButton,
            muteButton, startStopButton
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
                self.startStopButton.image = CarPlayUI.circleBadge(systemName: isRecording ? "stop.fill" : "play.fill",
                                                                   color: isRecording ? CarPlayUI.alertRed : CarPlayUI.neonGreen)
                self.startStopButton.focusedImage = self.startStopButton.image
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
        limitButton.image = CarPlayUI.statusPill(color: CarPlayUI.statusColor(status))
        roadNameButton.title = (roadName?.isEmpty == false) ? roadName! : ""
    }

    @MainActor
    private func updateSessionTimer(duration: TimeInterval, isRecording: Bool) {
        if !isRecording {
            sessionTimerButton.title = ""
            sessionTimerButton.image = nil
            if mapTemplate.trailingNavigationBarButtons.contains(sessionTimerButton) {
                mapTemplate.trailingNavigationBarButtons = [limitButton]
            }
            return
        }
        sessionTimerButton.image = CarPlayUI.dot(color: CarPlayUI.alertRed)
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
                    self?.interfaceController?.popTemplate(animated: true) { _, _ in
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

    /// Colored icon tile for a search result based on its POI category.
    /// `nonisolated` so it can be called from the search completion closure.
    private nonisolated func searchResultIcon(for mapItem: MKMapItem) -> UIImage? {
        switch mapItem.pointOfInterestCategory {
        case .gasStation: return CarPlayUI.iconTile(systemName: "fuelpump.fill", color: CarPlayUI.orange)
        case .cafe:       return CarPlayUI.iconTile(systemName: "cup.and.saucer.fill", color: CarPlayUI.amber)
        case .restaurant: return CarPlayUI.iconTile(systemName: "fork.knife", color: CarPlayUI.pink)
        case .parking:    return CarPlayUI.iconTile(systemName: "p.circle.fill", color: CarPlayUI.blue)
        case .hotel:      return CarPlayUI.iconTile(systemName: "bed.double.fill", color: CarPlayUI.purple)
        case .hospital:   return CarPlayUI.iconTile(systemName: "cross.case.fill", color: CarPlayUI.alertRed)
        case .store:      return CarPlayUI.iconTile(systemName: "bag.fill", color: CarPlayUI.teal)
        case .evCharger:  return CarPlayUI.iconTile(systemName: "bolt.car.fill", color: CarPlayUI.neonGreen)
        default:          return CarPlayUI.iconTile(systemName: "mappin.circle.fill", color: CarPlayUI.gray)
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
        // Grid of big, colorful quick actions — safe to scan while driving.
        let gas = CPGridButton(titleVariants: ["Gas Station"],
                               image: CarPlayUI.iconTile(systemName: "fuelpump.fill", color: CarPlayUI.orange, size: 56)) { [weak self] _ in
            Task { @MainActor in self?.searchAndAddStop(query: "Gas Station") }
        }
        let coffee = CPGridButton(titleVariants: ["Coffee"],
                                  image: CarPlayUI.iconTile(systemName: "cup.and.saucer.fill", color: CarPlayUI.amber, size: 56)) { [weak self] _ in
            Task { @MainActor in self?.searchAndAddStop(query: "Coffee") }
        }
        let food = CPGridButton(titleVariants: ["Food"],
                                image: CarPlayUI.iconTile(systemName: "fork.knife", color: CarPlayUI.pink, size: 56)) { [weak self] _ in
            Task { @MainActor in self?.searchAndAddStop(query: "Restaurant") }
        }
        let parking = CPGridButton(titleVariants: ["Parking"],
                                   image: CarPlayUI.iconTile(systemName: "p.circle.fill", color: CarPlayUI.blue, size: 56)) { [weak self] _ in
            Task { @MainActor in self?.searchAndAddStop(query: "Parking") }
        }
        let search = CPGridButton(titleVariants: ["Search"],
                                  image: CarPlayUI.iconTile(systemName: "magnifyingglass", color: CarPlayUI.cyan, size: 56)) { [weak self] _ in
            Task { @MainActor in self?.presentSearch() }
        }
        var buttons = [gas, coffee, food, parking, search]
        if !viewModel.routeStops.isEmpty {
            let vs = CPGridButton(titleVariants: ["Stops (\(viewModel.routeStops.count))"],
                                  image: CarPlayUI.iconTile(systemName: "list.bullet", color: CarPlayUI.purple, size: 56)) { [weak self] _ in
                Task { @MainActor in self?.presentStopsList() }
            }
            buttons.insert(vs, at: 0)
        }
        interfaceController?.pushTemplate(CPGridTemplate(title: "Add Stop", gridButtons: buttons), animated: true, completion: nil)
    }

    @MainActor
    private func searchAndAddStop(query: String) {
        stopSearchGeneration += 1
        let generation = stopSearchGeneration
        navigationManager.searchDestination(query: query) { [weak self] results in
            guard let self = self else { return }
            Task { @MainActor in
                // Ignore stale responses: if the driver tapped a different
                // category (or left the + flow) while this search was in
                // flight, a newer request is authoritative.
                guard generation == self.stopSearchGeneration else { return }
                self.presentStopOptions(title: query, results: results)
            }
        }
    }

    /// Show a picker of nearby results so the driver chooses the exact place
    /// (nearest first, with distance) instead of auto-adding the first hit.
    /// Used by every category shortcut (+ button: gas, coffee, food, parking).
    @MainActor
    private func presentStopOptions(title: String, results: [MKMapItem]) {
        guard !results.isEmpty else {
            let noResults = CPListItem(text: "No Results", detailText: "Try a different category")
            noResults.isEnabled = false
            let template = CPListTemplate(title: title, sections: [
                CPListSection(items: [noResults], header: nil, sectionIndexTitle: nil)
            ])
            interfaceController?.pushTemplate(template, animated: true, completion: nil)
            return
        }

        // Nearest first so the closest option is always at the top.
        let sorted = results.sorted {
            (distanceFromUser(to: $0) ?? .infinity) < (distanceFromUser(to: $1) ?? .infinity)
        }

        let items: [CPListItem] = sorted.prefix(10).map { mapItem in
            let name = mapItem.name ?? "Unknown"
            let dist = distanceLabel(for: mapItem)
            let address = mapItem.placemark.title ?? ""
            let detail = [dist, address].filter { !$0.isEmpty }.joined(separator: " · ")
            let item = CPListItem(text: name, detailText: detail)
            if let icon = searchResultIcon(for: mapItem) { item.setImage(icon) }
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    guard let self = self else { return }
                    await self.viewModel.addStopToRoute(mapItem)
                    self.showStopAddedConfirmation(name: name)
                }
                completion()
            }
            return item
        }

        let section = CPListSection(items: items, header: "\(results.count) found", sectionIndexTitle: nil)
        let template = CPListTemplate(title: title, sections: [section])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    /// Distance (meters) from the user's current location to a result.
    private func distanceFromUser(to mapItem: MKMapItem) -> CLLocationDistance? {
        guard let user = viewModel.locationManager.latestLocation,
              let loc = mapItem.placemark.location else { return nil }
        return user.distance(from: loc)
    }

    /// Short distance string honoring the user's unit preference
    /// (e.g. "0.4 mi" / "1.2 km" / "800 ft" / "350 m").
    private func distanceLabel(for mapItem: MKMapItem) -> String {
        guard let meters = distanceFromUser(to: mapItem) else { return "" }
        if SpeedFormatting.isMetric(SpeedFormatting.measurementSystem()) {
            return meters >= 1000
                ? String(format: "%.1f km", meters / 1000)
                : String(format: "%.0f m", meters)
        }
        let miles = meters / 1609.344
        return miles >= 0.1
            ? String(format: "%.1f mi", miles)
            : String(format: "%.0f ft", meters * 3.28084)
    }

    /// Brief confirmation after a stop is added, then back to the map.
    @MainActor
    private func showStopAddedConfirmation(name: String) {
        // Pop to root first to keep the hierarchy shallow, then present
        // the confirmation alert on the clean root map template.
        interfaceController?.popToRootTemplate(animated: false) { [weak self] success, _ in
            guard let self = self, success else { return }
            let action = CPAlertAction(title: "OK", style: .default) { _ in }
            let alert = CPAlertTemplate(
                titleVariants: ["Stop added: \(name)", "Tap + again to add more stops."],
                actions: [action]
            )
            self.interfaceController?.presentTemplate(alert, animated: true, completion: nil)
        }
    }

    @MainActor
    private func presentStopsList() {
        let items: [CPListItem] = viewModel.routeStops.enumerated().map { i, stop in
            let item = CPListItem(text: "\(i+1). \(stop.name)", detailText: stop.address ?? "")
            let sid = stop.id
            item.handler = { _, c in
                Task { @MainActor in
                    await self.viewModel.removeStopFromRoute(sid)
                    // Pop the current list instead of pushing a new one —
                    // each push without a pop was causing the CarPlay
                    // clientExceededHierarchyDepthLimit crash.
                    if self.viewModel.routeStops.isEmpty {
                        // No stops left — go all the way back to the map
                        // so the user doesn't see a stale grid.
                        self.interfaceController?.popToRootTemplate(animated: true, completion: nil)
                    } else {
                        self.interfaceController?.popTemplate(animated: true, completion: nil)
                    }
                }
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
        searchGeneration += 1
        let generation = searchGeneration
        navigationManager.searchDestination(query: searchText) { [weak self] results in
            guard let self = self else { return }
            Task { @MainActor in
                // Drop stale responses so a slow earlier query can't overwrite
                // fresher results (or let the driver tap a wrong, stale row).
                guard generation == self.searchGeneration else { return }
                self.searchItemMap.removeAll()
                let items = results.map { mi in
                    let item = CPListItem(text: mi.name, detailText: mi.placemark.title)
                    self.searchItemMap[ObjectIdentifier(item)] = mi
                    if let icon = self.searchResultIcon(for: mi) { item.setImage(icon) }
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
    func searchTemplate(_ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem, completionHandler: @escaping () -> Void) {
        let id = ObjectIdentifier(item)
        guard let mapItem = searchItemMap[id] else {
            completionHandler()
            return
        }
        // completionHandler() tells CarPlay to dismiss the search template,
        // so we must NOT call popTemplate — the search is already gone.
        completionHandler()
        Task { @MainActor in
            self.presentTripPreview(for: mapItem)
        }
    }

    // MARK: - Trip Preview

    @MainActor func showTurnByTurnList() { navigationManager.showManeuversList(interfaceController: interfaceController) }

    @MainActor
    private func presentTripPreview(for destination: MKMapItem) {
        navigationManager.calculateRoutes(to: destination) { [weak self] routes in
            Task { @MainActor in
                guard let self = self else { return }
                let choices: [CPRouteChoice]
                if routes.isEmpty {
                    choices = [CPRouteChoice(summaryVariants: [destination.name ?? "Destination"],
                                             additionalInformationVariants: [destination.placemark.title ?? ""],
                                             selectionSummaryVariants: ["Start Navigation"])]
                } else {
                    let system = SpeedFormatting.measurementSystem()
                    choices = routes.enumerated().map { index, route in
                        let eta = route.expectedTravelTime
                        let etaStr = eta >= 3600
                            ? String(format: "%d h %02d min", Int(eta) / 3600, (Int(eta) % 3600) / 60)
                            : String(format: "%d min", max(1, Int(eta) / 60))
                        let distMi = route.distance / 1609.34
                        let distStr = SpeedFormatting.isMetric(system)
                            ? String(format: "%.1f km", distMi * 1.60934)
                            : String(format: "%.1f mi", distMi)
                        let title = index == 0 ? "Fastest Route" : "Route \(index + 1)"
                        return CPRouteChoice(
                            summaryVariants: [title],
                            additionalInformationVariants: ["\(etaStr) \u{00B7} \(distStr)"],
                            selectionSummaryVariants: [title]
                        )
                    }
                }
                let trip = CPTrip(origin: MKMapItem.forCurrentLocation(), destination: destination, routeChoices: choices)
                let pt = CPTripPreviewTextConfiguration(startButtonTitle: "Start",
                    additionalRoutesButtonTitle: routes.count > 1 ? "Routes" : nil, overviewButtonTitle: "Overview")
                self.mapTemplate.showTripPreviews([trip], textConfiguration: pt)
            }
        }
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
