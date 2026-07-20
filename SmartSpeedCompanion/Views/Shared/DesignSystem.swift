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
    
    // ---------------------------------------------------------------
    //  Liquid Glass Design Tokens
    //  Inspired by Apple's ultra-thin material + refractive edge +
    //  depth shadow + subtle inner glow for a true glass aesthetic.
    // ---------------------------------------------------------------
    
    /// Legacy solid-glass helpers (kept for backward compatibility)
    public static let glassBg = Color(white: 1.0, opacity: 0.1)
    public static let glassBorder = Color(white: 1.0, opacity: 0.2)
    public static let glassVibrancy = Color(white: 1.0, opacity: 0.05)
    
    public struct LiquidGlass {
        // ── Material ──────────────────────────────────────────
        /// Ultra-thin material = the trademark Apple blur layer
        public static let material = Material.ultraThinMaterial
        
        // ── Outer shadow (depth / elevation) ──────────────────
        public static let shadowColor      = Color.black.opacity(0.18)
        public static let shadowRadius: CGFloat = 18
        public static let shadowX: CGFloat = 0
        public static let shadowY: CGFloat = 8
        
        // ── Refractive edge border ────────────────────────────
        /// Main border — thin white outline that mimics the glass edge
        public static let borderColor  = Color.white.opacity(0.18)
        public static let borderWidth: CGFloat = 0.5
        
        /// Edge highlight — a brighter accent on the top-leading edge,
        /// simulating light catching the glass bevel
        public static let edgeHighlightColor  = Color.white.opacity(0.35)
        public static let edgeHighlightWidth: CGFloat = 0.5
        
        // ── Inner glow & depth ────────────────────────────────
        /// Top gradient glow — a white-to-clear gradient at the top
        /// of the glass panel, mimicking environmental reflection
        public static let topGlowColor = Color.white.opacity(0.10)
        
        /// Inner shadow — very subtle dark inset that gives the
        /// glass a "sunken" / beveled edge feel
        public static let innerShadowColor = Color.black.opacity(0.08)
        public static let innerShadowRadius: CGFloat = 2
        
        // ── Shape ─────────────────────────────────────────────
        public static let cornerRadius: CGFloat = 20
        
        // ── Vibrancy───────────────────────────────────────────
        /// Extra tint layer on top of the material to boost
        /// readability when content sits on the glass
        public static let vibrancyTint = Color.white.opacity(0.04)
    }
}