// Draws the app icon and writes Resources/AppIcon.icns.
//   swift scripts/make-icon.swift
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
        NSColor(red: 0.20, green: 0.84, blue: 0.82, alpha: 1),
        NSColor(red: 0.16, green: 0.42, blue: 0.95, alpha: 1),
        NSColor(red: 0.40, green: 0.22, blue: 0.86, alpha: 1),
    ])!.draw(in: shape, angle: -60)

    // Soft top highlight.
    NSGradient(colors: [.white.withAlphaComponent(0.28), .white.withAlphaComponent(0)])!
        .draw(in: shape, angle: -90)

    let configuration = NSImage.SymbolConfiguration(pointSize: tile.width * 0.5, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
    {
        let symbolSize = symbol.size
        let origin = NSPoint(x: tile.midX - symbolSize.width / 2, y: tile.midY - symbolSize.height / 2)
        symbol.draw(in: NSRect(origin: origin, size: symbolSize))
    }

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
