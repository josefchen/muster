// Renders Muster's app icon: three stacked glass session cards in the agents'
// colours on a deep squircle. Run: swift Resources/icon.swift <out.iconset>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body with soft shadow.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225
    let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(squircle)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(srgbRed: 0.16, green: 0.17, blue: 0.22, alpha: 1).cgColor,
        NSColor(srgbRed: 0.05, green: 0.05, blue: 0.08, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY), options: [])

    // Three session cards, back to front: violet, blue, amber.
    let cards: [(NSColor, CGFloat, CGFloat)] = [
        (NSColor(srgbRed: 0.62, green: 0.40, blue: 0.98, alpha: 1), 0.62, 0.80),
        (NSColor(srgbRed: 0.27, green: 0.52, blue: 0.98, alpha: 1), 0.50, 0.88),
        (NSColor(srgbRed: 0.96, green: 0.58, blue: 0.22, alpha: 1), 0.36, 0.96),
    ]
    for (colour, centreY, widthFactor) in cards {
        let w = body.width * 0.66 * widthFactor
        let h = body.height * 0.20
        let r = CGRect(x: body.midX - w / 2, y: body.minY + body.height * centreY - h / 2, width: w, height: h)
        let path = CGPath(roundedRect: r, cornerWidth: h * 0.32, cornerHeight: h * 0.32, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.008), blur: s * 0.025, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.addPath(path)
        ctx.setFillColor(colour.withAlphaComponent(0.92).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            NSColor.white.withAlphaComponent(0.38).cgColor, NSColor.white.withAlphaComponent(0.0).cgColor] as CFArray,
                               locations: [0, 1])!
        ctx.drawLinearGradient(sheen, start: CGPoint(x: r.midX, y: r.maxY), end: CGPoint(x: r.midX, y: r.midY), options: [])
        ctx.restoreGState()

        let dot = h * 0.34
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
        ctx.fillEllipse(in: CGRect(x: r.minX + h * 0.33, y: r.midY - dot / 2, width: dot, height: dot))
        let bar = CGRect(x: r.minX + h * 0.33 + dot + h * 0.28, y: r.midY - h * 0.07, width: w * 0.42, height: h * 0.14)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: bar.height / 2, cornerHeight: bar.height / 2, transform: nil))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        ctx.fillPath()
    }

    // Glass rim.
    ctx.addPath(squircle)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
    ctx.setLineWidth(s * 0.006)
    ctx.strokePath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
