// CarPlayVehicleProfileController.swift
// =======================================
// Vehicle profile management for CarPlay.
// Lets the driver switch between saved vehicle profiles,
// view per-vehicle stats, and see which one is active.
//
// Integration:
//   Called from CarPlayNavigationRootTemplate when the user
//   taps the settings button → Settings → Vehicle Profile.
//   Also callable directly from a dedicated map button.

import CarPlay
import UIKit

@MainActor
class CarPlayVehicleProfileController {

    // MARK: - Public

    /// Push the vehicle profile picker onto the CarPlay stack.
    func showVehicleProfiles() {
        pushProfileList()
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

    // MARK: - Profile List

    /// Build and push the vehicle profile list template.
    /// Shows all saved profiles with the active one marked.
    private func pushProfileList() {
        let profiles = viewModel.vehicleProfiles

        guard !profiles.isEmpty else {
            showNoProfilesAlert()
            return
        }

        let items: [CPListItem] = profiles.map { profile in
            let isActive = profile.isActive
            let title = isActive ? "✓ \(profile.name)" : profile.name

            // Stats string
            let tripsStr = "\(profile.totalTrips) trips"
            let distStr = String(format: "%.0f mi", profile.totalDistanceMiles)
            let detailText = "\(tripsStr) · \(distStr) · \(profile.measurementSystem)"

            let item = CPListItem(text: title, detailText: detailText)
            item.setImage(CarPlayUI.iconTile(systemName: "car.fill", color: CarPlayUI.blue))

            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.activateProfile(profile.id)
                    self?.interfaceController?.popTemplate(animated: true, completion: nil)
                }
                completion()
            }
            return item
        }

        let section = CPListSection(
            items: items,
            header: "VEHICLE PROFILES",
            sectionIndexTitle: nil
        )

        let template = CPListTemplate(
            title: "Vehicle",
            sections: [section]
        )
        template.emptyViewTitleVariants = ["No Vehicle Profiles"]
        template.emptyViewSubtitleVariants = ["Create profiles on your iPhone"]

        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Activation

    private func activateProfile(_ id: UUID) {
        let context = AppDelegate.sharedModelContainer.mainContext
        viewModel.activateVehicleProfile(id, context: context)
    }

    // MARK: - No Profiles Alert

    private func showNoProfilesAlert() {
        let action = CPAlertAction(title: "OK", style: .default) { _ in }
        let alert = CPAlertTemplate(
            titleVariants: [
                "No Vehicle Profiles",
                "Create vehicle profiles on your iPhone to switch between them here."
            ],
            actions: [action]
        )
        interfaceController?.presentTemplate(alert, animated: true, completion: nil)
    }
}
