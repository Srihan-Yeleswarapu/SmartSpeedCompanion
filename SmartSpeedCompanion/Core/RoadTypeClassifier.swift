import Foundation

/// Maps the current driving context to a road-type key consumed by
/// `SpeedAlertProfile.buffer(for:)` — "highway", "arterial", "residential",
/// or "schoolZone".
///
/// Speedio's live HERE speed-limit provider does not expose a road
/// functional-class, so this is a conservative heuristic built from the two
/// signals already flowing through the app: the posted speed limit (mph) and
/// the reverse-geocoded road name. Ambiguous or unknown cases return `nil`,
/// which lets the active profile fall back to its `defaultBuffer` — a safe
/// choice that never disables alerts and never tightens them off a guess.
enum RoadTypeClassifier {

    /// Returns a road-type key suitable for `SpeedAlertProfile.buffer(for:)`,
    /// or `nil` when the road can't be confidently classified.
    static func roadType(speedLimitMph: Int?, roadName: String?) -> String? {
        let name = (roadName?.uppercased() ?? "")

        // School zones are the one type reliably signaled by the road name.
        if name.contains("SCHOOL") { return "schoolZone" }

        // Very low posted limits (15-20 mph) are neighborhood / school streets.
        if let limit = speedLimitMph, limit <= 20 { return "residential" }

        // Freeways/highways: family road-name prefixes or a 55+ mph limit.
        let isHighwayFamily = name.contains("INTERSTATE")
            || name.hasPrefix("I-")
            || name.hasPrefix("I ")
            || name.hasPrefix("US")
            || name.contains(" STATE ROUTE")
            || name.contains("STATE HIGHWAY")
            || name.contains(" HWY")
            || name.contains(" FREEWAY")
            || name.contains(" TURNPIKE")
        if isHighwayFamily || (speedLimitMph ?? 0) >= 55 {
            return "highway"
        }

        if let limit = speedLimitMph {
            // 35-50 mph signed roads read as arterials; under that, local.
            return limit >= 35 ? "arterial" : "residential"
        }
        return nil
    }
}