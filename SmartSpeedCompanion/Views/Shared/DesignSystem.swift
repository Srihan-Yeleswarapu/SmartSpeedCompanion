import SwiftUI

public struct DesignSystem {
    public static let bgDeep    = Color(hex: "#040510")
    public static let bgPanel   = Color(hex: "#0B0C1E")
    public static let bgCard    = Color(hex: "#0F1022")
    public static let cyan      = Color(hex: "#00D4FF")
    public static let neonGreen = Color(hex: "#00FF9D")
    public static let amber     = Color(hex: "#FFB800")
    public static let alertRed  = Color(hex: "#FF3D71")

    // Assuming Orbitron is not bundled natively, we'll try to use it if registered,
    // otherwise fallback to system font with similar characteristics.
    public static var displayFont: Font {
        .custom("Orbitron-Black", size: 52, relativeTo: .largeTitle)
    }
    
    public static var labelFont: Font {
        .system(.caption, design: .monospaced)
    }
    
    public static func colorForStatus(_ status: SpeedStatus) -> Color {
        switch status {
        case .safe: return neonGreen
        case .warning: return amber
        case .over: return alertRed
        }
    }
}
