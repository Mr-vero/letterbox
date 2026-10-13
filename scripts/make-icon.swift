// Renders the Letterbox app icon into an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset> [preview.png]
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    let space = CGColorSpaceCreateDeviceRGB()

    // Paper tile with a soft shadow (macOS icon grid: 824pt tile, 100pt margin).
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.22).cgColor)
    ctx.addPath(tilePath); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let paper = CGGradient(colorsSpace: space, colors: [
        NSColor(red: 0.992, green: 0.989, blue: 0.980, alpha: 1).cgColor,
        NSColor(red: 0.925, green: 0.918, blue: 0.900, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(paper, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()
    ctx.addPath(tilePath)
    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.08).cgColor)
    ctx.setLineWidth(3)
    ctx.strokePath()

    // Ink envelope.
    let ink = NSColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1).cgColor
    let env = CGRect(x: 262, y: 334, width: 500, height: 356)
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(30)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    ctx.addPath(CGPath(roundedRect: env, cornerWidth: 46, cornerHeight: 46, transform: nil))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: env.minX + 40, y: env.maxY - 44))
    ctx.addLine(to: CGPoint(x: env.midX, y: env.midY - 6))
    ctx.addLine(to: CGPoint(x: env.maxX - 40, y: env.maxY - 44))
    ctx.strokePath()

    // Unread dot.
    let dot = CGRect(x: env.maxX - 54, y: env.maxY - 54, width: 108, height: 108)
    ctx.setFillColor(NSColor(red: 0.992, green: 0.989, blue: 0.980, alpha: 1).cgColor)
    ctx.fillEllipse(in: dot.insetBy(dx: -22, dy: -22))
    ctx.setFillColor(NSColor(red: 0.18, green: 0.36, blue: 0.83, alpha: 1).cgColor)
    ctx.fillEllipse(in: dot)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
if CommandLine.arguments.count > 2 {
    try! render(512).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
