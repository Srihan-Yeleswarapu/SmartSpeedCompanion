// NetworkReachability.swift
// Lightweight wrapper around NWPathMonitor that publishes whether the device has an
// active network path. SmartSpeedLimitService uses this to decide whether to
// attempt the live HERE/ArcGIS/Overpass provider chain. When offline, it returns
// No Data rather than using the Arizona-only dormant dataset.
//
// Why @MainActor? The published `isConnected` is consumed by the @MainActor
// orchestrator (SmartSpeedLimitService) on every speed-limit fetch. Keeping both
// on the same isolation domain avoids Task hops on the hot path.

import Foundation
import Network
import Combine

@MainActor
public final class NetworkReachability: ObservableObject {
    public static let shared = NetworkReachability()

    /// True iff the recently-evaluated network path satisfies cellular or wifi.
    /// Defaults to `true` (optimistic) until the monitor delivers its first sample.
    @Published public private(set) var isConnected: Bool = true

    private let monitor: NWPathMonitor

    private init() {
        self.monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            // Bounce onto the main actor before updating the @Published property.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isConnected != satisfied {
                    self.isConnected = satisfied
                    DebugLogger.shared.log("NetworkReachability: isConnected = \(satisfied)")
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.smartSpeedCompanion.reachability"))
    }
}
