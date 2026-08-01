// CarPlayNamedLocationsController.swift
// =======================================
// Saved locations browser for CarPlay.
// Lets the driver browse their named locations and
// navigate to any saved place.
//
// Integration:
//   Called from CarPlayNavigationRootTemplate when the user
//   taps the saved places map button (bookmark icon).
//   Also accessible from Settings → Saved Places.

import CarPlay
import MapKit
import UIKit

@MainActor
class CarPlayNamedLocationsController {

    // MARK: - Public

    /// Push the saved places browser onto the CarPlay stack.
    func showSavedPlaces() {
        pushSavedPlacesList()
    }

    // MARK: - Private Properties

    private weak var interfaceController: CPInterfaceController?
    private let viewModel: DriveViewModel

    // MARK: - Init

    init(
        interfaceController: CPInterfaceController?,
        viewModel: DriveViewModel
    ) {
        self.interfaceController = interfaceController
        self.viewModel = viewModel
    }

    // MARK: - Saved Places List

    /// Build and push a CPListTemplate showing all named locations.
    private func pushSavedPlacesList() {
        let locations = viewModel.namedLocations

        guard !locations.isEmpty else {
            showEmptyAlert()
            return
        }

        let items: [CPListItem] = locations.map { location in
            let detailText = location.address ?? savedDateString(location.createdAt)
            let item = CPListItem(text: location.name, detailText: detailText)
            item.setImage(CarPlayUI.iconTile(systemName: "mappin.circle.fill", color: CarPlayUI.pink))

            // Navigate to this location
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.navigateToLocation(location)
                    self?.showNavigationStartedConfirmation(location.name)
                }
                completion()
            }
            return item
        }

        let section = CPListSection(
            items: items,
            header: "SAVED PLACES",
            sectionIndexTitle: nil
        )

        let template = CPListTemplate(
            title: "Saved Places",
            sections: [section]
        )
        template.emptyViewTitleVariants = ["No Saved Places"]
        template.emptyViewSubtitleVariants = ["Long-press on the map on your iPhone to save places"]

        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Navigation

    /// Start navigation to a named location.
    private func navigateToLocation(_ location: NamedLocation) {
        let coord = CLLocationCoordinate2D(
            latitude: location.latitude,
            longitude: location.longitude
        )
        let placemark = MKPlacemark(coordinate: coord)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = location.name

        // Set destination on viewModel
        Task { @MainActor in
            await viewModel.selectDestinationAndCalculateRoutes(to: mapItem)
            // Start navigation if route available
            if let firstRoute = viewModel.availableRoutes.first {
                await viewModel.startNavigation(with: firstRoute)
            }
        }
    }

    // MARK: - Confirmation

    /// Show a brief confirmation alert that navigation has started.
    private func showNavigationStartedConfirmation(_ name: String) {
        // Pop to root first to keep the hierarchy shallow, then present
        // the confirmation alert on the clean root map template.
        interfaceController?.popToRootTemplate(animated: false) { [weak self] success, _ in
            guard let self = self, success else { return }
            let action = CPAlertAction(title: "OK", style: .default) { _ in }
            let alert = CPAlertTemplate(
                titleVariants: [
                    "Navigating to \(name)",
                    "Route calculated. Follow the map for turn-by-turn directions."
                ],
                actions: [action]
            )
            self.interfaceController?.presentTemplate(alert, animated: true, completion: nil)
        }
    }

    // MARK: - Empty State

    private func showEmptyAlert() {
        let action = CPAlertAction(title: "OK", style: .default) { _ in }
        let alert = CPAlertTemplate(
            titleVariants: [
                "No Saved Places",
                "Long-press on the map on your iPhone to save a place, then it will appear here."
            ],
            actions: [action]
        )
        interfaceController?.presentTemplate(alert, animated: true, completion: nil)
    }

    // MARK: - Helpers

    private func savedDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "Saved \(formatter.string(from: date))"
    }
}
