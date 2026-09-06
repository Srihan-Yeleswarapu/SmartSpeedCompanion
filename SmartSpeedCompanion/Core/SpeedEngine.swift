import Foundation
import Combine
import CoreLocation

/// Engine responsible for observing location, determining speed, buffer, and calculating status.
@MainActor
public final class SpeedEngine: ObservableObject {
    @Published public var speed: Double = 0.0
    @Published public var limit: Int = 0
    /// True only after the latest requested lookup produced a usable posted
    /// limit. AlertEngine uses this separately from `limit` so an old value
    /// cannot keep beeping while a new lookup is in flight.
    @Published public private(set) var isLimitResolved: Bool = false
    @Published public var status: SpeedStatus = .safe

    /// Live read of the user's alert buffer (mph, -5...10) from UserDefaults.
    ///
    /// Deliberately NOT `@AppStorage`: that property wrapper only auto-
    /// refreshes inside SwiftUI Views (DynamicProperty). SpeedEngine is a
    /// plain class, so `@AppStorage` snapshotted the value at init and never
    /// observed later Settings changes — a buffer adjusted mid-drive kept the
    /// stale launch-time threshold in `updateStatus`, AlertEngine, the gauge
    /// arc, and the CarPlay buffer chip (TestFlight 2.3.0 b640: "I moved the
    /// buffer from +3 to +5 in the middle of the drive and it didn't update
    /// during the drive"). A direct read per evaluation costs nanoseconds at
    /// our ~1 Hz tick and is the same pattern HapticAlertManager uses.
    ///
    /// The getter accepts Int- or Double-backed stored values (SettingsView's
    /// slider writes a Double; VehicleProfile apply writes an Int), rounds to
    /// the nearest mph, and falls back to 5 when the key is unset — matching
    /// the previous `@AppStorage` default.
    public var userBuffer: Int {
        get {
            if let stored = UserDefaults.standard.object(forKey: "userBuffer") as? Double {
                return Int(stored.rounded())
            }
            return 5
        }
        set { UserDefaults.standard.set(newValue, forKey: "userBuffer") }
    }

    /// Live read of the measurement system ("Imperial" / "Metric"). Same
    /// rationale as `userBuffer` — see its doc comment.
    public var measurementSystem: String {
        get { UserDefaults.standard.string(forKey: "measurementSystem") ?? "Imperial" }
        set { UserDefaults.standard.set(newValue, forKey: "measurementSystem") }
    }

    private let locationManager: LocationManager
    private let speedLimitService = SmartSpeedLimitService.shared
    private let roadGeocoder = RoadGeocoder.shared
    private var cancellables = Set<AnyCancellable>()

    /// Internal speed state is always MPH. The prior 0.15 EMA plus a half-speed
    /// seed made the HUD materially under-report for the first several seconds
    /// after acceleration, and the under-report also delayed overspeed alerts.
    /// Keep a modest filter for GPS jitter while responding quickly to real
    /// acceleration/deceleration.
    private var smoothedSpeed: Double = 0.0
    private let smoothingFactor: Double = 0.35
    private let rapidSmoothingFactor: Double = 0.65
    private let rapidChangeThresholdMph: Double = 10.0
    private var lastSpeedSampleTimestamp: Date?
    private var lastValidSpeedTimestamp: Date?

    // ── Zero-speed deadband ──────────────────────────────────
    /// Number of consecutive raw readings that must fall below the
    /// `minSpeedThreshold` before we force the displayed speed to zero.
    /// Prevents GPS noise from showing "5 mph" while the user is
    /// stationary (holding the phone, sitting at a red light, etc.).
    private var zeroDeadbandCount: Int = 0
    private let minZerosBeforeStop: Int = 5
    /// Raw speed (mph) below which we count toward the deadband.
    private let minSpeedThreshold: Double = 3.0
    /// Raw speed (mph) below which we force the display to exactly 0.
    private let forceZeroThreshold: Double = 0.8
    /// If Core Location cannot provide a trustworthy speed for this long,
    /// do not leave the last moving speed frozen on screen indefinitely.
    private let invalidSpeedTimeout: TimeInterval = 3.0

    /// Fires the initial HERE batch cache setup once when the first valid,
    /// accurate GPS location arrives. After the first trigger, this flag
    /// is set so it never fires again.
    private var hasFiredInitialSetup: Bool = false

    /// Only one location-driven HERE resolution may publish at a time. A
    /// slower response for an older coordinate must never replace the limit
    /// for the road the user is currently on.
    private var speedLimitResolutionTask: Task<Void, Never>?
    private var speedLimitResolutionGeneration: UInt64 = 0

    // No own throttle on road-name resolution. `RoadGeocoder` carries its
    // own 50m grid-cell cache (see SmartSpeedCompanion/Core/RoadGeocoder.swift)
    // so a typical city drive costs ~1 geocode per block instead of per 1-Hz
    // GPS ping. The cached road name is preserved across the 50m cells so
    // live providers receive consistent road context on every fetch.

    /// Minimum distance (meters) the user must travel before we re-query the speed limit provider.
    /// The orchestration now self-throttles via the SpeedLimitResponseCache (spatial-grid
    /// short-circuit) + per-provider dedup, so we can space out fetches far enough for the
    /// live network providers without missing turns on city streets.
    ///   - Surface streets (< 20 m/s = ~45 mph): 80m (~ one city block)
    ///   - Highways (>= 20 m/s): 250m
    private let surfaceFetchDistance: CLLocationDistance = 80.0
    private let highwayFetchDistance: CLLocationDistance = 250.0
    private var lastFetchLocation: CLLocation?
    
    public init(locationManager: LocationManager) {
        self.locationManager = locationManager
        locationManager.$latestLocation
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] location in
                self?.processLocation(location)
            }
            .store(in: &cancellables)
    }
    
    private func processLocation(_ location: CLLocation) {
        let isMetric = measurementSystem == "Metric"

        // Speed can be unavailable (-1) or too uncertain for a live speedometer.
        // We still run the coordinate-driven speed-limit lookup below so a
        // stationary user can resolve the posted limit before moving.
        if let rawSpeedMph = trustworthySpeedMph(from: location) {
            updateDisplayedSpeed(rawSpeedMph, timestamp: location.timestamp, isMetric: isMetric)
        } else {
            expireUnavailableSpeedIfNeeded()
        }

        scheduleSpeedLimitResolution(for: location)
    }

    /// Core Location's `speedAccuracy` is measured in m/s. Reject only fixes
    /// whose error exceeds 5 m/s; a missing accuracy value (-1) is allowed when
    /// the speed itself is valid (common on simulators and some background
    /// fixes).
    private func trustworthySpeedMph(from location: CLLocation) -> Double? {
        guard location.speed >= 0 else { return nil }
        if location.speedAccuracy >= 0 && location.speedAccuracy > 5.0 {
            return nil
        }
        return location.speed * 2.23694
    }

    private func updateDisplayedSpeed(
        _ rawSpeedMph: Double,
        timestamp: Date,
        isMetric: Bool
    ) {
        lastValidSpeedTimestamp = timestamp

        // A new drive, foreground return, or GPS gap must not inherit the
        // previous drive's filtered speed.
        let hasSampleGap = lastSpeedSampleTimestamp.map {
            timestamp.timeIntervalSince($0) > 5.0
        } ?? true

        if rawSpeedMph < minSpeedThreshold {
            zeroDeadbandCount += 1
        } else {
            zeroDeadbandCount = 0
        }

        if rawSpeedMph < forceZeroThreshold || zeroDeadbandCount >= minZerosBeforeStop {
            smoothedSpeed = 0
            zeroDeadbandCount = minZerosBeforeStop
            speed = 0
            status = .safe
        } else if rawSpeedMph < minSpeedThreshold {
            // Decelerations into the low-speed range should be visible now;
            // the deadband only decides when to clamp persistent GPS noise to
            // zero, not whether the HUD may remain at the old cruising speed.
            smoothedSpeed = rawSpeedMph
            let displaySpeed = isMetric ? smoothedSpeed * 1.60934 : smoothedSpeed
            speed = max(0, displaySpeed)
            updateStatus(speed: speed, limit: Double(limit))
        } else {
            if smoothedSpeed == 0 || hasSampleGap {
                // Seed with the actual validated speed. Seeding at 50% was the
                // main source of an obviously wrong speed immediately after
                // starting or accelerating into traffic.
                smoothedSpeed = rawSpeedMph
            } else {
                let factor = abs(rawSpeedMph - smoothedSpeed) >= rapidChangeThresholdMph
                    ? rapidSmoothingFactor
                    : smoothingFactor
                smoothedSpeed += factor * (rawSpeedMph - smoothedSpeed)
            }

            let displaySpeed = isMetric ? smoothedSpeed * 1.60934 : smoothedSpeed
            speed = max(0, displaySpeed)
            updateStatus(speed: speed, limit: Double(limit))
        }

        lastSpeedSampleTimestamp = timestamp
    }

    private func expireUnavailableSpeedIfNeeded() {
        guard let lastValidSpeedTimestamp,
              Date().timeIntervalSince(lastValidSpeedTimestamp) >= invalidSpeedTimeout else {
            return
        }
        smoothedSpeed = 0
        speed = 0
        status = .safe
        zeroDeadbandCount = minZerosBeforeStop
    }

    /// Returns whether a location is eligible to start a speed-limit lookup.
    /// This is kept pure so the accuracy boundary can be regression-tested
    /// without starting Core Location or a network request.
    internal nonisolated static func isEligibleForSpeedLimitResolution(_ location: CLLocation) -> Bool {
        location.horizontalAccuracy > 0 &&
        location.horizontalAccuracy < LocationManager.maximumAcceptedHorizontalAccuracy
    }

    /// Starts a coordinate-driven HERE resolution if the user has moved far
    /// enough for a new lookup. Results are generation-checked before they can
    /// update the HUD, which prevents an older network response from restoring
    /// a wrong limit and suppressing or triggering the wrong alert.
    ///
    /// Use the same 100 m quality ceiling as LocationManager. The previous
    /// 15 m gate silently skipped nearly every real-device fix that the app
    /// otherwise accepted, leaving the speed-limit badge at `--` while speed
    /// and map tracking continued normally.
    private func scheduleSpeedLimitResolution(for location: CLLocation) {
        guard Self.isEligibleForSpeedLimitResolution(location) else {
            return
        }

        // CLLocation.speed is meters per second. Keep this comparison in the
        // same unit so highway updates receive the intended 250 m throttle.
        let threshold: CLLocationDistance = location.speed >= 20.0
            ? highwayFetchDistance
            : surfaceFetchDistance
        if let lastLoc = lastFetchLocation,
           location.distance(from: lastLoc) < threshold {
            return
        }

        lastFetchLocation = location
        speedLimitResolutionTask?.cancel()
        speedLimitResolutionGeneration &+= 1
        let generation = speedLimitResolutionGeneration

        // The previous answer is no longer authoritative while this location
        // is being resolved. This immediately stops an old overspeed alert
        // instead of allowing it to fire during the network/provider wait.
        limit = 0
        isLimitResolved = false
        status = .safe
        speedLimitService.beginResolution()

        // ── Initial HERE batch cache setup ───────────────────
        // Fire once on the first valid GPS tick to populate the local batch
        // cache with speed limits from a 2.5km grid.
        if !hasFiredInitialSetup {
            hasFiredInitialSetup = true
            Task {
                await HEREGeofenceManager.shared.performInitialSetup(
                    around: location.coordinate
                )
                HEREGeofenceManager.shared.configure(
                    locationManager: self.locationManager
                )
            }
        }

        let currentSpeedMph = trustworthySpeedMph(from: location) ?? 0
        speedLimitResolutionTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // HERE REST is the primary lookup and must not wait for reverse
            // geocoding. CLGeocoder can take several seconds; the next GPS
            // fix would cancel this task before the network request ever ran.
            // Live HERE can resolve by coordinate alone. Road-name enrichment
            // remains available to the batch cache on later integrations.
            let currentLimit = await self.speedLimitService.updateSpeedLimit(
                at: location.coordinate,
                heading: location.course >= 0 ? location.course : nil,
                currentSpeedMph: currentSpeedMph,
                roadName: nil
            )

            guard !Task.isCancelled,
                  self.speedLimitResolutionGeneration == generation else { return }

            self.limit = currentLimit
            self.isLimitResolved = currentLimit > 0
            self.updateStatus(speed: self.speed, limit: Double(currentLimit))
            if self.speedLimitResolutionGeneration == generation {
                self.speedLimitResolutionTask = nil
            }
        }
    }

    /// Returns the cached or freshly-resolved road name from `RoadGeocoder`
    /// for the current coordinate.
    ///
    /// Implementation note: do NOT add a local throttle here. The previous
    /// implementation short-circuited with `return nil` when the caller was
    /// within 200m of the last geocode, which stripped the road name from
    /// the SpeedLimit pipeline for entire city blocks and caused the snap
    /// to fall back to spatial-only scoring -- which on roads like Arizona
    /// Avenue in Chandler returns S 202's 65 mph mega-bbox instead of the
    /// correct local-road answer. `RoadGeocoder` already throttles via its
    /// own 50m grid cache; this method just delegates so the road name
    /// flows through every fetch.
    private func resolvedRoadName(at coordinate: CLLocationCoordinate2D) async -> String? {
        // The road name is enrichment for cache matching, not a prerequisite
        // for HERE REST. A cold CLGeocoder can otherwise delay the only live
        // speed-limit request long enough for the next GPS tick to cancel it.
        let geocoder = roadGeocoder
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await geocoder.resolveRoadContext(at: coordinate)?.roadName
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 350_000_000)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
    
    /// Resets transient GPS and limit state at the beginning of a new drive.
    /// Without this boundary, a quick stop/start could inherit the previous
    /// drive's filtered speed or skip the first HERE lookup because the new
    /// coordinate was still inside the prior distance throttle.
    public func resetForNewDrive() {
        speedLimitResolutionTask?.cancel()
        speedLimitResolutionTask = nil
        speedLimitResolutionGeneration &+= 1
        smoothedSpeed = 0
        lastSpeedSampleTimestamp = nil
        lastValidSpeedTimestamp = nil
        zeroDeadbandCount = 0
        lastFetchLocation = nil
        speed = 0
        limit = 0
        isLimitResolved = false
        status = .safe
        speedLimitService.beginResolution()
    }

    /// Marks the current limit as unresolved before a direct/manual lookup.
    /// DriveViewModel uses this when it asks SmartSpeedLimitService outside
    /// the normal GPS-resolution task.
    @discardableResult
    public func beginLimitResolution() -> UInt64 {
        speedLimitResolutionTask?.cancel()
        speedLimitResolutionGeneration &+= 1
        let token = speedLimitResolutionGeneration

        // Clear the displayed limit immediately. Manual and heading-triggered
        // refreshes must have the same unknown-limit semantics as GPS refreshes:
        // neutral HUD, no red state, and no alert audio/haptics while HERE is
        // resolving the new road.
        limit = 0
        isLimitResolved = false
        status = .safe
        speedLimitService.beginResolution()
        return token
    }

    /// Applies a limit returned by a direct lookup (manual refresh or a
    /// heading-triggered fetch) through the same state path as GPS updates.
    /// If a newer GPS/manual resolution started while the request was in
    /// flight, discard this stale completion.
    public func applyResolvedLimit(_ newLimit: Int, resolutionToken: UInt64? = nil) {
        if let resolutionToken,
           resolutionToken != speedLimitResolutionGeneration {
            return
        }
        speedLimitResolutionTask = nil
        limit = newLimit
        isLimitResolved = newLimit > 0
        updateStatus(speed: speed, limit: Double(newLimit))
    }

    private func updateStatus(speed: Double, limit: Double) {
        guard limit > 0 else {
            self.status = .safe
            return
        }
        
        let isMetric = measurementSystem == "Metric"
        let displayLimit = isMetric ? limit * 1.60934 : limit
        let displayBuffer = isMetric ? Double(userBuffer) * 1.60934 : Double(userBuffer)
        
        let threshold = displayLimit + displayBuffer
        
        if speed > threshold {
            self.status = .over
        } else if speed >= (threshold - (isMetric ? 2.0 : 1.0)) {
            self.status = .warning // Yellow only for the top 1 mph of buffer
        } else {
            self.status = .safe
        }
    }
}