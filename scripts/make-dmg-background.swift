// Draws the DMG window background and writes Resources/DMG/background.tiff (1x + 2x).
//   swift scripts/make-dmg-background.swift
// Icon positions in scripts/dmg-settings.py must match `appCenter` and `applicationsCenter`.
import AppKit

let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appending(path: "Resources/DMG")
let width: CGFloat = 660
let height: CGFloat = 450
let appCenter = CGPoint(x: 170, y: 150)
let applicationsCenter = CGPoint(x: 490, y: 150)

let accent = NSColor(red: 0.16, green: 0.42, blue: 0.95, alpha: 1)
let warning = NSColor(red: 0.85, green: 0.45, blue: 0.0, alpha: 1)
let ink = NSColor(white: 0.12, alpha: 1)
let secondaryInk = NSColor(white: 0.35, alpha: 1)

func text(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = ink) -> NSAttributedString {
    NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
    ])
}

func drawCentered(_ string: NSAttributedString, x: CGFloat, y: CGFloat) {
    let size = string.size()
    string.draw(at: CGPoint(x: x - size.width / 2, y: y))
}

func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: .semibold).applying(.init(paletteColors: [color])))
}

/// One language block: a sentence and the settings path in a pill.
func drawInstruction(sentence: String, path: String, top: CGFloat, left: CGFloat, right: CGFloat) -> CGFloat {
    let line = text(sentence, size: 12.5, color: secondaryInk)
    line.draw(at: CGPoint(x: left, y: top))
    let pathText = text(path, size: 13, weight: .semibold)
    let pathSize = pathText.size()
    let pill = CGRect(x: left - 1, y: top + 20, width: min(pathSize.width + 20, right - left + 2), height: 24)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7).fill()
    warning.withAlphaComponent(0.35).setStroke()
    NSBezierPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7).stroke()
    pathText.draw(at: CGPoint(x: pill.minX + 10, y: pill.minY + (pill.height - pathSize.height) / 2))
    return pill.maxY
}

func render(scale: CGFloat) -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let cg = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
    // Top-left origin, like Finder icon positions.
    cg.translateBy(x: 0, y: height * scale)
    cg.scaleBy(x: scale, y: -scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    NSGradient(colors: [NSColor(white: 1, alpha: 1), NSColor(red: 0.93, green: 0.95, blue: 0.99, alpha: 1)])!
        .draw(in: bounds, angle: 90)

    drawCentered(text("Перетягніть MacUtil у Програми  ·  Drag MacUtil to Applications", size: 13, weight: .medium,
                      color: secondaryInk), x: width / 2, y: 26)

    // Arrow from the app to Applications.
    let arrowY = appCenter.y
    let start = appCenter.x + 78
    let end = applicationsCenter.x - 78
    let shaft = NSBezierPath()
    shaft.move(to: CGPoint(x: start, y: arrowY))
    shaft.line(to: CGPoint(x: end - 10, y: arrowY))
    shaft.lineWidth = 5
    shaft.lineCapStyle = .round
    shaft.setLineDash([2, 11], count: 2, phase: 0)
    accent.withAlphaComponent(0.8).setStroke()
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: CGPoint(x: end - 16, y: arrowY - 13))
    head.line(to: CGPoint(x: end, y: arrowY))
    head.line(to: CGPoint(x: end - 16, y: arrowY + 13))
    head.lineWidth = 5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    // First-launch card.
    let card = CGRect(x: 28, y: 268, width: width - 56, height: 160)
    NSColor(red: 1, green: 0.965, blue: 0.9, alpha: 1).setFill()
    NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14).fill()
    warning.withAlphaComponent(0.45).setStroke()
    let border = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
    border.lineWidth = 1
    border.stroke()

    let left = card.minX + 20
    let right = card.maxX - 20
    if let icon = symbol("exclamationmark.shield.fill", size: 17, color: warning) {
        icon.draw(in: CGRect(x: left, y: card.minY + 14, width: icon.size.width, height: icon.size.height),
                  from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    text("Перший запуск  ·  First launch", size: 15, weight: .bold, color: warning)
        .draw(at: CGPoint(x: left + 28, y: card.minY + 14))

    var y = card.minY + 46
    y = drawInstruction(
        sentence: "macOS блокує програми без нотаризації Apple. Відкрийте MacUtil один раз, потім:",
        path: "Системні параметри → Приватність і безпека → Все одно відкрити",
        top: y, left: left, right: right
    )
    _ = drawInstruction(
        sentence: "macOS blocks apps that Apple has not notarized. Open MacUtil once, then:",
        path: "System Settings → Privacy & Security → Open Anyway",
        top: y + 14, left: left, right: right
    )

    NSGraphicsContext.restoreGraphicsState()
    // Set after drawing: it only records the DPI, so Finder picks the 2x image on Retina.
    bitmap.size = NSSize(width: width, height: height)
    return bitmap.representation(using: .png, properties: [:])!
}

let temporary = FileManager.default.temporaryDirectory
let oneX = temporary.appending(path: "dmg-background.png")
let twoX = temporary.appending(path: "dmg-background@2x.png")
try render(scale: 1).write(to: oneX)
try render(scale: 2).write(to: twoX)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let tiffutil = Process()
tiffutil.executableURL = URL(filePath: "/usr/bin/tiffutil")
tiffutil.arguments = ["-cathidpicheck", oneX.path, twoX.path, "-out", output.appending(path: "background.tiff").path]
try tiffutil.run()
tiffutil.waitUntilExit()
print("Wrote \(output.path)/background.tiff (preview: \(twoX.path))")
