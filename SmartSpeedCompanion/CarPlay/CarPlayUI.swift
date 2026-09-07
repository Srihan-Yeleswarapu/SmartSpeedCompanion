// CarPlayUI.swift
// =================================
// Shared visual design system for the Speedio CarPlay experience.
// Provides the canonical palette (mirroring DesignSystem on the
// phone) and rendered icon assets — iOS-Settings-style colored
// tiles, circular map-button badges, HUD status pills — so every
// CarPlay screen shares one cohesive, premium look.

import UIKit

enum CarPlayUI {

    // MARK: - Palette (mirrors DesignSystem)

    static let cyan      = UIColor(red: 0.000, green: 0.831, blue: 1.000, alpha: 1.0) // #00D4FF
    static let neonGreen = UIColor(red: 0.000, green: 1.000, blue: 0.616, alpha: 1.0) // #00FF9D
    static let amber     = UIColor(red: 1.000, green: 0.722, blue: 0.000, alpha: 1.0) // #FFB800
    static let alertRed  = UIColor(red: 1.000, green: 0.239, blue: 0.443, alpha: 1.0) // #FF3D71
    static let blue      = UIColor(red: 0.039, green: 0.518, blue: 1.000, alpha: 1.0) // #0A84FF
    static let purple    = UIColor(red: 0.749, green: 0.353, blue: 0.949, alpha: 1.0) // #BF5AF2
    static let orange    = UIColor(red: 1.000, green: 0.624, blue: 0.039, alpha: 1.0) // #FF9F0A
    static let teal      = UIColor(red: 0.251, green: 0.784, blue: 0.878, alpha: 1.0) // #40C8E0
    static let pink      = UIColor(red: 1.000, green: 0.216, blue: 0.373, alpha: 1.0) // #FF375F
    static let indigo    = UIColor(red: 0.369, green: 0.361, blue: 0.902, alpha: 1.0) // #5E5CE6
    static let gray      = UIColor(red: 0.557, green: 0.557, blue: 0.576, alpha: 1.0) // #8E8E93

    /// Liquid-glass guidance panel tone for the map template's
    /// `guidanceBackgroundColor`. CarPlay's default is a solid red banner
    /// above the map; this replaces it with the same dark translucent glass
    /// material the system uses for the trip-estimates panel (bottom-left
    /// distance / time / ETA), so all guidance chrome reads as one material.
    /// The alpha is intentional — CarPlay composites the guidance background
    /// over the live map for a glass-like translucency; head units that
    /// flatten it still render the same charcoal glass tone. The tone is
    /// dark, so white instruction text clears the system's contrast check
    /// (the documented fallback would otherwise restore the default red).

    static let guidanceGlass = UIColor(white: 0.10, alpha: 0.80)

    /// Canonical status color used across the HUD and alerts.
    static func statusColor(_ status: SpeedStatus) -> UIColor {
        switch status {
        case .safe:    return neonGreen
        case .warning: return amber
        case .over:    return alertRed
        }
    }

    // MARK: - Renderers

    /// Renders an SF Symbol as an `alwaysOriginal` (full-color) image.
    private static func symbol(_ name: String,
                               pointSize: CGFloat,
                               weight: UIImage.SymbolWeight = .semibold,
                               color: UIColor = .white) -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        return UIImage(systemName: name, withConfiguration: config)?
            .withTintColor(color, renderingMode: .alwaysOriginal)
    }

    /// iOS Settings-style colored rounded-square tile with a white glyph.
    /// Used for list-row icons across settings, profiles, and places.
    static func iconTile(systemName: String,
                         color: UIColor,
                         size: CGFloat = 44,
                         cornerRatio: CGFloat = 0.225,
                         symbolSize: CGFloat? = nil) -> UIImage {
        let glyph = symbolSize ?? size * 0.5
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let image = renderer.image { _ in
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: size * cornerRatio)
            color.setFill()
            path.fill()
            if let s = symbol(systemName, pointSize: glyph) {
                s.draw(in: CGRect(x: (size - s.size.width) / 2,
                                  y: (size - s.size.height) / 2,
                                  width: s.size.width,
                                  height: s.size.height))
            }
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    /// Circular colored badge with a white glyph — the map-button look.
    /// Renders full-color so the buttons read like Google/Apple Maps
    /// action buttons instead of flat system glyphs.
    static func circleBadge(systemName: String,
                            color: UIColor,
                            size: CGFloat = 46,
                            symbolSize: CGFloat? = nil) -> UIImage {
        let glyph = symbolSize ?? size * 0.52
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let image = renderer.image { _ in
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            let path = UIBezierPath(ovalIn: rect)
            color.setFill()
            path.fill()
            if let s = symbol(systemName, pointSize: glyph) {
                s.draw(in: CGRect(x: (size - s.size.width) / 2,
                                  y: (size - s.size.height) / 2,
                                  width: s.size.width,
                                  height: s.size.height))
            }
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    /// Capsule-shaped status indicator for the HUD limit button.
    static func statusPill(color: UIColor,
                           size: CGSize = CGSize(width: 44, height: 22)) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: size.height / 2)
            color.setFill()
            path.fill()
            // Thin white border for definition against the map.
            UIColor.white.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    /// Small solid dot — used as the recording indicator.
    static func dot(color: UIColor, size: CGFloat = 14) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let image = renderer.image { _ in
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            let path = UIBezierPath(ovalIn: rect)
            color.setFill()
            path.fill()
        }
        return image.withRenderingMode(.alwaysOriginal)
    }
}
