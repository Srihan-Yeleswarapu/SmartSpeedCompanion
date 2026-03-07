import Foundation
import CoreLocation

extension CLLocation {
    /// Helper to reliably extract speed in mph, falling back to 0 if invalid.
    public var speedInMph: Double {
        let validSpeed = max(0, self.speed)
        return validSpeed * 2.23694
    }
}
