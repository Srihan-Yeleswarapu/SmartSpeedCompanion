// CarPlayListSpeedController.swift — PLAN B
// ==========================================
// Rich list-based speed dashboard that works with ONLY the
// `carplay-driving-task` entitlement.
//
// Manages a CPListTemplate with mutable CPListItem references,
// updated in-place from DriveViewModel's Combine publishers.
// No CPMapTemplate, no CPNavigationSession — purely list-based.

import CarPlay
import Combine
import UIKit

/// Rich list-based speed dashboard for Plan B CarPlay mode.
/// Displays current speed, limit, status, session controls,
/// and drive info — all within a CPListTemplate hierarchy that
/// works with only the `carplay-driving-task` entitlement.
@MainActor
class CarPlayListSpeedController {

    // MARK: - Public

    /// The root list template displayed in CarPlay.
    let listTemplate: CPListTemplate

    // MARK: - Private properties

    private weak var interfaceController: CPInterfaceController?
    private let viewModel: DriveViewModel
    private var cancellables = Set<AnyCancellable>()

    /// Top speed observed during the current recording session (in display units).
    private var sessionTopSpeed: Double = 0

    // ── Mutable list items (updated in-place) ──────────────────────

    // Speed section
    private let speedItem: CPListItem
    private let limitItem: CPListItem
    private let statusItem: CPListItem

    // Session section
    private let sessionToggleItem: CPListItem

    // Drive info section (shown/hidden based on recording state)
    private let durationItem: CPListItem
    private let topSpeedItem: CPListItem
    private var driveInfoSection: CPListSection?

    // Actions section
    private let camerasItem: CPListItem

    // MARK: - Init

    init(interfaceController: CPInterfaceController, viewModel: DriveViewModel) {
        self.interfaceController = interfaceController
        self.viewModel = viewModel

        let system = SpeedFormatting.measurementSystem()
        let unitShort = SpeedFormatting.unitLabelShort(measurementSystem: system)

        // ── Create all items with initial placeholders ────────────

        // SPEED section
        speedItem = CPListItem(text: "--", detailText: unitShort)
        speedItem.isEnabled = false
        speedItem.setImage(Self.statusCircleImage(color: .systemGreen, size: 28))

        limitItem = CPListItem(text: "Speed Limit", detailText: "--")
        limitItem.isEnabled = false

        statusItem = CPListItem(text: "Status", detailText: "SAFE")
        statusItem.isEnabled = false

        // SESSION section
        sessionToggleItem = CPListItem(
            text: "▶ START DRIVE",
            detailText: "Tap to begin recording"
        )
        sessionToggleItem.handler = { [weak self] _, completion in
            self?.handleSessionToggle()
            completion()
        }

        // DRIVE INFO section (hidden initially)
        durationItem = CPListItem(text: "Duration", detailText: "0 min")
        durationItem.isEnabled = false

        topSpeedItem = CPListItem(text: "Top Speed", detailText: "0 \(unitShort)")
        topSpeedItem.isEnabled = false

        // ACTIONS section
        let reportItem = CPListItem(
            text: "Safety Report",
            detailText: "View drive statistics"
        )
        reportItem.handler = { [weak self] _, completion in
            self?.presentSafetyReport()
            completion()
        }

        camerasItem = CPListItem(text: "Cameras Nearby", detailText: "0")
        camerasItem.isEnabled = false

        // ── Build initial sections ─────────────────────────────────

        let speedSection = CPListSection(
            items: [speedItem, limitItem, statusItem],
            header: "CURRENT SPEED",
            sectionIndexTitle: nil
        )
        let sessionSection = CPListSection(
            items: [sessionToggleItem],
            header: "SESSION",
            sectionIndexTitle: nil
        )
        let actionsSection = CPListSection(
            items: [reportItem, camerasItem],
            header: "ACTIONS",
            sectionIndexTitle: nil
        )

        listTemplate = CPListTemplate(
            title: "Speedio",
            sections: [speedSection, sessionSection, actionsSection]
        )

        // Empty the drive-info sections array so the section can be
        // inserted dynamically when recording starts.
        self.driveInfoSection = nil

        // ── Bind view model publishers ────────────────────────────
        bindViewModel()
    }

    // MARK: - View Model Binding

    private func bindViewModel() {
        // Use a 500ms Timer to periodically read all values from the view model
        // and update the display. Using a timer avoids the complexity of chaining
        // `combineLatest` with 6+ publishers (which exceeds Combine's built-in
        // overload limit) while still providing smooth 2 Hz updates.
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
                    cameras: self.viewModel.nearbyCameras
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
        cameras: [SpeedCamera]
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

        // ── Speed item ────────────────────────────────────────────
        let speedInt = Int(speed)
        let circleColor = Self.colorForStatus(status)
        speedItem.setText("\(speedInt)")
        speedItem.setDetailText(unitShort)
        speedItem.setImage(Self.statusCircleImage(color: circleColor, size: 28))

        // ── Limit item ────────────────────────────────────────────
        if limit > 0 {
            limitItem.setDetailText("\(displayLimit) \(unitShort)")
        } else {
            limitItem.setDetailText("--")
        }

        // ── Status item ───────────────────────────────────────────
        let statusLabel: String
        switch status {
        case .over:
            statusLabel = "⚠ OVERSPEED"
        case .warning:
            statusLabel = "⚠ WARNING"
        case .safe:
            statusLabel = "✔ SAFE"
        }
        statusItem.setDetailText(statusLabel)

        // ── Session toggle item ───────────────────────────────────
        if isRecording {
            sessionToggleItem.setText("■ END DRIVE")
            sessionToggleItem.setDetailText("Tap to stop recording")
        } else {
            sessionToggleItem.setText("▶ START DRIVE")
            sessionToggleItem.setDetailText("Tap to begin recording")
        }

        // ── Drive-info section (show/hide) ────────────────────────
        if isRecording && driveInfoSection == nil {
            // Insert the drive-info section after the session section (index 1)
            let mins = Int(duration / 60)
            durationItem.setDetailText("\(mins) min")
            topSpeedItem.setDetailText("\(Int(sessionTopSpeed)) \(unitShort)")

            let section = CPListSection(
                items: [durationItem, topSpeedItem],
                header: "DRIVE INFO",
                sectionIndexTitle: nil
            )
            driveInfoSection = section

            // CPListTemplate.sections is a get-only property.
            // We use updateSections(_:) to replace the full array.
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
            durationItem.setDetailText("\(mins) min")
            topSpeedItem.setDetailText("\(Int(sessionTopSpeed)) \(unitShort)")

        } else if !isRecording && driveInfoSection != nil {
            // Remove the drive-info section
            driveInfoSection = nil
            var current = listTemplate.sections
            // Find and remove the section titled "DRIVE INFO"
            current.removeAll { section in
                section.header == "DRIVE INFO"
            }
            listTemplate.updateSections(current)
        }

        // ── Cameras item ──────────────────────────────────────────
        camerasItem.setDetailText("\(cameras.count)")
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
            CPInformationItem(title: "Current Speed", detail: "\(Int(viewModel.speed)) \(unitShort)"),
            CPInformationItem(title: "Drive Time", detail: "\(Int(viewModel.sessionDuration / 60)) min"),
            CPInformationItem(
                title: "Status",
                detail: viewModel.status.rawValue.uppercased()
            ),
            CPInformationItem(
                title: "Speed Limit Source",
                detail: viewModel.speedLimitSource
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
    static func statusCircleImage(color: UIColor, size: CGFloat = 28) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            color.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 2, y: 2, width: size - 4, height: size - 4))
        }
    }
}
