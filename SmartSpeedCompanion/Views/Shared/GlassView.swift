import SwiftUI

// MARK: - Liquid Glass Modifiers

/// A set of view modifiers that apply Apple's native Liquid Glass from iOS 26+,
/// with a fully featured multi-layer fallback for earlier iOS versions.
///
/// **iOS 26+ path** uses the system `glassEffect(.regular.tint(...).interactive(), in:)`
/// modifier — the native Apple API with built-in blur, reflection, and touch reactivity.
///
/// **Fallback path** (< iOS 26) uses our custom multi-layer ZStack with ultra-thin
/// material, vibrancy tint, top gradient glow, inner shadow, refractive border,
/// edge highlight, and depth shadow.
///
/// Use `.liquidGlass()` for card/panel surfaces, `.liquidGlassChip()` for compact
/// pills, and `.interactive` only for tappable elements.
public extension View {

    /// Full Liquid Glass panel — ideal for cards, floating widgets, and containers.
    /// - Parameters:
    ///   - cornerRadius: Corner radius for the glass shape (default 20).
    ///   - hasInnerGlow: Whether to render the top gradient glow + edge highlight (default true).
    ///   - tint: Optional accent color overlay (e.g. `.cyan.opacity(0.06)` for branded glass).
    ///   - interactive: Whether the glass responds to touch/pointer (default false). Only for tappable elements.
    /// Full Liquid Glass panel — ideal for cards, floating widgets, and containers.
    /// Built with a custom multi-layer ZStack for full rendering control.
    /// - Parameters:
    ///   - cornerRadius: Corner radius for the glass shape (default 20).
    ///   - hasInnerGlow: Whether to render the top gradient glow + edge highlight (default true).
    ///   - tint: Optional accent color overlay (e.g. `.cyan.opacity(0.06)` for branded glass).
    ///   - interactive: Reserved for future native API adoption (currently no-op).
    func liquidGlass(cornerRadius: CGFloat = DesignSystem.LiquidGlass.cornerRadius,
                     hasInnerGlow: Bool = true,
                     tint: Color? = nil,
                     interactive: Bool = false) -> some View {
        _fallbackGlass(cornerRadius: cornerRadius, hasInnerGlow: hasInnerGlow, tint: tint)
    }

    /// Compact Liquid Glass chip — zero extra padding, minimal shadow.
    /// Perfect for inline pills, badges, and small controls.
    /// - Parameters:
    ///   - cornerRadius: Corner radius for the glass shape (default 14).
    ///   - tint: Optional accent color overlay.
    ///   - interactive: Reserved for future native API adoption (currently no-op).
    func liquidGlassChip(cornerRadius: CGFloat = 14,
                         tint: Color? = nil,
                         interactive: Bool = false) -> some View {
        _fallbackGlassChip(cornerRadius: cornerRadius, tint: tint)
    }

    // MARK: - Implementation

    private func _fallbackGlass(cornerRadius: CGFloat, hasInnerGlow: Bool, tint: Color?) -> some View {
        self
            .padding()
            .background(
                ZStack {
                    // Layer 1: Ultra-thin material (the core blur)
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(DesignSystem.LiquidGlass.material)
                    
                    // Layer 2: Vibrancy tint (boosts readability)
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(DesignSystem.LiquidGlass.vibrancyTint)
                    
                    // Layer 3: Optional branded tint
                    if let tintColor = tint {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(tintColor)
                    }
                    
                    // Layer 4: Top gradient glow (light hitting glass edge)
                    if hasInnerGlow {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(
                                LinearGradient(
                                    colors: [DesignSystem.LiquidGlass.topGlowColor, .clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                    
                    // Layer 5: Inner shadow (subtle dark bevel)
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(DesignSystem.LiquidGlass.innerShadowColor, lineWidth: 1)
                        .padding(0.5)
                }
            )
            .cornerRadius(cornerRadius)
            .overlay(
                ZStack {
                    // Layer 6: Main refractive edge
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(DesignSystem.LiquidGlass.borderColor,
                                lineWidth: DesignSystem.LiquidGlass.borderWidth)
                    
                    // Layer 7: Edge highlight (light catch on top-leading edge)
                    if hasInnerGlow {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        DesignSystem.LiquidGlass.edgeHighlightColor,
                                        .clear,
                                        .clear
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: DesignSystem.LiquidGlass.edgeHighlightWidth
                            )
                    }
                }
            )
            .shadow(
                color: DesignSystem.LiquidGlass.shadowColor,
                radius: DesignSystem.LiquidGlass.shadowRadius,
                x: DesignSystem.LiquidGlass.shadowX,
                y: DesignSystem.LiquidGlass.shadowY
            )
    }

    private func _fallbackGlassChip(cornerRadius: CGFloat, tint: Color?) -> some View {
        self
            .background(
                ZStack {
                    // Layer 1: Ultra-thin material
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(DesignSystem.LiquidGlass.material)
                    
                    // Layer 2: Vibrancy tint
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(DesignSystem.LiquidGlass.vibrancyTint)
                    
                    // Layer 3: Optional branded tint
                    if let tintColor = tint {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(tintColor)
                    }
                }
            )
            .cornerRadius(cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(DesignSystem.LiquidGlass.borderColor,
                            lineWidth: DesignSystem.LiquidGlass.borderWidth)
            )
            .shadow(
                color: DesignSystem.LiquidGlass.shadowColor.opacity(0.6),
                radius: 8,
                x: 0,
                y: 4
            )
    }
}

// MARK: - Legacy GlassView (kept for backward compatibility)

public struct GlassView<Content: View>: View {
    var cornerRadius: CGFloat
    var content: () -> Content
    
    public init(cornerRadius: CGFloat = DesignSystem.LiquidGlass.cornerRadius,
                @ViewBuilder content: @escaping () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content
    }
    
    public var body: some View {
        content()
            .liquidGlass(cornerRadius: cornerRadius)
    }
}

// MARK: - Deprecated glassStyle

/// ⚠️ Legacy modifier — kept so existing callers compile without errors.
/// Prefer `.liquidGlass()` or `.liquidGlassChip()` for new code.
public extension View {
    func glassStyle(cornerRadius: CGFloat = DesignSystem.LiquidGlass.cornerRadius) -> some View {
        self
            .padding()
            .background(DesignSystem.LiquidGlass.material)
            .background(DesignSystem.glassVibrancy)
            .cornerRadius(cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(DesignSystem.glassBorder, lineWidth: DesignSystem.LiquidGlass.borderWidth)
            )
            .shadow(color: DesignSystem.LiquidGlass.shadowColor, radius: DesignSystem.LiquidGlass.shadowRadius, x: 0, y: 10)
    }
}