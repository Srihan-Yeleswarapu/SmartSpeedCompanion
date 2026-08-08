// SpeedFormatting.swift
// Single source of truth for every "mph/kmh" label and every speed-limit
// value surfaced to the user. The SpeedEngine stores everything internally
// in MPH (its smoothing + threshold logic is mph-stable) and the ViewModel
// publishes `speed` already converted to the active display unit — but every
// OTHER place that displays a stored MPH limit (the widget, the Live
// Activity, CarPlay button labels, the safety-report CPInformationItem, the
// gauge center "MPH" caption, etc.) needs to (a) read the user's measurement
// setting and (b) convert / re-label accordingly.
//
// Before this helper existed, the limit was rendered under at least one of
// three different policies per view:
//   - corrected (SpeedDisplayView, MapWithHUDView's LimitSignView)
//   - hard-coded "MPH" widget (SpeedWidget, SpeedLiveActivityView, SpeedGaugeView)
//   - ignored entirely (StandByView had no unit at all)
//
// TestFlight 2.1.4 feedback "When I put metric, why does speed limit show MPH
// still? Make sure when in metric it shows metric, when in imperial it shows
// imperial." — every display path now routes through `SpeedFormatting` so the
// toggle is honored everywhere simultaneously.

import Foundation

public enum SpeedFormatting {

    // MARK: - Constants

    /// 1 mph = 1.60934 km/h. Single canonical conversion factor — every
    /// other conversion site in the codebase should reference this rather
    /// than hard-coding a literal so we can audit drift in one place.
    public static let kmhPerMph: Double = 1.60934

    /// 1 mile in meters. Canonical SI-derived value (1609.344 exactly).
    /// Paired with `feetPerMeter` so the only place a length conversion
    /// factor lives is here — keeps the comment in the file header auditable
    /// ("every other conversion site... should reference this rather than
    /// hard-coding a literal").
    public static let metersPerMile: Double = 1609.344

    /// 1 meter in feet. Equals ~3.28084. Paired with `metersPerMile`.
    public static let feetPerMeter: Double = 1.0 / 0.3048

    /// 1 kilometer in meters. SI canonical.
    public static let metersPerKilometer: Double = 1000

    /// Suite name shared by WidgetKit + ActivityKit extensions. Must mirror
    /// the App Group capability declared on the main app's entitlements.
    public static let appGroupSuite = "group.com.smartspeedcompanion.app"

    /// User-Defaults key written from Settings → UNITS picker. Mirrors the
    /// `@AppStorage("measurementSystem")` declaration in `SettingsView`. We
    /// accept `"Metric"` / `"Imperial"`; anything else falls back to
    /// Imperial, matching the historical default for U.S. builds.
    public static let measurementSystemDefaultsKey = "measurementSystem"

    /// App-Group key written from Settings → UNITS picker (via
    /// `SettingsView.onChange(of: measurementSystem)`). Widgets + Live
    /// Activities live in their own process and can't read the main app's
    /// standard UserDefaults, so we mirror the value into the shared suite.
    public static let widgetMeasurementSystemAppGroupKey = "widgetMeasurementSystem"

    // MARK: - Read active unit

    /// Returns the user's preferred measurement system ("Metric" or
    /// "Imperial") from standard UserDefaults. Defaults to "Imperial"
    /// when the key is unset (matches `SettingsView`'s @AppStorage default).
    public static func measurementSystem(from defaults: UserDefaults = .standard) -> String {
        return defaults.string(forKey: measurementSystemDefaultsKey) ?? "Imperial"
    }

    /// Convenience predicate so call sites don't repeat the equality check.
    public static func isMetric(_ system: String) -> Bool {
        return system == "Metric"
    }

    /// Reads measurement system from the shared App Group suite. Widgets
    /// and Live Activities should ALWAYS use this instead of
    /// `measurementSystem(from:)` — their standard UserDefaults is empty.
    public static func measurementSystemFromAppGroup() -> String {
        let group = UserDefaults(suiteName: appGroupSuite)
        return group?.string(forKey: widgetMeasurementSystemAppGroupKey) ?? "Imperial"
    }

    // MARK: - Value conversion

    /// Converts a stored MPH limit to the value to render under the active
    /// measurement system. Uses `(mph * kmhPerMph).rounded()` so 65 mph
    /// becomes 105 km/h (the nearest posted-sign value, consistent with
    /// countries that round to multiples of 5 km/h).
    public static func displayLimit(forMph mph: Int, measurementSystem: String) -> Int {
        if isMetric(measurementSystem) {
            return Int((Double(mph) * kmhPerMph).rounded())
        }
        return mph
    }

    /// Same as `displayLimit(forMph:measurementSystem:)` but for the
    /// buffer (a Double, since callers feed it the raw mph slider value).
    public static func displayBuffer(forMph mph: Double, measurementSystem: String) -> Double {
        if isMetric(measurementSystem) {
            return (mph * kmhPerMph).rounded()
        }
        return mph
    }

    /// Converts a stored meters `CLLocationDistance` into the `(value, unit)`
    /// tuple that voice and UI surfaces speak back. Below ~1 km / ~1 mi we
    /// drop into the finer-grained unit (meters / feet) because drivers
    /// reason about short distances naturally in those units — Siri will
    /// say *"Your next turn is in 200 feet"* instead of *"Your next turn is in
    /// 0.12 miles"*.
    public static func distanceDisplay(forMeters meters: Double, measurementSystem: String) -> (value: Double, unit: String) {
        if isMetric(measurementSystem) {
            return (meters / metersPerKilometer, "kilometers")
        }
        // Imperial: see top-of-enum constants. (1/0.3048 == ~3.28084)
        if meters >= metersPerMile {
            return (meters / metersPerMile, "miles")
        }
        return (meters * feetPerMeter, "feet")
    }

    // MARK: - Unit labels

    /// Upper-case 3-letter label used wherever space is tight and we want
    /// the chip to read consistently: "65 MPH", "Speed: 65 KMH".
    public static func unitLabelShort(measurementSystem: String) -> String {
        return isMetric(measurementSystem) ? "KMH" : "MPH"
    }

    /// Lower-case word used in prose-style labels where a slash is fine:
    /// Settings → "Speed Buffer: +5 km/h", BufferSliderView footer.
    public static func unitLabelLong(measurementSystem: String) -> String {
        return isMetric(measurementSystem) ? "km/h" : "mph"
    }

    // MARK: - Navigation distance helpers

    /// Formats a navigation distance using the user's large-distance display
    /// unit. Metric navigation uses kilometers consistently (including short
    /// distances) so a route never appears as a large raw-meter count.
    public static func navigationDistanceLabel(
        forMeters meters: Double,
        measurementSystem: String
    ) -> String {
        if isMetric(measurementSystem) {
            return String(format: "%.1f km", meters / metersPerKilometer)
        }
        let miles = meters / metersPerMile
        if miles < 0.1 {
            return String(format: "%.0f ft", meters * feetPerMeter)
        }
        return String(format: "%.1f mi", miles)
    }

    /// Builds the unit CarPlay should display for a navigation distance.
    ///
    /// CarPlay renders the unit carried by `CPTravelEstimates`; passing raw
    /// meters makes an imperial route appear as `38,619 m` on some head units
    /// and bypasses the user's app-level units preference. Keep navigation
    /// values in meters internally, but hand CarPlay a locale-independent
    /// miles or kilometers measurement at the presentation boundary.
    public static func navigationDistanceMeasurement(
        forMeters meters: Double,
        measurementSystem: String
    ) -> Measurement<UnitLength> {
        if isMetric(measurementSystem) {
            return Measurement(value: meters / metersPerKilometer, unit: .kilometers)
        }
        return Measurement(value: meters / metersPerMile, unit: .miles)
    }

    /// MARK: - Combined convenience

    /// Returns `(value, unit)` for a stored mph limit so call sites don't
    /// have to repeat the two conversion calls.
    public static func limitDisplay(forMph mph: Int, measurementSystem: String) -> (value: Int, unit: String) {
        return (
            displayLimit(forMph: mph, measurementSystem: measurementSystem),
            unitLabelShort(measurementSystem: measurementSystem)
        )
    }

    // MARK: - App Group writer

    /// Writes the active measurement system into the shared App Group so
    /// widgets / Live Activities can read it. Call this whenever the user
    /// changes the UNITS picker (Settings → NAVIGATION section). Safe to
    /// call repeatedly; identical values short-circuit the underlying
    /// UserDefaults write.
    public static func writeMeasurementSystemToAppGroup(_ system: String) {
        UserDefaults(suiteName: appGroupSuite)?.set(system, forKey: widgetMeasurementSystemAppGroupKey)
    }
}
