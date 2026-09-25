// Draws the DMG window background: graphite (matching the app icon), an arrow
// from the app to Applications, and a one-line hint. Used by scripts/package.sh.
import AppKit

let out = CommandLine.arguments[1]
let size = NSSize(width: 660, height: 400) // the DMG window's content size (package.sh sets the bounds)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let bounds = NSRect(origin: .zero, size: size)
NSGradient(colors: [NSColor(srgbRed: 0.17, green: 0.175, blue: 0.19, alpha: 1), NSColor(srgbRed: 0.085, green: 0.087, blue: 0.095, alpha: 1)])!
    .draw(in: bounds, angle: -90)
NSGradient(colors: [NSColor.white.withAlphaComponent(0.05), .clear])!.draw(in: bounds, angle: -60) // faint sheen

// Arrow between the two icons (Finder puts them at x 180 and 480, y 190 from the top).
let y = size.height - 190
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 268, y: y)); arrow.line(to: NSPoint(x: 392, y: y))
arrow.move(to: NSPoint(x: 380, y: y + 10)); arrow.line(to: NSPoint(x: 394, y: y)); arrow.line(to: NSPoint(x: 380, y: y - 10))
arrow.lineWidth = 3
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor.white.withAlphaComponent(0.28).setStroke()
arrow.stroke()

let hint = NSAttributedString(string: "Drag PairProgram to Applications", attributes: [
    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
    .foregroundColor: NSColor.white.withAlphaComponent(0.55),
])
let hs = hint.size()
hint.draw(at: NSPoint(x: (size.width - hs.width) / 2, y: 62))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
