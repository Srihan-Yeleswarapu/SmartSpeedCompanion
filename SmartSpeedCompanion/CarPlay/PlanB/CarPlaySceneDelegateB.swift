// CarPlaySceneDelegateB.swift — PLAN B
// ==========================================
// This is the Plan B CarPlay scene delegate.
// It uses ONLY templates that work with the `carplay-driving-task`
// entitlement (no CPMapTemplate, no CPNavigationSession, no MapKit).
//
// Plan A (original CarPlaySceneDelegate) is preserved untouched
// in SmartSpeedCompanion/CarPlay/ and will be activated once the
// provisioning profile is regenerated with all three entitlements.
//
// What Plan B offers:
//   • Live speed / limit / status display via CPListTemplate
//   • Color-coded status indicator (green/amber/red)
//   • Start / End drive session toggle
//   • Drive duration + top-speed tracking
//   • Safety Report (CPInformationTemplate)
//   • Dashboard buttons (reuses CarPlayDashboardController)
//
// Entitlement-safe: only imports CarPlay (no MapKit).

import CarPlay
import UIKit

class CarPlaySceneDelegateB: UIResponder,
                              CPTemplateApplicationSceneDelegate,
                              CPTemplateApplicationDashboardSceneDelegate {

    private var interfaceController: CPInterfaceController?
    private var dashboardController: CPDashboardController?
    private var dashboardManager: CarPlayDashboardController?
    private var speedListController: CarPlayListSpeedController?

    // MARK: - Scene Connection (Modern, iOS 14+)

    /// CarPlay connected the template scene with a CPWindow.
    /// We build a list-based root template instead of a map template.
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        self.interfaceController = interfaceController
        setupListRoot(interfaceController: interfaceController)
    }

    // MARK: - Scene Connection (Legacy, no window)

    /// Fallback for configurations that dispatch the legacy selector.
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        setupListRoot(interfaceController: interfaceController)
    }

    // MARK: - Setup Helpers

    /// Build the list-based root template, start the controller, and set it
    /// on the interface controller.
    private func setupListRoot(interfaceController: CPInterfaceController) {
        let vm = AppDelegate.sharedDriveViewModel
        let controller = CarPlayListSpeedController(
            interfaceController: interfaceController,
            viewModel: vm
        )
        // Start the controller: wires item handlers and the display-update timer.
        // Must be called AFTER init because handlers capture self, and self's
        // stored properties (listTemplate) must be initialized first.
        controller.start()
        speedListController = controller

        guard let rootTemplate = speedListController?.listTemplate else { return }
        interfaceController.setRootTemplate(rootTemplate, animated: true, completion: nil)
    }

    // MARK: - Dashboard Support

    func templateApplicationDashboardScene(
        _ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
        didConnect dashboardController: CPDashboardController,
        to window: UIWindow
    ) {
        self.dashboardController = dashboardController
        let vm = AppDelegate.sharedDriveViewModel
        self.dashboardManager = CarPlayDashboardController(
            dashboardController: dashboardController,
            viewModel: vm
        )
    }

    func templateApplicationDashboardScene(
        _ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
        didDisconnect dashboardController: CPDashboardController,
        from window: UIWindow
    ) {
        self.dashboardManager = nil
        self.dashboardController = nil
    }

    // MARK: - Disconnection

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        tearDown()
    }

    /// Single teardown for all disconnect paths.
    private func tearDown() {
        speedListController = nil
        dashboardManager = nil
        interfaceController = nil
        dashboardController = nil
    }
}
