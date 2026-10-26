// Draws three candidate app icons side by side for choosing between.
//   swift scripts/make-icon-options.swift <output.png>
import AppKit

let output = CommandLine.arguments.count > 1
    ? URL(filePath: CommandLine.arguments[1])
    : URL(filePath: "icon-options.png")

/// The rounded square macOS puts every app icon on.
func tile(in size: CGFloat) -> (shape: NSBezierPath, rect: NSRect) {
    let inset = size * 0.1
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    return (NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225), rect)
}

func background(_ shape: NSBezierPath, _ colours: [NSColor], angle: CGFloat = -60) {
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 10
    shadow.shadowOffset = NSSize(width: 0, height: -4)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSShadow().set()
    NSGradient(colors: colours)!.draw(in: shape, angle: angle)
    NSGradient(colors: [.white.withAlphaComponent(0.22), .white.withAlphaComponent(0)])!
        .draw(in: shape, angle: -90)
}

/// A hub: a bright core with spokes out to the things it gathers.
func drawHub(_ size: CGFloat) {
    let (shape, rect) = tile(in: size)
    background(shape, [
        NSColor(red: 0.07, green: 0.11, blue: 0.24, alpha: 1),
        NSColor(red: 0.12, green: 0.25, blue: 0.62, alpha: 1),
        NSColor(red: 0.33, green: 0.16, blue: 0.78, alpha: 1),
    ])

    let centre = NSPoint(x: rect.midX, y: rect.midY)
    let radius = rect.width * 0.30
    let accent = NSColor(red: 0.35, green: 0.95, blue: 0.93, alpha: 1)

    for index in 0 ..< 6 {
        let angle = CGFloat(index) / 6 * .pi * 2 + .pi / 6
        let node = NSPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)

        let spoke = NSBezierPath()
        spoke.move(to: centre)
        spoke.line(to: node)
        spoke.lineWidth = size * 0.016
        spoke.lineCapStyle = .round
        accent.withAlphaComponent(0.55).setStroke()
        spoke.stroke()

        let dot = size * 0.052
        accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: node.x - dot, y: node.y - dot, width: dot * 2, height: dot * 2)).fill()
    }

    let core = size * 0.085
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: centre.x - core, y: centre.y - core, width: core * 2, height: core * 2)).fill()
}

/// A control centre: rings in orbit around a core.
func drawOrbit(_ size: CGFloat) {
    let (shape, rect) = tile(in: size)
    background(shape, [
        NSColor(red: 0.05, green: 0.07, blue: 0.18, alpha: 1),
        NSColor(red: 0.18, green: 0.13, blue: 0.56, alpha: 1),
        NSColor(red: 0.62, green: 0.18, blue: 0.70, alpha: 1),
    ])

    let centre = NSPoint(x: rect.midX, y: rect.midY)
    let accent = NSColor(red: 0.45, green: 0.98, blue: 0.90, alpha: 1)

    for (index, tilt) in [CGFloat(-28), 28, 90].enumerated() {
        let width = rect.width * (index == 2 ? 0.46 : 0.62)
        let height = rect.width * (index == 2 ? 0.46 : 0.24)
        let ring = NSBezierPath(ovalIn: NSRect(
            x: -width / 2, y: -height / 2, width: width, height: height
        ))
        let turn = NSAffineTransform()
        turn.translateX(by: centre.x, yBy: centre.y)
        turn.rotate(byDegrees: tilt)
        ring.transform(using: turn as AffineTransform)
        ring.lineWidth = size * 0.018
        accent.withAlphaComponent(index == 2 ? 0.9 : 0.6).setStroke()
        ring.stroke()
    }

    let core = size * 0.075
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: centre.x - core, y: centre.y - core, width: core * 2, height: core * 2)).fill()
}

/// A hexagon, the shape of a module that fits with others, around a letter U.
func drawHex(_ size: CGFloat) {
    let (shape, rect) = tile(in: size)
    background(shape, [
        NSColor(red: 0.08, green: 0.20, blue: 0.26, alpha: 1),
        NSColor(red: 0.08, green: 0.48, blue: 0.56, alpha: 1),
        NSColor(red: 0.16, green: 0.32, blue: 0.84, alpha: 1),
    ])

    let centre = NSPoint(x: rect.midX, y: rect.midY)
    let radius = rect.width * 0.33
    let accent = NSColor(red: 0.55, green: 1.0, blue: 0.88, alpha: 1)

    let hexagon = NSBezierPath()
    for index in 0 ..< 6 {
        let angle = CGFloat(index) / 6 * .pi * 2 + .pi / 2
        let point = NSPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
        if index == 0 { hexagon.move(to: point) } else { hexagon.line(to: point) }
    }
    hexagon.close()
    hexagon.lineWidth = size * 0.022
    hexagon.lineJoinStyle = .round
    accent.withAlphaComponent(0.85).setStroke()
    hexagon.stroke()

    // A U drawn as a path rather than set in a typeface, so it scales cleanly.
    let armWidth = rect.width * 0.17
    let letter = NSBezierPath()
    letter.move(to: NSPoint(x: centre.x - armWidth, y: centre.y + radius * 0.46))
    letter.line(to: NSPoint(x: centre.x - armWidth, y: centre.y - radius * 0.08))
    letter.appendArc(
        withCenter: NSPoint(x: centre.x, y: centre.y - radius * 0.08),
        radius: armWidth, startAngle: 180, endAngle: 360, clockwise: true
    )
    letter.line(to: NSPoint(x: centre.x + armWidth, y: centre.y + radius * 0.46))
    letter.lineWidth = size * 0.055
    letter.lineCapStyle = .round
    letter.lineJoinStyle = .round
    NSColor.white.setStroke()
    letter.stroke()
}

let each = 512
let drawings: [(String, (CGFloat) -> Void)] = [("hub", drawHub), ("orbit", drawOrbit), ("hex", drawHex)]
let gap = 40
let width = each * drawings.count + gap * (drawings.count + 1)
let height = each + gap * 2

let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(white: 0.12, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

for (index, drawing) in drawings.enumerated() {
    let context = NSGraphicsContext.current!
    context.saveGraphicsState()
    let move = NSAffineTransform()
    move.translateX(by: CGFloat(gap + index * (each + gap)), yBy: CGFloat(gap))
    move.concat()
    drawing.1(CGFloat(each))
    context.restoreGraphicsState()
}

NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
print("Wrote \(output.path(percentEncoded: false)): " + drawings.map(\.0).joined(separator: ", "))
