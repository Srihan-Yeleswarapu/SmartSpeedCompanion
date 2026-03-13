import SwiftUI

public struct GlassView<Content: View>: View {
    var cornerRadius: CGFloat
    var content: () -> Content
    
    public init(cornerRadius: CGFloat = DesignSystem.LiquidGlass.cornerRadius, @ViewBuilder content: @escaping () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content
    }
    
    public var body: some View {
        content()
            .padding()
            .background(
                DesignSystem.LiquidGlass.material
                    .background(DesignSystem.glassVibrancy)
            )
            .cornerRadius(cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(DesignSystem.glassBorder, lineWidth: DesignSystem.LiquidGlass.borderWidth)
            )
            .shadow(color: DesignSystem.LiquidGlass.shadowColor, radius: DesignSystem.LiquidGlass.shadowRadius, x: 0, y: 10)
    }
}

public extension View {
    func glassStyle(cornerRadius: CGFloat = DesignSystem.LiquidGlass.cornerRadius) -> some View {
        self
            .padding()
            .background(
                DesignSystem.LiquidGlass.material
                    .background(DesignSystem.glassVibrancy)
            )
            .cornerRadius(cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(DesignSystem.glassBorder, lineWidth: DesignSystem.LiquidGlass.borderWidth)
            )
            .shadow(color: DesignSystem.LiquidGlass.shadowColor, radius: DesignSystem.LiquidGlass.shadowRadius, x: 0, y: 10)
    }
}
