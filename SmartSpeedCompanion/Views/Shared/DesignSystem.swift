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
    
    // Liquid Glass Tokens
    public static let glassBg = Color(white: 1.0, opacity: 0.1)
    public static let glassBorder = Color(white: 1.0, opacity: 0.2)
    public static let glassVibrancy = Color(white: 1.0, opacity: 0.05)
    
    public struct LiquidGlass {
        public static let material = Material.ultraThinMaterial
        public static let shadowColor = Color.black.opacity(0.3)
        public static let shadowRadius: CGFloat = 15
        public static let cornerRadius: CGFloat = 20
        public static let borderWidth: CGFloat = 0.5
    }
}
