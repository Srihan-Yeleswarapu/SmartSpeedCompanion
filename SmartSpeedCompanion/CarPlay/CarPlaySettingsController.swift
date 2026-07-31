// CarPlaySettingsController.swift
// =================================
// Comprehensive settings experience for CarPlay.
// Adapts the iOS Settings view for the driving context:
//   • Vehicle Profiles — switch active vehicle
//   • Alert Profiles — switch active alert profile
//   • Units — toggle Imperial/Metric
//   • Audio & Navigation — voice/mute toggles
//   • Map Style — choose map appearance
//   • Saved Places — browse named locations
//   • Offline Regions — view saved offline areas
//   • About — app version info
//
// All interactions use safe, big-button CarPlay templates
// (CPListTemplate, CPInformationTemplate, CPGridTemplate).

import CarPlay
import UIKit

@MainActor
class CarPlaySettingsController {

    // MARK: - Public

    /// Push the main settings menu onto the CarPlay stack.
    func showSettings() {
        pushMainSettingsTemplate()
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

    // MARK: - Main Settings Menu

    /// The root settings menu — a multi-section CPListTemplate.
    /// Each row pushes a sub-template for its category.
    private func pushMainSettingsTemplate() {
        let system = SpeedFormatting.measurementSystem()
        let unitLabel = SpeedFormatting.isMetric(system) ? "KMH" : "MPH"

        // Get active profile names
        let activeVehicle = viewModel.vehicleProfiles.first(where: { $0.isActive })?.name ?? "Primary"
        let activeAlertProfile = viewModel.alertProfiles.first(where: { $0.isActive })?.name ?? "Default"

        // ── Section 1: Profiles ─────────────────────────────────
        let vehicleItem = CPListItem(
            text: "Vehicle Profile",
            detailText: activeVehicle
        )
        vehicleItem.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.pushVehicleProfilePicker()
            }
            completion()
        }
        if let img = UIImage(systemName: "car.fill") { vehicleItem.setImage(img) }

        let alertItem = CPListItem(
            text: "Alert Profile",
            detailText: activeAlertProfile
        )
        alertItem.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.pushAlertProfilePicker()
            }
            completion()
        }
        if let img = UIImage(systemName: "speedometer") { alertItem.setImage(img) }

        let bufferItem = CPListItem(
            text: "Alert Buffer",
            detailText: "+\(viewModel.speedEngine.userBuffer)"
        )
        bufferItem.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.pushBufferAdjuster()
            }
            completion()
        }
        if let img = UIImage(systemName: "slider.horizontal.3") { bufferItem.setImage(img) }

        let profileSection = CPListSection(
            items: [vehicleItem, alertItem, bufferItem],
            header: "PROFILES"
        )

        // ── Section 2: Units & Navigation ───────────────────────
        let unitsItem = CPListItem(
            text: "Units",
            detailText: unitLabel
        )
        unitsItem.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.pushUnitsPicker()
            }
            completion()
        }
        if let img = UIImage(systemName: "ruler") { unitsItem.setImage(img) }

        let voiceItem = CPListItem(
            text: "Voice Navigation",
            detailText: UserDefaults.standard.bool(forKey: "voiceNavEnabled") ? "On" : "Off"
        )
        voiceItem.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.toggleVoiceNavigation()
            }
            completion()
        }
        if let img = UIImage(systemName: "waveform") { voiceItem.setImage(img) }

        let avoidItem = CPListItem(
            text: "Avoid Highways",
            detailText: UserDefaults.standard.bool(forKey: "avoidHighways") ? "On" : "Off"
        )
        avoidItem.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.toggleAvoidHighways()
            }
            completion()
        }
        if let img = UIImage(systemName: "road.lanes") { avoidItem.setImage(img) }

        let navSection = CPListSection(
            items: [unitsItem, voiceItem, avoidItem],
            header: "UNITS & NAVIGATION"
        )

        // ── Section 3: Map ───────────────────────────────────────
        let mapStyleItem = CPListItem(
            text: "Map Style",
            detailText: viewModel.mapStyle.displayName
        )
        mapStyleItem.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.pushMapStylePicker()
            }
            completion()
        }
        if let img = UIImage(systemName: "map.fill") { mapStyleItem.setImage(img) }

        let poiItem = CPListItem(
            text: "Show POIs",
            detailText: viewModel.showApplePOIs ? "On" : "Off"
        )
        poiItem.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.togglePOIs()
            }
            completion()
        }
        if let img = UIImage(systemName: "mappin.and.ellipse") { poiItem.setImage(img) }

        let mapSection = CPListSection(
            items: [mapStyleItem, poiItem],
            header: "MAP"
        )

        // ── Section 4: Places ───────────────────────────────────
        let placesItem = CPListItem(
            text: "Saved Places",
            detailText: "\(viewModel.namedLocations.count) saved"
        )
        placesItem.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.pushSavedPlaces()
            }
            completion()
        }
        if let img = UIImage(systemName: "bookmark.fill") { placesItem.setImage(img) }

        let offlineItem = CPListItem(
            text: "Offline Regions",
            detailText: "\(viewModel.savedOfflineRegions.count) saved"
        )
        offlineItem.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.pushOfflineRegions()
            }
            completion()
        }
        if let img = UIImage(systemName: "square.and.arrow.down") { offlineItem.setImage(img) }

        let placesSection = CPListSection(
            items: [placesItem, offlineItem],
            header: "PLACES & DATA"
        )

        // ── Section 5: About ────────────────────────────────────
        let aboutItem = CPListItem(
            text: "About",
            detailText: "Speedio v\(appVersion())"
        )
        aboutItem.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.pushAboutInfo()
            }
            completion()
        }
        if let img = UIImage(systemName: "info.circle.fill") { aboutItem.setImage(img) }

        let aboutSection = CPListSection(
            items: [aboutItem],
            header: "ABOUT"
        )

        let template = CPListTemplate(
            title: "Settings",
            sections: [profileSection, navSection, mapSection, placesSection, aboutSection]
        )

        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Vehicle Profiles

    private func pushVehicleProfilePicker() {
        guard !viewModel.vehicleProfiles.isEmpty else {
            showNoItemsAlert(title: "No Vehicle Profiles", message: "Create one on your iPhone.")
            return
        }

        let items: [CPListItem] = viewModel.vehicleProfiles.map { profile in
            let isActive = profile.isActive
            let label = isActive ? "✓ \(profile.name)" : profile.name
            let item = CPListItem(text: label, detailText: profile.measurementSystem)
            if let img = UIImage(systemName: "car.fill") { item.setImage(img) }
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.activateVehicleProfile(profile.id)
                    self?.interfaceController?.popTemplate(animated: true, completion: nil)
                }
                completion()
            }
            return item
        }

        let section = CPListSection(items: items, header: "SELECT VEHICLE")
        let template = CPListTemplate(title: "Vehicle Profile", sections: [section])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func activateVehicleProfile(_ id: UUID) {
        let context = AppDelegate.sharedModelContainer.mainContext
        viewModel.activateVehicleProfile(id, context: context)
    }

    // MARK: - Alert Profiles

    private func pushAlertProfilePicker() {
        guard !viewModel.alertProfiles.isEmpty else {
            showNoItemsAlert(title: "No Alert Profiles", message: "Create one on your iPhone.")
            return
        }

        let items: [CPListItem] = viewModel.alertProfiles.map { profile in
            let isActive = profile.isActive
            let label = isActive ? "✓ \(profile.name)" : profile.name
            let item = CPListItem(
                text: label,
                detailText: "Buffer: +\(profile.defaultBuffer)"
            )
            if let img = UIImage(systemName: "speedometer") { item.setImage(img) }
            if isActive {
                item.accessoryType = .cloud
            }
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.activateAlertProfile(profile.id)
                    self?.interfaceController?.popTemplate(animated: true, completion: nil)
                }
                completion()
            }
            return item
        }

        let section = CPListSection(items: items, header: "SELECT ALERT PROFILE")
        let template = CPListTemplate(title: "Alert Profile", sections: [section])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func activateAlertProfile(_ id: UUID) {
        let context = AppDelegate.sharedModelContainer.mainContext
        viewModel.activateProfile(id, context: context)
    }

    // MARK: - Buffer Adjuster

    /// Simple +/- picker for the speed alert buffer value.
    private func pushBufferAdjuster() {
        let currentBuffer = viewModel.speedEngine.userBuffer

        let items: [CPListItem] = (-5...10).map { value in
            let label: String
            if value == currentBuffer {
                label = "✓ +\(value)"
            } else if value < 0 {
                label = "\(value)"
            } else {
                label = "+\(value)"
            }
            let item = CPListItem(text: label, detailText: value == currentBuffer ? "Current" : nil)
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.setBuffer(value)
                    self?.interfaceController?.popTemplate(animated: true, completion: nil)
                }
                completion()
            }
            return item
        }

        let section = CPListSection(items: items, header: "SELECT BUFFER")
        let template = CPListTemplate(title: "Alert Buffer", sections: [section])
        template.emptyViewTitleVariants = ["Adjust Buffer"]
        template.emptyViewSubtitleVariants = ["How much over the limit before alerting?"]
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func setBuffer(_ value: Int) {
        viewModel.speedEngine.userBuffer = value
        UserDefaults.standard.set(Double(value), forKey: "userBuffer")
    }

    // MARK: - Units Picker

    private func pushUnitsPicker() {
        let current = SpeedFormatting.measurementSystem()

        let imperialItem = CPListItem(
            text: current == "Imperial" ? "✓ Imperial (MPH)" : "Imperial (MPH)",
            detailText: "mph, mi"
        )
        imperialItem.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.setUnits("Imperial")
                self?.interfaceController?.popTemplate(animated: true, completion: nil)
            }
            completion()
        }

        let metricItem = CPListItem(
            text: current == "Metric" ? "✓ Metric (KMH)" : "Metric (KMH)",
            detailText: "km/h, km"
        )
        metricItem.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.setUnits("Metric")
                self?.interfaceController?.popTemplate(animated: true, completion: nil)
            }
            completion()
        }

        let section = CPListSection(items: [imperialItem, metricItem], header: "SELECT UNITS")
        let template = CPListTemplate(title: "Units", sections: [section])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func setUnits(_ system: String) {
        UserDefaults.standard.set(system, forKey: "measurementSystem")
        SpeedFormatting.writeMeasurementSystemToAppGroup(system)
        viewModel.speedEngine.measurementSystem = system
    }

    // MARK: - Toggles

    private func toggleVoiceNavigation() {
        let current = UserDefaults.standard.bool(forKey: "voiceNavEnabled")
        UserDefaults.standard.set(!current, forKey: "voiceNavEnabled")
        // Pop back to refresh the settings list
        interfaceController?.popTemplate(animated: true, completion: nil)
    }

    private func toggleAvoidHighways() {
        let current = UserDefaults.standard.bool(forKey: "avoidHighways")
        UserDefaults.standard.set(!current, forKey: "avoidHighways")
        interfaceController?.popTemplate(animated: true, completion: nil)
    }

    private func togglePOIs() {
        viewModel.showApplePOIs.toggle()
        interfaceController?.popTemplate(animated: true, completion: nil)
    }

    // MARK: - Map Style Picker

    private func pushMapStylePicker() {
        let current = viewModel.mapStyle

        let styles: [(DriveViewModel.MapStyleChoice, String)] = [
            (.mutedDark, "Muted (Dark)"),
            (.standard, "Standard"),
            (.satellite, "Satellite"),
            (.hybridFlyover, "Hybrid 3D")
        ]

        let items: [CPListItem] = styles.map { (style, name) in
            let label = style == current ? "✓ \(name)" : name
            let item = CPListItem(text: label, detailText: nil)
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.setMapStyle(style)
                    self?.interfaceController?.popTemplate(animated: true, completion: nil)
                }
                completion()
            }
            return item
        }

        let section = CPListSection(items: items, header: "MAP STYLE")
        let template = CPListTemplate(title: "Map Style", sections: [section])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func setMapStyle(_ style: DriveViewModel.MapStyleChoice) {
        viewModel.mapStyle = style
    }

    // MARK: - Saved Places

    private func pushSavedPlaces() {
        guard !viewModel.namedLocations.isEmpty else {
            showNoItemsAlert(title: "No Saved Places", message: "Save places on your iPhone.")
            return
        }

        let items: [CPListItem] = viewModel.namedLocations.map { location in
            let item = CPListItem(
                text: location.name,
                detailText: location.address ?? "Saved location"
            )
            if let img = UIImage(systemName: "mappin.circle.fill") { item.setImage(img) }
            return item
        }

        let section = CPListSection(items: items, header: "SAVED PLACES")
        let template = CPListTemplate(title: "Saved Places", sections: [section])
        template.emptyViewTitleVariants = ["No Saved Places"]
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Offline Regions

    private func pushOfflineRegions() {
        guard !viewModel.savedOfflineRegions.isEmpty else {
            showNoItemsAlert(title: "No Offline Regions", message: "Download regions on your iPhone.")
            return
        }

        let items: [CPListItem] = viewModel.savedOfflineRegions.map { region in
            let sizeStr = String(format: "%.0f MB", region.estimatedSizeMB)
            let item = CPListItem(
                text: region.label,
                detailText: sizeStr
            )
            if let img = UIImage(systemName: "square.and.arrow.down.fill") { item.setImage(img) }
            return item
        }

        let section = CPListSection(items: items, header: "OFFLINE REGIONS")
        let template = CPListTemplate(title: "Offline Regions", sections: [section])
        template.emptyViewTitleVariants = ["No Offline Regions"]
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - About

    private func pushAboutInfo() {
        let items: [CPInformationItem] = [
            CPInformationItem(title: "App", detail: "Speedio"),
            CPInformationItem(title: "Version", detail: appVersion()),
            CPInformationItem(title: "Build", detail: buildNumber()),
            CPInformationItem(title: "Speed Source", detail: viewModel.speedLimitSource)
        ]

        let template = CPInformationTemplate(
            title: "About",
            layout: .twoColumn,
            items: items,
            actions: [CPTextButton(title: "Dismiss", textStyle: .cancel, handler: { [weak self] _ in
                self?.interfaceController?.popTemplate(animated: true, completion: nil)
            })]
        )

        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Helpers

    private func showNoItemsAlert(title: String, message: String) {
        let action = CPAlertAction(title: "OK", style: .default) { _ in }
        let alert = CPAlertTemplate(titleVariants: [title, message], actions: [action])
        interfaceController?.presentTemplate(alert, animated: true, completion: nil)
    }

    private func appVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private func buildNumber() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
}
