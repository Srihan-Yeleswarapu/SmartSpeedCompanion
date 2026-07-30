// CarPlayDestinationController.swift — PLAN B
// ============================================
// Destination selection flow for Plan B CarPlay mode.
// Uses MKLocalSearch (runs on-device, no navigation entitlement required)
// and pushes CPListTemplates for the selection UI.
//
// Available templates (no carplay-navigation needed):
//   • CPListTemplate  — list of destinations/categories/results
//   • CPInformationTemplate — info details
//   • CPAlertTemplate — confirmation dialogs
//
// Flow:
//   1. showDestinationPicker() → CPListTemplate with Quick Categories,
//      Named Locations, and Recent Searches
//   2. User taps a category → MKLocalSearch for nearby places
//   3. Results shown in another CPListTemplate
//   4. User taps a result → sets destination on DriveViewModel, pops back

import CarPlay
import Combine
import MapKit
import UIKit

/// Manages the destination selection flow for CarPlay Plan B.
/// Uses MKLocalSearch (phone-side) to find nearby places and sets
/// the destination on the DriveViewModel.
@MainActor
class CarPlayDestinationController {

    // MARK: - Public

    /// Call this to push the destination picker onto the CarPlay stack.
    func showDestinationPicker() {
        pushPickerTemplate()
    }

    // MARK: - Private properties

    private weak var interfaceController: CPInterfaceController?
    private let viewModel: DriveViewModel
    private let onDestinationSet: () -> Void

    private var cancellables = Set<AnyCancellable>()
    private var searchGeneration: UInt64 = 0

    // (No image cache needed — UIImage(systemName:) is fast and SF Symbols
    //  are cached by the system.render cache across the app lifetime.)

    // MARK: - Init

    init(
        interfaceController: CPInterfaceController,
        viewModel: DriveViewModel,
        onDestinationSet: @escaping () -> Void
    ) {
        self.interfaceController = interfaceController
        self.viewModel = viewModel
        self.onDestinationSet = onDestinationSet
    }

    // MARK: - Quick Categories

    private struct QuickCategory {
        let name: String
        let searchQuery: String
        let sfSymbolName: String
    }

    private let quickCategories: [QuickCategory] = [
        QuickCategory(name: "Gas Station", searchQuery: "Gas station", sfSymbolName: "fuelpump.fill"),
        QuickCategory(name: "Coffee",     searchQuery: "Coffee shop",      sfSymbolName: "cup.and.saucer.fill"),
        QuickCategory(name: "Food",       searchQuery: "Restaurant",       sfSymbolName: "fork.knife"),
        QuickCategory(name: "Parking",    searchQuery: "Parking",          sfSymbolName: "p.circle.fill"),
        QuickCategory(name: "Hospital",   searchQuery: "Hospital",         sfSymbolName: "cross.fill"),
        QuickCategory(name: "EV Charger", searchQuery: "EV charging station", sfSymbolName: "bolt.fill"),
        QuickCategory(name: "Grocery",    searchQuery: "Grocery store",    sfSymbolName: "cart.fill"),
        QuickCategory(name: "Hotel",      searchQuery: "Hotel",            sfSymbolName: "bed.double.fill")
    ]

    // MARK: - Picker Template

    /// Build and push the main destination picker template.
    /// All handler wiring happens in a single pass after all items are created.
    private func pushPickerTemplate() {
        var allSections: [CPListSection] = []

        // ── Section 1: Quick Categories ───────────────────────────
        let (categorySection, categoryItems) = buildCategorySection()
        allSections.append(categorySection)

        // ── Section 2: Named Locations ────────────────────────────
        let (namedSection, namedItems, namedLocations) = buildNamedLocationsSection()
        if let section = namedSection {
            allSections.append(section)
        }

        // ── Section 3: Recent Searches ────────────────────────────
        let (recentSection, recentItems, recentQueries) = buildRecentSearchesSection()
        if let section = recentSection {
            allSections.append(section)
        }

        let template = CPListTemplate(title: "Set Destination", sections: allSections)

        // ── Wire all handlers ──────────────────────────────────────
        for (i, category) in quickCategories.enumerated() {
            guard i < categoryItems.count else { break }
            categoryItems[i].handler = { [weak self] _, completion in
                self?.searchCategory(category)
                completion()
            }
        }

        for (i, location) in namedLocations.enumerated() {
            guard i < namedItems.count else { break }
            namedItems[i].handler = { [weak self] _, completion in
                self?.selectNamedLocation(location)
                completion()
            }
        }

        for (i, query) in recentQueries.enumerated() {
            guard i < recentItems.count else { break }
            recentItems[i].handler = { [weak self] _, completion in
                self?.searchForQuery(query)
                completion()
            }
        }

        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Section Builders

    private func buildCategorySection() -> (CPListSection, [CPListItem]) {
        var items: [CPListItem] = []
        for category in quickCategories {
            let item = CPListItem(text: category.name, detailText: "Search nearby")
            if let image = UIImage(systemName: category.sfSymbolName) {
                item.setImage(image)
            }
            items.append(item)
        }
        let section = CPListSection(
            items: items,
            header: "QUICK DESTINATIONS",
            sectionIndexTitle: nil
        )
        return (section, items)
    }

    private func buildNamedLocationsSection() -> (CPListSection?, [CPListItem], [NamedLocation]) {
        let locations = viewModel.namedLocations
        guard !locations.isEmpty else { return (nil, [], []) }

        var items: [CPListItem] = []
        for location in locations {
            let item = CPListItem(text: location.name, detailText: "Saved location")
            if let image = UIImage(systemName: "house.fill") {
                item.setImage(image)
            }
            items.append(item)
        }
        let section = CPListSection(
            items: items,
            header: "MY PLACES",
            sectionIndexTitle: nil
        )
        return (section, items, locations)
    }

    private func buildRecentSearchesSection() -> (CPListSection?, [CPListItem], [String]) {
        let searches = Array(viewModel.recentSearches.prefix(5))
        guard !searches.isEmpty else { return (nil, [], []) }

        var items: [CPListItem] = []
        for query in searches {
            let item = CPListItem(text: query, detailText: "Recent search")
            if let image = UIImage(systemName: "clock.arrow.circlepath") {
                item.setImage(image)
            }
            items.append(item)
        }
        let section = CPListSection(
            items: items,
            header: "RECENT",
            sectionIndexTitle: nil
        )
        return (section, items, searches)
    }

    // MARK: - Category Search

    /// Perform MKLocalSearch for a category and show results.
    private func searchCategory(_ category: QuickCategory) {
        let generation = searchGeneration + 1
        searchGeneration = generation

        pushLoadingTemplate(title: category.name)

        Task { [weak self] in
            guard let self = self else { return }
            let items = await self.performLocalSearch(category.searchQuery)
            guard generation == self.searchGeneration else { return }
            self.interfaceController?.popTemplate(animated: false, completion: nil)
            self.pushResultsTemplate(items: items, title: category.name)
        }
    }

    // MARK: - Query Search

    /// Search for a specific query string (from recent searches).
    private func searchForQuery(_ query: String) {
        let generation = searchGeneration + 1
        searchGeneration = generation

        pushLoadingTemplate(title: query)

        Task { [weak self] in
            guard let self = self else { return }
            let items = await self.performLocalSearch(query)
            guard generation == self.searchGeneration else { return }
            self.interfaceController?.popTemplate(animated: false, completion: nil)
            self.pushResultsTemplate(items: items, title: query)
        }
    }

    // MARK: - Named Location Selection

    /// Select a saved named location as the destination.
    private func selectNamedLocation(_ location: NamedLocation) {
        let coord = CLLocationCoordinate2D(
            latitude: location.latitude,
            longitude: location.longitude
        )
        let placemark = MKPlacemark(coordinate: coord)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = location.name
        setDestination(mapItem)
    }

    // MARK: - Loading Template

    /// Push a temporary "Searching..." template so the user has feedback.
    private func pushLoadingTemplate(title: String) {
        let loadingItem = CPListItem(text: "Searching...", detailText: title)
        loadingItem.isEnabled = false
        let loadingSection = CPListSection(
            items: [loadingItem],
            header: "SEARCHING",
            sectionIndexTitle: nil
        )
        let loadingTemplate = CPListTemplate(title: title, sections: [loadingSection])
        interfaceController?.pushTemplate(loadingTemplate, animated: true, completion: nil)
    }

    // MARK: - Results Template

    /// Push a CPListTemplate showing MKLocalSearch results.
    private func pushResultsTemplate(items: [MKMapItem], title: String) {
        guard !items.isEmpty else {
            let noResults = CPListItem(text: "No Results", detailText: "Try a different category")
            noResults.isEnabled = false
            let section = CPListSection(
                items: [noResults],
                header: nil,
                sectionIndexTitle: nil
            )
            let template = CPListTemplate(title: title, sections: [section])
            interfaceController?.pushTemplate(template, animated: true, completion: nil)
            return
        }

        // Build list items for the first 10 results
        let displayItems = Array(items.prefix(10))
        var listItems: [CPListItem] = []

        for mapItem in displayItems {
            let name = mapItem.name ?? "Unknown"
            let address = Self.compactAddress(for: mapItem)
            let listItem = CPListItem(text: name, detailText: address)
            if let image = UIImage(systemName: "mappin.circle.fill") {
                listItem.setImage(image)
            }
            listItems.append(listItem)
        }

        let resultHeader = items.count == 1 ? "1 found" : "\(items.count) found"
        let section = CPListSection(
            items: listItems,
            header: resultHeader,
            sectionIndexTitle: nil
        )
        let template = CPListTemplate(title: title, sections: [section])

        // Wire handlers
        for (i, mapItem) in displayItems.enumerated() {
            guard i < listItems.count else { break }
            listItems[i].handler = { [weak self] _, completion in
                self?.setDestination(mapItem)
                completion()
            }
        }

        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Set Destination

    /// Set the selected destination on DriveViewModel, show a brief confirmation,
    /// then dismiss the alert and pop back to root.
    private func setDestination(_ item: MKMapItem) {
        let destName = item.name ?? "Destination"

        Task { @MainActor in
            await viewModel.selectDestinationAndCalculateRoutes(to: item)
            onDestinationSet()

            // ── Show confirmation alert ───────────────────────────────
            // CPAlertTemplate is presented modally via presentTemplate.
            // The action handler MUST dismiss the alert first, then pop
            // the navigation stack — calling popToRootTemplate while the
            // alert is still presented would leave the alert visible on
            // top of whatever the stack unwound to.
            let confirmAction = CPAlertAction(
                title: "OK",
                style: .default
            ) { [weak self] _ in
                self?.interfaceController?.dismissTemplate(
                    animated: true
                ) { _, _ in
                    self?.interfaceController?.popToRootTemplate(
                        animated: true,
                        completion: nil
                    )
                }
            }
            let confirmAlert = CPAlertTemplate(
                titleVariants: ["Destination set to \(destName)"],
                actions: [confirmAction]
            )
            self.interfaceController?.presentTemplate(
                confirmAlert,
                animated: true,
                completion: nil
            )
        }
    }

    // MARK: - MKLocalSearch

    /// Perform an MKLocalSearch for the given query, centered near the user.
    private func performLocalSearch(_ query: String) async -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]

        if let location = viewModel.locationManager.latestLocation {
            request.region = MKCoordinateRegion(
                center: location.coordinate,
                latitudinalMeters: 50000,
                longitudinalMeters: 50000
            )
        }

        let search = MKLocalSearch(request: request)
        do {
            let response = try await search.start()
            return response.mapItems
        } catch {
            DebugLogger.shared.log("CarPlay destination search failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Address Formatting

    /// Returns a short address string (City, State) for display in search results.
    private static func compactAddress(for item: MKMapItem) -> String {
        let p = item.placemark
        if let city = p.locality, let state = p.administrativeArea {
            return "\(city), \(state)"
        }
        if let city = p.locality {
            return city
        }
        if let title = p.title {
            let parts = title.components(separatedBy: ",")
            if parts.count >= 2 {
                return parts.dropFirst()
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: ", ")
            }
        }
        return ""
    }
}
