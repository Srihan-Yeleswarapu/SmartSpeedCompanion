// CarPlayListSpeedController.swift — PLAN B
// ==========================================
// Focus-mode-inspired speed dashboard for CarPlay.
// Works with ONLY the `carplay-driving-task` entitlement.
// No CPMapTemplate, no CPNavigationSession, no MapKit.
//
// Layout:
//   NavBar: [Speedio]        [📍 Dest]
//   ─────────────────────────────────────────────────
//   CURRENT SPEED
//     [●] 65 mph             ← colored status circle + speed
//     Status: ✔ SAFE         ← status indicator
//     Speed Limit: 55 mph    ← limit info
//     Current Road: I-280 S  ← road name
//   ─────────────────────────────────────────────────
//   SESSION
//     ▶ START DRIVE / ■ END DRIVE
//   ─────────────────────────────────────────────────
//   DRIVE INFO (shown when recording)
//     Duration: 12 min
//     Top Speed: 68 mph
//   ─────────────────────────────────────────────────
//   ACTIONS
//     📋 Safety Report
//     📍 Set Destination
//
// IMPORTANT: After init, the caller MUST call start() to set up
// item handlers and begin the display update timer. This two-phase
// init avoids Swift compiler errors about "self used before all
// stored properties are initialized" inside closures.

import CarPlay
import Combine
import UIKit

/// Rich focus-mode-inspired speed dashboard for Plan B CarPlay mode.
/// Displays current speed, limit, status, road name, session controls,
/// drive info, and destination setting — all within a CPListTemplate
/// hierarchy that works with only the `carplay-driving-task` entitlement.
@MainActor
class CarPlayListSpeedController {

    // MARK: - Public

    /// The root list template displayed in CarPlay.
    let listTemplate: CPListTemplate

    /// Call this after init to set up handlers and begin updates.
    func start() {
        setupItemHandlers()
        setupNavBarButtons()
        bindViewModel()
    }

    // MARK: - Private properties

    private weak var interfaceController: CPInterfaceController?
    private let viewModel: DriveViewModel
    private var cancellables = Set<AnyCancellable>()

    /// Top speed observed during the current recording session (in display units).
    private var sessionTopSpeed: Double = 0

    /// Whether a destination is currently set. Updates the destination item detail.
    private var hasDestination: Bool = false

    // ── Destination controller (lazy, created on first use) ─────────
    private lazy var destinationController: CarPlayDestinationController? = {
        guard let interface = self.interfaceController else { return nil }
        return CarPlayDestinationController(
            interfaceController: interface,
            viewModel: self.viewModel,
            onDestinationSet: { [weak self] in
                self?.hasDestination = true
                self?.updateDestinationItem()
            }
        )
    }()

    // ── Mutable list items (updated in-place) ──────────────────────

    // CURRENT SPEED section
    private let speedItem: CPListItem
    private let statusItem: CPListItem
    private let limitItem: CPListItem
    private let roadNameItem: CPListItem

    // SESSION section
    private let sessionItem: CPListItem

    // DRIVE INFO section (shown/hidden based on recording state)
    private let durationItem: CPListItem
    private let topSpeedItem: CPListItem
    private var driveInfoSection: CPListSection?

    // ACTIONS section
    private let safetyItem: CPListItem
    private let destinationItem: CPListItem

    // MARK: - Init

    init(interfaceController: CPInterfaceController, viewModel: DriveViewModel) {
        self.interfaceController = interfaceController
        self.viewModel = viewModel

        let system = SpeedFormatting.measurementSystem()
        let unitShort = SpeedFormatting.unitLabelShort(measurementSystem: system)

        // ── Create all items with initial placeholders ────────────
        // NOTE: Item handlers are NOT set here because closures would
        // capture `self` before `listTemplate` is initialized below.
        // Handlers are wired in `start()` → `setupItemHandlers()`.

        // CURRENT SPEED section — the "focus mode" display
        speedItem = CPListItem(text: "--", detailText: unitShort)
        speedItem.isEnabled = false

        statusItem = CPListItem(text: "Status", detailText: "SAFE")
        statusItem.isEnabled = false

        limitItem = CPListItem(text: "Speed Limit", detailText: "--")
        limitItem.isEnabled = false

        roadNameItem = CPListItem(text: "Current Road", detailText: "--")
        roadNameItem.isEnabled = false

        // SESSION section
        sessionItem = CPListItem(
            text: "▶ START DRIVE",
            detailText: "Tap to begin recording"
        )

        // DRIVE INFO section (hidden initially)
        durationItem = CPListItem(text: "Duration", detailText: "0 min")
        durationItem.isEnabled = false

        topSpeedItem = CPListItem(text: "Top Speed", detailText: "0 \(unitShort)")
        topSpeedItem.isEnabled = false

        // ACTIONS section
        safetyItem = CPListItem(
            text: "Safety Report",
            detailText: "View drive statistics"
        )

        destinationItem = CPListItem(
            text: "Set Destination",
            detailText: "Choose a destination"
        )

        // ── Build initial sections ─────────────────────────────────

        let speedSection = CPListSection(
            items: [speedItem, statusItem, limitItem, roadNameItem],
            header: "CURRENT SPEED",
            sectionIndexTitle: nil
        )
        let sessionSection = CPListSection(
            items: [sessionItem],
            header: "SESSION",
            sectionIndexTitle: nil
        )
        let actionsSection = CPListSection(
            items: [safetyItem, destinationItem],
            header: "ACTIONS",
            sectionIndexTitle: nil
        )

        listTemplate = CPListTemplate(
            title: "Speedio",
            sections: [speedSection, sessionSection, actionsSection]
        )

        self.driveInfoSection = nil
    }

    // MARK: - Item Handlers (deferred from init)

    /// Wire tap handlers for interactive items. Called from `start()`.
    private func setupItemHandlers() {
        sessionItem.handler = { [weak self] _, completion in
            self?.handleSessionToggle()
            completion()
        }

        safetyItem.handler = { [weak self] _, completion in
            self?.presentSafetyReport()
            completion()
        }

        destinationItem.handler = { [weak self] _, completion in
            self?.destinationController?.showDestinationPicker()
            completion()
        }
    }

    // MARK: - Navigation Bar Buttons

    /// Set trailing navigation bar button for destination access.
    private func setupNavBarButtons() {
        let mapPinImage = UIImage(systemName: "mappin.and.ellipse")
        let destButton: CPBarButton
        if let image = mapPinImage {
            destButton = CPBarButton(image: image) { [weak self] _ in
                self?.destinationController?.showDestinationPicker()
            }
        } else {
            // Fallback to text button if SF Symbol is unavailable
            destButton = CPBarButton(title: "Dest") { [weak self] _ in
                self?.destinationController?.showDestinationPicker()
            }
        }

        listTemplate.trailingNavigationBarButtons = [destButton]
    }

    // MARK: - View Model Binding

    /// Start a 500 ms timer that reads current ViewModel values and
    /// updates the display. Called from `start()`.
    private func bindViewModel() {
        Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateDisplay(
                    speed: self.viewModel.speed,
                    limit: self.viewModel.limit,
                    status: self.viewModel.status,
                    isRecording: self.viewModel.isRecording,
                    duration: self.viewModel.sessionDuration,
                    roadName: self.viewModel.currentRoadName
                )
            }
            .store(in: &cancellables)
    }

    // MARK: - Display Updates

    /// Update all mutable list items in-place from the latest view model state.
    private func updateDisplay(
        speed: Double,
        limit: Int,
        status: SpeedStatus,
        isRecording: Bool,
        duration: TimeInterval,
        roadName: String?
    ) {
        let system = SpeedFormatting.measurementSystem()
        let unitShort = SpeedFormatting.unitLabelShort(measurementSystem: system)
        let displayLimit = SpeedFormatting.displayLimit(forMph: limit, measurementSystem: system)

        // ── Track top speed during session ────────────────────────
        if isRecording && speed > sessionTopSpeed {
            sessionTopSpeed = speed
        }
        if !isRecording {
            sessionTopSpeed = 0
        }

        let circleColor = Self.colorForStatus(status)

        // ── Speed item (hero display) ─────────────────────────────
        let speedInt = Int(speed)
        speedItem.setText("\\(speedInt)")
        speedItem.setDetailText(unitShort)
        speedItem.setImage(Self.statusCircleImage(color: circleColor, size: 40))

        // ── Status item ───────────────────────────────────────────
        let statusLabel: String
        let statusPrefix: String
        switch status {
        case .over:
            statusLabel = "⚠ OVERSPEED"
            statusPrefix = "⚠ "
        case .warning:
            statusLabel = "⚠ WARNING"
            statusPrefix = "⚠ "
        case .safe:
            statusLabel = "✔ SAFE"
            statusPrefix = "✔ "
        }
        statusItem.setDetailText(statusLabel)

        // ── Limit item ────────────────────────────────────────────
        if limit > 0 {
            limitItem.setDetailText("\\(displayLimit) \\(unitShort)")
        } else {
            limitItem.setDetailText("--")
        }

        // ── Road name item ────────────────────────────────────────
        if let name = roadName, !name.isEmpty {
            roadNameItem.setDetailText(name)
        } else {
            roadNameItem.setDetailText("--")
        }

        // ── Session toggle item ───────────────────────────────────
        if isRecording {
            sessionItem.setText("■ END DRIVE")
            sessionItem.setDetailText("Tap to stop recording")
        } else {
            sessionItem.setText("▶ START DRIVE")
            sessionItem.setDetailText("Tap to begin recording")
        }

        // ── Drive-info section (show/hide) ────────────────────────
        if isRecording && driveInfoSection == nil {
            // Insert the drive-info section after the session section (index 1)
            let mins = Int(duration / 60)
            durationItem.setDetailText("\\(mins) min")
            topSpeedItem.setDetailText("\\(Int(sessionTopSpeed)) \\(unitShort)")

            let section = CPListSection(
                items: [durationItem, topSpeedItem],
                header: "DRIVE INFO",
                sectionIndexTitle: nil
            )
            driveInfoSection = section

            var current = listTemplate.sections
            if current.count >= 2 {
                current.insert(section, at: 2)
            } else {
                current.append(section)
            }
            listTemplate.updateSections(current)

        } else if isRecording && driveInfoSection != nil {
            // Update existing drive-info items
            let mins = Int(duration / 60)
            durationItem.setDetailText("\\(mins) min")
            topSpeedItem.setDetailText("\\(Int(sessionTopSpeed)) \\(unitShort)")

        } else if !isRecording && driveInfoSection != nil {
            // Remove the drive-info section
            driveInfoSection = nil
            var current = listTemplate.sections
            current.removeAll { section in
                section.header == "DRIVE INFO"
            }
            listTemplate.updateSections(current)
        }
    }

    // MARK: - Destination Item Update

    /// Update the destination item's detail text when a destination is set.
    private func updateDestinationItem() {
        if let dest = viewModel.destination {
            let name = dest.name ?? "Destination"
            destinationItem.setDetailText(name)
        } else {
            destinationItem.setDetailText("Choose a destination")
        }
    }

    // MARK: - Session Toggle

    private func handleSessionToggle() {
        if viewModel.isRecording {
            viewModel.endSession()
        } else {
            viewModel.startSession()
        }
    }

    // MARK: - Safety Report

    @MainActor
    private func presentSafetyReport() {
        let system = SpeedFormatting.measurementSystem()
        let unitShort = SpeedFormatting.unitLabelShort(measurementSystem: system)

        let items = [
            CPInformationItem(title: "Current Speed", detail: "\\(Int(viewModel.speed)) \\(unitShort)"),
            CPInformationItem(title: "Drive Time", detail: "\\(Int(viewModel.sessionDuration / 60)) min"),
            CPInformationItem(
                title: "Status",
                detail: viewModel.status.rawValue.uppercased()
            ),
            // Production: hide the speed-limit source line from CarPlay so
            // end users don't see provider names. The underlying data flow
            // (DriveViewModel.speedLimitSource / SpeedLimitService) is unchanged.
            // CPInformationItem(
            //     title: "Speed Limit Source",
            //     detail: viewModel.speedLimitSource
            // ),
            CPInformationItem(
                title: "Current Road",
                detail: viewModel.currentRoadName ?? "Unknown"
            )
        ]

        let report = CPInformationTemplate(
            title: "Safety Report",
            layout: .twoColumn,
            items: items,
            actions: [
                CPTextButton(
                    title: "Dismiss",
                    textStyle: .cancel,
                    handler: { [weak self] _ in
                        self?.interfaceController?.popTemplate(animated: true, completion: nil)
                    }
                )
            ]
        )

        interfaceController?.pushTemplate(report, animated: true, completion: nil)
    }

    // MARK: - Status Color

    /// Returns the display color for a given speed status.
    static func colorForStatus(_ status: SpeedStatus) -> UIColor {
        switch status {
        case .over:
            return UIColor(red: 1.0, green: 0.24, blue: 0.44, alpha: 1.0) // red
        case .warning:
            return UIColor(red: 1.0, green: 0.72, blue: 0.0, alpha: 1.0)  // amber
        case .safe:
            return UIColor(red: 0.0, green: 1.0, blue: 0.62, alpha: 1.0)  // green
        }
    }

    /// Generates a small filled-circle image with the given color.
    static func statusCircleImage(color: UIColor, size: CGFloat = 40) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            // Draw outer glow
            color.withAlphaComponent(0.2).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
            // Draw filled circle
            color.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 4, y: 4, width: size - 8, height: size - 8))
        }
    }
}
