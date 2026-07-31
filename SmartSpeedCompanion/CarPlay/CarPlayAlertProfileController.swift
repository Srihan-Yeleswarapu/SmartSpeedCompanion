// CarPlayAlertProfileController.swift
// =====================================
// Alert profile management for CarPlay.
// Lets the driver switch between saved speed buffer profiles
// and quickly adjust the alert buffer threshold.
//
// Integration:
//   Called from CarPlaySettingsController or directly from
//   the map template's settings → Alert Profile.

import CarPlay
import UIKit

@MainActor
class CarPlayAlertProfileController {

    // MARK: - Public

    /// Push the alert profile picker onto the CarPlay stack.
    func showAlertProfiles() {
        pushProfileList()
    }

    /// Push the buffer adjuster for quick threshold changes.
    func showBufferAdjuster() {
        pushBufferAdjuster()
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

    private func pushProfileList() {
        let profiles = viewModel.alertProfiles

        guard !profiles.isEmpty else {
            showNoProfilesAlert()
            return
        }

        let items: [CPListItem] = profiles.map { profile in
            let isActive = profile.isActive
            let title = isActive ? "✓ \(profile.name)" : profile.name
            let detailText = "Default: +\(profile.defaultBuffer) · Hwy: +\(profile.highwayBuffer)"

            let item = CPListItem(text: title, detailText: detailText)
            if let img = UIImage(systemName: "speedometer") { item.setImage(img) }

            if isActive {
                item.accessoryType = .cloud
            }

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
            header: "ALERT PROFILES",
            sectionIndexTitle: nil
        )

        let template = CPListTemplate(
            title: "Alert Profile",
            sections: [section]
        )
        template.emptyViewTitleVariants = ["No Alert Profiles"]
        template.emptyViewSubtitleVariants = ["Create profiles on your iPhone"]

        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Buffer Adjuster

    /// A quick +/- selector for the buffer value.
    /// Shows a grid-like list of values from -5 to +10.
    private func pushBufferAdjuster() {
        let currentBuffer = viewModel.speedEngine.userBuffer
        let system = SpeedFormatting.measurementSystem()
        let unitLong = SpeedFormatting.unitLabelLong(measurementSystem: system)
        let displayCurrent = Int(SpeedFormatting.displayBuffer(
            forMph: Double(currentBuffer),
            measurementSystem: system
        ))

        // Create items for common buffer values
        let bufferValues = [-5, -3, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 10]

        let items: [CPListItem] = bufferValues.map { value in
            let displayVal = Int(SpeedFormatting.displayBuffer(
                forMph: Double(value),
                measurementSystem: system
            ))
            let label: String
            if value == currentBuffer {
                label = "✓ \(displayVal) \(unitLong)"
            } else if displayVal > 0 {
                label = "+\(displayVal) \(unitLong)"
            } else {
                label = "\(displayVal) \(unitLong)"
            }

            let item = CPListItem(text: label, detailText: value == currentBuffer ? "Active" : nil)
            if value == currentBuffer {
                if let img = UIImage(systemName: "checkmark.circle.fill") { item.setImage(img) }
            }

            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.setBuffer(value)
                    self?.interfaceController?.popTemplate(animated: true, completion: nil)
                }
                completion()
            }
            return item
        }

        let section = CPListSection(
            items: items,
            header: "SELECT BUFFER",
            sectionIndexTitle: nil
        )

        let template = CPListTemplate(
            title: "Buffer",
            sections: [section]
        )
        template.emptyViewTitleVariants = ["Adjust Buffer"]
        template.emptyViewSubtitleVariants = ["How much over limit before alert?"]

        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Activation & Buffer Set

    private func activateProfile(_ id: UUID) {
        let context = AppDelegate.sharedModelContainer.mainContext
        viewModel.activateProfile(id, context: context)
    }

    private func setBuffer(_ value: Int) {
        viewModel.speedEngine.userBuffer = value
        UserDefaults.standard.set(Double(value), forKey: "userBuffer")
    }

    // MARK: - No Profiles Alert

    private func showNoProfilesAlert() {
        let action = CPAlertAction(title: "OK", style: .default) { _ in }
        let alert = CPAlertTemplate(
            titleVariants: [
                "No Alert Profiles",
                "Create alert profiles on your iPhone to switch between them here."
            ],
            actions: [action]
        )
        interfaceController?.presentTemplate(alert, animated: true, completion: nil)
    }
}
