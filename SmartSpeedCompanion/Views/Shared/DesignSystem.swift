import SwiftUI

public struct DesignSystem {
    // ── COLORS (PRD SPECIFIED)
    public static let bgDeep    = Color(hex: "#040510") // Deepest background
    public static let bgCard    = Color(hex: "#0F1022") // Card/Inset background
    public static let bgPanel   = Color(hex: "#15162D") // Lighter glass-ish panel
    public static let border    = Color(hex: "#22233E") // Subtle border
    
    public static let cyan      = Color(hex: "#00D4FF") // Navigation/Primary
    public static let neonGreen = Color(hex: "#00FF9D") // Safe Speed
    public static let amber     = Color(hex: "#FFB800") // Warning Boundary
    public static let alertRed  = Color(hex: "#FF3D71") // Overspeed Alert
    
    public static let text      = Color(hex: "#FFFFFF")
    public static let secondary = Color(hex: "#8888AA") // Muted text

    // ── TYPOGRAPHY
    public static var displayFont: Font {
        .system(size: 40, weight: .black, design: .monospaced)
    }
    
    public static func speedFont(landscape: Bool) -> Font {
        .system(size: landscape ? 40 : 56, weight: .black, design: .monospaced)
    }
    
    public static var labelFont: Font {
        .system(size: 10, weight: .bold, design: .monospaced)
    }

    public static var instructionFont: Font {
        .system(size: 18, weight: .semibold, design: .default)
    }

    public static func colorForStatus(_ status: SpeedStatus) -> Color {
        switch status {
        case .safe: return neonGreen
        case .warning: return amber
        case .over: return alertRed
        }
    }
    
    // ── GLASSMORPHISM HELPER
    public static var glassBackground: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(bgPanel.opacity(0.85))
            .background(Blur(style: .systemThinMaterialDark))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(border.opacity(0.3), lineWidth: 1))
    }
}

// ── BLUR EFFECT HELPER
struct Blur: UIViewRepresentable {
    var style: UIBlurEffect.Style
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}
