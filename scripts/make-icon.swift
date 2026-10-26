// Draws the app icon and writes Resources/AppIcon.icns.
//   swift scripts/make-icon.swift
//
// A core in orbit: the hub everything on the Mac is reached from. Candidates are drawn
// side by side by scripts/make-icon-options.swift.
import AppKit

let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    // macOS icon grid: the shape fills about 80% of the canvas.
    let inset = size * 0.1
    let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)

    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = size * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.008)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSShadow().set()

    NSGradient(colors: [
        NSColor(red: 0.05, green: 0.07, blue: 0.18, alpha: 1),
        NSColor(red: 0.18, green: 0.13, blue: 0.56, alpha: 1),
        NSColor(red: 0.62, green: 0.18, blue: 0.70, alpha: 1),
    ])!.draw(in: shape, angle: -60)

    // Soft top highlight.
    NSGradient(colors: [.white.withAlphaComponent(0.22), .white.withAlphaComponent(0)])!
        .draw(in: shape, angle: -90)

    let centre = NSPoint(x: tile.midX, y: tile.midY)
    let accent = NSColor(red: 0.45, green: 0.98, blue: 0.90, alpha: 1)

    // Two tilted ellipses and a circle: an orbit read from the side and from above.
    // The strokes thicken a little at small sizes, where a hairline would disappear.
    let weight = pixels <= 32 ? 0.030 : 0.018
    for (index, tilt) in [CGFloat(-28), 28, 90].enumerated() {
        let isCircle = index == 2
        let width = tile.width * (isCircle ? 0.46 : 0.62)
        let height = tile.width * (isCircle ? 0.46 : 0.24)
        let ring = NSBezierPath(ovalIn: NSRect(
            x: -width / 2, y: -height / 2, width: width, height: height
        ))
        let turn = NSAffineTransform()
        turn.translateX(by: centre.x, yBy: centre.y)
        turn.rotate(byDegrees: tilt)
        ring.transform(using: turn as AffineTransform)
        ring.lineWidth = size * weight
        accent.withAlphaComponent(isCircle ? 0.9 : 0.6).setStroke()
        ring.stroke()
    }

    let core = size * 0.075
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: centre.x - core, y: centre.y - core, width: core * 2, height: core * 2)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try render(pixels: points).write(to: iconset.appending(path: "icon_\(points)x\(points).png"))
    try render(pixels: points * 2).write(to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}

let output = root.appending(path: "Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(filePath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path(percentEncoded: false), "-o", output.path(percentEncoded: false)]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote \(output.path(percentEncoded: false))" : "iconutil failed")
