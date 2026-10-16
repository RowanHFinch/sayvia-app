import SwiftUI
import AppKit

/// The Sayvia mark: five symmetric voice bars cut by one S-shaped path.
/// Geometry lives in a 1024 canvas (macOS icon grid) so every size draws the same shape.
enum SayviaBrand {
    static let ink = Color(red: 0.102, green: 0.098, blue: 0.094)
    static let creamTop = Color(red: 0.984, green: 0.973, blue: 0.945)
    static let creamBottom = Color(red: 0.933, green: 0.910, blue: 0.863)
    private static let barPitch: CGFloat = 102
    private static let barHeights: [CGFloat] = [230, 380, 480, 380, 230]
    /// Bounding box of the mark inside the 1024 canvas.
    static let markBounds = CGRect(x: 268, y: 272, width: 488, height: 480)

    /// Draws the mark with `canvas` mapped onto the 1024 grid, in top-left-origin coordinates.
    /// `barWidth` and `cutWidth` are in 1024-grid units; the menu bar uses lighter strokes.
    static func drawMark(in cg: CGContext, canvas: CGRect, color: CGColor, barWidth: CGFloat = 80, cutWidth: CGFloat = 46) {
        let k = canvas.width / 1024
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: canvas.minX + x * k, y: canvas.minY + y * k) }
        cg.saveGState(); cg.beginTransparencyLayer(auxiliaryInfo: nil)
        cg.setFillColor(color)
        func bars(_ indices: [Int]) {
            for i in indices {
                // Bars keep their centers when thinned, so the S still lands in the gaps.
                let h = barHeights[i], origin = p(308 + CGFloat(i) * barPitch - barWidth / 2, 512 - h / 2)
                cg.addPath(CGPath(roundedRect: CGRect(origin: origin, size: CGSize(width: barWidth * k, height: h * k)), cornerWidth: barWidth * k / 2, cornerHeight: barWidth * k / 2, transform: nil))
            }
            cg.fillPath()
        }
        bars([1, 2, 3])
        // Clearing inside the transparency layer subtracts the S from the bars only.
        cg.setBlendMode(.clear); cg.setLineWidth(cutWidth * k); cg.setLineCap(.butt)
        cg.move(to: p(350, 320))
        cg.addCurve(to: p(512, 512), control1: p(346, 480), control2: p(430, 500))
        cg.addCurve(to: p(674, 704), control1: p(594, 524), control2: p(678, 544))
        cg.strokePath()
        // The S passes through the middle three bars only; the outer bars stay whole.
        cg.setBlendMode(.normal); bars([0, 4])
        cg.endTransparencyLayer(); cg.restoreGState()
    }

    /// Monochrome template for the menu bar; AppKit tints it for light and dark bars.
    /// Thinner bars (≈1.5 pt) and cut keep it as light as the system's own glyphs.
    static let menuBarImage: NSImage = {
        let size = NSSize(width: 17, height: 16)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let k = 14 / markBounds.height
            let canvas = CGRect(x: rect.midX - 512 * k, y: rect.midY - 512 * k, width: 1024 * k, height: 1024 * k)
            drawMark(in: cg, canvas: canvas, color: NSColor.black.cgColor, barWidth: 1.55 / k, cutWidth: 1.25 / k)
            return true
        }
        image.isTemplate = true; image.accessibilityDescription = "Sayvia"
        return image
    }()
}

/// Mark only, filling the view's 1024-grid canvas.
struct SayviaMark: View {
    var color: Color = SayviaBrand.ink
    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let canvas = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
            context.withCGContext { SayviaBrand.drawMark(in: $0, canvas: canvas, color: NSColor(color).cgColor) }
        }.accessibilityHidden(true)
    }
}

/// Full-bleed cream logo used inside the app (sidebar, onboarding).
struct SayviaLogo: View {
    var size: CGFloat = 22
    var body: some View {
        let k = size / 824
        ZStack {
            RoundedRectangle(cornerRadius: 185 * k, style: .continuous)
                .fill(LinearGradient(colors: [SayviaBrand.creamTop, SayviaBrand.creamBottom], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 185 * k, style: .continuous).strokeBorder(.black.opacity(0.1), lineWidth: max(0.5, 8 * k))
            // The 1024 grid has a 100-unit margin around the 824 squircle.
            SayviaMark().frame(width: 1024 * k, height: 1024 * k)
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 185 * k, style: .continuous))
            .accessibilityLabel("Sayvia")
    }
}

/// App icon on the standard 1024 macOS grid, including its drop shadow.
struct SayviaAppIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [SayviaBrand.creamTop, SayviaBrand.creamBottom], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous).strokeBorder(.black.opacity(0.07), lineWidth: 2))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.22), radius: 14, y: 12)
            SayviaMark()
        }.frame(width: 1024, height: 1024)
    }

    /// Writes an .iconset for `iconutil`; used by scripts/build-app.sh.
    @MainActor static func renderIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let renderer = ImageRenderer(content: SayviaAppIcon())
                renderer.scale = CGFloat(points * scale) / 1024
                guard let image = renderer.cgImage else { throw AppError("Icon rendering failed.") }
                guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw AppError("Icon encoding failed.") }
                try data.write(to: directory.appendingPathComponent("icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"))
            }
        }
    }
}
