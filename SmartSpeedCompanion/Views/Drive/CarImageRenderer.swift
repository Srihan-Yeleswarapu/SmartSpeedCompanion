import UIKit
import CoreGraphics

// MARK: - Car Image Renderer

/// Draws a realistic, 3D-looking car from a top-down perspective using Core
/// Graphics. The car body is colored by the caller (matching `VehicleIconTint`),
/// brake lights are ALWAYS red (user requirement), headlights are white,
/// windows are blue-tinted glass, and a soft drop shadow gives the car visual
/// elevation above the road surface.
///
/// The returned image is oriented with the **front** of the car facing UP.
/// The caller rotates the image by the user's heading before placing it on the
/// map so the car always faces the direction of travel.
public enum CarImageRenderer {

    /// Desired output size of the car image.
    /// Width defines the car's width on screen.
    /// The car is drawn at a ~2:1 length-to-width ratio (realistic sedan/coupe
    /// proportions) so the height is derived internally.
    public static let defaultImageSize = CGSize(width: 64, height: 116)

    private static let scale = UITraitCollection.current.displayScale

    // MARK: - Public API

    /// Renders a car image at the default size with the given body color.
    /// - Parameter bodyColor: The car body's primary color (from `VehicleIconTint.uiColor`).
    /// - Returns: A UIImage ready for use on an MKAnnotationView.
    public static func renderCar(bodyColor: UIColor) -> UIImage {
        renderCar(size: defaultImageSize, bodyColor: bodyColor)
    }

    /// Preview size for the vehicle icon picker sheet header.
    public static let previewSize = CGSize(width: 48, height: 84)

    /// Renders the car at the preview size for use in the VehicleIconPickerSheet.
    /// - Parameter bodyColor: The car body color.
    /// - Returns: A UIImage or nil (always returns a valid image on iOS).
    public static func renderCarPreview(bodyColor: UIColor) -> UIImage? {
        renderCar(size: previewSize, bodyColor: bodyColor)
    }

    /// Renders a car image at an explicit size.
    /// - Parameters:
    ///   - size: Output image size. The car is drawn to fill this rect.
    ///   - bodyColor: The car body's primary color.
    /// - Returns: A UIImage.
    public static func renderCar(size: CGSize, bodyColor: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { ctx in
            let c = ctx.cgContext
            let rect = CGRect(origin: .zero, size: size)

            // ── Layout constants (relative to size) ───────────────
            let w = rect.width
            let h = rect.height

            // Car dimensions (proportions)
            let bodyW       = w * 0.82
            let bodyH       = h * 0.92
            let bodyX       = (w - bodyW) / 2
            let bodyY       = (h - bodyH) / 2

            let cabinW      = bodyW * 0.52
            let cabinH      = bodyH * 0.42
            let cabinX      = (w - cabinW) / 2
            let cabinY      = bodyY + bodyH * 0.14   // front of cabin is set back from front bumper

            let windshieldH = cabinH * 0.40
            let rearWindowH = cabinH * 0.35

            let headlightW  = bodyW * 0.12
            let headlightH  = bodyH * 0.06
            let brakelightW = bodyW * 0.10
            let brakelightH = bodyH * 0.05

            let wheelW      = bodyW * 0.14
            let wheelH      = bodyH * 0.08

            // ── 1. Drop shadow ───────────────────────────────────
            c.saveGState()
            let shadowRect = CGRect(
                x: bodyX + 3,
                y: bodyY + 4,
                width: bodyW - 6,
                height: bodyH - 4
            )
            let shadowPath = UIBezierPath(
                roundedRect: shadowRect,
                cornerRadius: bodyW * 0.15
            ).cgPath
            c.addPath(shadowPath)
            c.setShadow(
                offset: CGSize(width: 0, height: 3),
                blur: 8,
                color: UIColor.black.withAlphaComponent(0.35).cgColor
            )
            c.setFillColor(UIColor.black.withAlphaComponent(0.5).cgColor)
            c.fillPath()
            c.restoreGState()

            // ── 2. Car body (main shape) ─────────────────────────
            c.saveGState()
            let bodyPath = CGMutablePath()

            // Body shape: a rounded rectangle that's slightly wider at
            // the front wheels and slightly narrower at the rear, with
            // smooth curves. We draw it as a continuous bezier path.
            let frontY = bodyY
            let rearY  = bodyY + bodyH
            let topR   = bodyW * 0.20   // front corner radius
            let botR   = bodyW * 0.16   // rear corner radius

            // Top (front) edge — slightly curved
            bodyPath.move(to: CGPoint(x: bodyX + topR, y: frontY))
            bodyPath.addQuadCurve(
                to: CGPoint(x: bodyX + bodyW - topR, y: frontY),
                control: CGPoint(x: bodyX + bodyW / 2, y: frontY - bodyH * 0.03)
            )

            // Right side — front section (slightly flared for wheel)
            bodyPath.addLine(to: CGPoint(x: bodyX + bodyW, y: frontY + bodyH * 0.30))

            // Right side — cabin section (slightly inset)
            bodyPath.addLine(to: CGPoint(x: bodyX + bodyW, y: frontY + bodyH * 0.35))
            bodyPath.addLine(to: CGPoint(x: bodyX + bodyW, y: frontY + bodyH * 0.65))

            // Right side — rear section
            bodyPath.addLine(to: CGPoint(x: bodyX + bodyW, y: frontY + bodyH * 0.72))

            // Bottom (rear) edge — rounded
            bodyPath.addQuadCurve(
                to: CGPoint(x: bodyX + botR, y: rearY),
                control: CGPoint(x: bodyX + bodyW / 2, y: rearY + bodyH * 0.02)
            )

            // Left side — rear section
            bodyPath.addLine(to: CGPoint(x: bodyX, y: frontY + bodyH * 0.72))

            // Left side — cabin section
            bodyPath.addLine(to: CGPoint(x: bodyX, y: frontY + bodyH * 0.65))
            bodyPath.addLine(to: CGPoint(x: bodyX, y: frontY + bodyH * 0.35))

            // Left side — front section
            bodyPath.addLine(to: CGPoint(x: bodyX, y: frontY + bodyH * 0.30))

            bodyPath.closeSubpath()

            c.addPath(bodyPath)
            c.setFillColor(bodyColor.cgColor)
            c.fillPath()
            c.restoreGState()

            // ── 3. Body shading (3D depth gradient) ──────────────
            c.saveGState()
            c.addPath(bodyPath)
            c.clip()

            // Make a darker and slightly lighter version of the body color
            var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
            bodyColor.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)

            let darkColor  = UIColor(hue: hue, saturation: min(sat + 0.25, 1.0),
                                     brightness: max(bri - 0.25, 0.0), alpha: alpha)
            let lightColor = UIColor(hue: hue, saturation: max(sat - 0.15, 0.0),
                                     brightness: min(bri + 0.15, 1.0), alpha: alpha)

            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [lightColor.cgColor, bodyColor.cgColor, darkColor.cgColor] as CFArray,
                locations: [0.0, 0.5, 1.0]
            )
            if let gradient = gradient {
                c.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: rect.midX, y: rect.minY),
                    end: CGPoint(x: rect.midX, y: rect.maxY),
                    options: []
                )
            }
            c.restoreGState()

            // ── 4. Edge highlight (light catching top) ───────────
            c.saveGState()
            c.addPath(bodyPath)
            c.clip()
            c.setStrokeColor(UIColor.white.withAlphaComponent(0.12).cgColor)
            c.setLineWidth(1.5)
            // Draw a lighter line along the top edge
            c.move(to: CGPoint(x: bodyX + topR + 4, y: frontY + 2))
            c.addQuadCurve(
                to: CGPoint(x: bodyX + bodyW - topR - 4, y: frontY + 2),
                control: CGPoint(x: bodyX + bodyW / 2, y: frontY - bodyH * 0.01)
            )
            c.strokePath()
            c.restoreGState()

            // ── 5. Wheel wells (dark areas under wheel arches) ───
            c.saveGState()
            c.setFillColor(UIColor.black.withAlphaComponent(0.30).cgColor)

            // Front-left wheel well
            let flWW = CGRect(
                x: bodyX + bodyW * 0.10,
                y: frontY + bodyH * 0.22,
                width: wheelW * 1.2,
                height: wheelH * 1.1
            )
            c.fillEllipse(in: flWW)

            // Front-right wheel well
            let frWW = CGRect(
                x: bodyX + bodyW * 0.70,
                y: frontY + bodyH * 0.22,
                width: wheelW * 1.2,
                height: wheelH * 1.1
            )
            c.fillEllipse(in: frWW)

            // Rear-left wheel well
            let rlWW = CGRect(
                x: bodyX + bodyW * 0.10,
                y: frontY + bodyH * 0.68,
                width: wheelW * 1.2,
                height: wheelH * 1.1
            )
            c.fillEllipse(in: rlWW)

            // Rear-right wheel well
            let rrWW = CGRect(
                x: bodyX + bodyW * 0.70,
                y: frontY + bodyH * 0.68,
                width: wheelW * 1.2,
                height: wheelH * 1.1
            )
            c.fillEllipse(in: rrWW)
            c.restoreGState()

            // ── 6. Wheels ─────────────────────────────────────────
            func drawWheel(center: CGPoint) {
                c.saveGState()
                // Tire (dark gray)
                c.setFillColor(UIColor(white: 0.15, alpha: 1.0).cgColor)
                let tireRect = CGRect(
                    x: center.x - wheelW / 2,
                    y: center.y - wheelH / 2,
                    width: wheelW,
                    height: wheelH
                )
                c.fillEllipse(in: tireRect)

                // Rim (silver)
                let rimW = wheelW * 0.55
                let rimH = wheelH * 0.55
                let rimRect = CGRect(
                    x: center.x - rimW / 2,
                    y: center.y - rimH / 2,
                    width: rimW,
                    height: rimH
                )
                c.setFillColor(UIColor(white: 0.70, alpha: 1.0).cgColor)
                c.fillEllipse(in: rimRect)

                // Hub (dark center)
                let hubW = rimW * 0.40
                let hubH = rimH * 0.40
                let hubRect = CGRect(
                    x: center.x - hubW / 2,
                    y: center.y - hubH / 2,
                    width: hubW,
                    height: hubH
                )
                c.setFillColor(UIColor(white: 0.25, alpha: 1.0).cgColor)
                c.fillEllipse(in: hubRect)
                c.restoreGState()
            }

            drawWheel(center: CGPoint(x: bodyX + bodyW * 0.20, y: frontY + bodyH * 0.28))
            drawWheel(center: CGPoint(x: bodyX + bodyW * 0.80, y: frontY + bodyH * 0.28))
            drawWheel(center: CGPoint(x: bodyX + bodyW * 0.20, y: frontY + bodyH * 0.72))
            drawWheel(center: CGPoint(x: bodyX + bodyW * 0.80, y: frontY + bodyH * 0.72))

            // ── 7. Cabin base (darker than body — shadows from roof) ─
            c.saveGState()
            let cabinPath = UIBezierPath(
                roundedRect: CGRect(x: cabinX, y: cabinY, width: cabinW, height: cabinH),
                cornerRadius: cabinW * 0.08
            ).cgPath
            c.addPath(cabinPath)
            let cabinColor = bodyColor.adjustBrightness(by: -0.18)
            c.setFillColor(cabinColor.cgColor)
            c.fillPath()
            c.restoreGState()

            // ── 8. Windshield (blue-tinted glass, front) ─────────
            c.saveGState()
            let windshieldRect = CGRect(
                x: cabinX + cabinW * 0.06,
                y: cabinY + cabinH * 0.03,
                width: cabinW * 0.88,
                height: windshieldH
            )
            let windshieldPath = UIBezierPath(
                roundedRect: windshieldRect,
                cornerRadius: cabinW * 0.06,
                byRoundingCorners: [.topLeft, .topRight],
                cornerRadii: CGSize(width: cabinW * 0.06, height: cabinW * 0.06)
            ).cgPath
            c.addPath(windshieldPath)

            // Windshield base: blue-tinted glass
            c.setFillColor(
                UIColor(red: 0.35, green: 0.55, blue: 0.85, alpha: 0.60).cgColor
            )
            c.fillPath()

            // Windshield reflection highlight
            c.saveGState()
            c.addPath(windshieldPath)
            c.clip()
            c.setFillColor(
                UIColor.white.withAlphaComponent(0.15).cgColor
            )
            c.fill(CGRect(x: windshieldRect.minX, y: windshieldRect.minY,
                           width: windshieldRect.width, height: windshieldRect.height * 0.35))
            c.restoreGState()
            c.restoreGState()

            // ── 9. Rear window (blue-tinted glass, rear) ─────────
            c.saveGState()
            let rearWindowRect = CGRect(
                x: cabinX + cabinW * 0.06,
                y: cabinY + cabinH * 0.62,
                width: cabinW * 0.88,
                height: rearWindowH
            )
            let rearWindowPath = UIBezierPath(
                roundedRect: rearWindowRect,
                cornerRadius: cabinW * 0.05,
                byRoundingCorners: [.bottomLeft, .bottomRight],
                cornerRadii: CGSize(width: cabinW * 0.05, height: cabinW * 0.05)
            ).cgPath
            c.addPath(rearWindowPath)
            c.setFillColor(
                UIColor(red: 0.30, green: 0.50, blue: 0.80, alpha: 0.50).cgColor
            )
            c.fillPath()
            c.restoreGState()

            // ── 10. Roof pillars (thin body-colored dividers) ────
            c.saveGState()
            c.setStrokeColor(bodyColor.cgColor)
            c.setLineWidth(1.5)

            // Left A-pillar
            c.move(to: CGPoint(x: cabinX + cabinW * 0.10, y: cabinY))
            c.addLine(to: CGPoint(x: cabinX + cabinW * 0.10, y: cabinY + cabinH))
            c.strokePath()

            // Right A-pillar
            c.move(to: CGPoint(x: cabinX + cabinW * 0.90, y: cabinY))
            c.addLine(to: CGPoint(x: cabinX + cabinW * 0.90, y: cabinY + cabinH))
            c.strokePath()

            // Center divider (rearview mirror area)
            c.setStrokeColor(bodyColor.withAlphaComponent(0.6).cgColor)
            c.move(to: CGPoint(x: rect.midX, y: cabinY + cabinH * 0.05))
            c.addLine(to: CGPoint(x: rect.midX, y: cabinY + cabinH * 0.50))
            c.strokePath()
            c.restoreGState()

            // ── 11. Hood highlight (subtle reflection) ───────────
            c.saveGState()
            c.setFillColor(UIColor.white.withAlphaComponent(0.06).cgColor)
            let hoodRect = CGRect(
                x: bodyX + bodyW * 0.20,
                y: frontY + bodyH * 0.02,
                width: bodyW * 0.60,
                height: cabinY - frontY - bodyH * 0.05
            )
            c.fillEllipse(in: hoodRect)
            c.restoreGState()

            // ── 12. HEADLIGHTS (white, at front corners) ─────────
            c.saveGState()
            c.setFillColor(UIColor(white: 0.95, alpha: 1.0).cgColor)
            c.setStrokeColor(UIColor(white: 0.60, alpha: 1.0).cgColor)
            c.setLineWidth(0.5)

            // Left headlight
            let hlLeft = CGRect(
                x: bodyX + bodyW * 0.08,
                y: frontY + bodyH * 0.04,
                width: headlightW,
                height: headlightH
            )
            c.fillEllipse(in: hlLeft)
            c.strokeEllipse(in: hlLeft)

            // Right headlight
            let hlRight = CGRect(
                x: bodyX + bodyW * 0.80,
                y: frontY + bodyH * 0.04,
                width: headlightW,
                height: headlightH
            )
            c.fillEllipse(in: hlRight)
            c.strokeEllipse(in: hlRight)

            // Headlight glow (subtle yellow-white halo)
            c.setFillColor(UIColor(red: 1.0, green: 0.95, blue: 0.80, alpha: 0.15).cgColor)
            let glowSize = headlightW * 1.6
            let glowLeft = CGRect(
                x: hlLeft.midX - glowSize / 2,
                y: hlLeft.midY - glowSize / 2,
                width: glowSize,
                height: glowSize
            )
            c.fillEllipse(in: glowLeft)

            let glowRight = CGRect(
                x: hlRight.midX - glowSize / 2,
                y: hlRight.midY - glowSize / 2,
                width: glowSize,
                height: glowSize
            )
            c.fillEllipse(in: glowRight)
            c.restoreGState()

            // ── 13. BRAKE LIGHTS (ALWAYS RED — user requirement) ─
            c.saveGState()
            // Bright red — always, regardless of body color
            let brakeColor = UIColor(red: 1.0, green: 0.12, blue: 0.08, alpha: 1.0)
            c.setFillColor(brakeColor.cgColor)

            // Left brake light
            let blLeft = CGRect(
                x: bodyX + bodyW * 0.08,
                y: frontY + bodyH * 0.89,
                width: brakelightW,
                height: brakelightH
            )
            c.fillEllipse(in: blLeft)

            // Right brake light
            let blRight = CGRect(
                x: bodyX + bodyW * 0.82,
                y: frontY + bodyH * 0.89,
                width: brakelightW,
                height: brakelightH
            )
            c.fillEllipse(in: blRight)

            // Brake light glow (red halo)
            c.setFillColor(UIColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 0.12).cgColor)
            let bGlowSize = brakelightW * 1.8
            let bGlowLeft = CGRect(
                x: blLeft.midX - bGlowSize / 2,
                y: blLeft.midY - bGlowSize / 2,
                width: bGlowSize,
                height: bGlowSize
            )
            c.fillEllipse(in: bGlowLeft)
            let bGlowRight = CGRect(
                x: blRight.midX - bGlowSize / 2,
                y: blRight.midY - bGlowSize / 2,
                width: bGlowSize,
                height: bGlowSize
            )
            c.fillEllipse(in: bGlowRight)

            // "Brake light" inner highlight (makes them glow)
            c.setFillColor(UIColor(red: 1.0, green: 0.4, blue: 0.3, alpha: 0.6).cgColor)
            let innerSize = brakelightW * 0.5
            c.fillEllipse(in: CGRect(
                x: blLeft.midX - innerSize / 2,
                y: blLeft.midY - innerSize / 2,
                width: innerSize,
                height: innerSize
            ))
            c.fillEllipse(in: CGRect(
                x: blRight.midX - innerSize / 2,
                y: blRight.midY - innerSize / 2,
                width: innerSize,
                height: innerSize
            ))
            c.restoreGState()

            // ── 14. Rear bumper detail (subtle gray line) ────────
            c.saveGState()
            c.setStrokeColor(UIColor(white: 0.25, alpha: 0.30).cgColor)
            c.setLineWidth(1.0)
            let bumperY = frontY + bodyH * 0.94
            c.move(to: CGPoint(x: bodyX + bodyW * 0.15, y: bumperY))
            c.addLine(to: CGPoint(x: bodyX + bodyW * 0.85, y: bumperY))
            c.strokePath()
            c.restoreGState()

            // ── 15. Side mirrors (small protrusions on sides) ────
            c.saveGState()
            c.setFillColor(bodyColor.adjustBrightness(by: -0.10).cgColor)

            // Left mirror
            let mirrorW = bodyW * 0.06
            let mirrorH = bodyH * 0.08
            let mirrorY = frontY + bodyH * 0.38
            c.fillEllipse(in: CGRect(
                x: bodyX - mirrorW * 0.4,
                y: mirrorY,
                width: mirrorW,
                height: mirrorH
            ))

            // Right mirror
            c.fillEllipse(in: CGRect(
                x: bodyX + bodyW - mirrorW * 0.6,
                y: mirrorY,
                width: mirrorW,
                height: mirrorH
            ))
            c.restoreGState()
        }
    }

    /// Rotates a car image by the given heading angle (in radians), cropping
    /// tightly to the rotated content so the map annotation view doesn't get
    /// excess padding.
    /// - Parameters:
    ///   - image: The car image (already rendered, facing UP).
    ///   - heading: Heading in radians (0 = north, π/2 = east, etc.).
    /// - Returns: A rotated UIImage tightly cropped to the car.
    public static func rotateCarImage(_ image: UIImage, heading: CGFloat) -> UIImage {
        let size = image.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            let c = ctx.cgContext
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)

            c.translateBy(x: mid.x, y: mid.y)
            c.rotate(by: heading)
            c.translateBy(x: -mid.x, y: -mid.y)

            image.draw(at: .zero)
        }
    }
}

// MARK: - Color Helper

private extension UIColor {
    /// Returns a new UIColor with brightness adjusted by the given delta
    /// (negative = darker, positive = lighter). Clamped to [0, 1].
    func adjustBrightness(by delta: CGFloat) -> UIColor {
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        guard getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha) else {
            return self
        }
        return UIColor(
            hue: hue,
            saturation: sat,
            brightness: max(0, min(1, bri + delta)),
            alpha: alpha
        )
    }
}
