// Renders the Onramp app icon: a red yield triangle on a black-steel rounded square.
// Used by scripts/make-icon.sh.
import AppKit
// usage: make-icon <out.png> <size>
let a = CommandLine.arguments
let px = CGFloat(Double(a[2])!)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
let s = px / 1024 // design at 1024

// macOS icon grid: 824×824 body centered, corner radius ~185, soft shadow below.
let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
let shape = NSBezierPath(roundedRect: body, xRadius: 185.4 * s, yRadius: 185.4 * s)
let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.28); shadow.shadowOffset = NSSize(width: 0, height: -10 * s); shadow.shadowBlurRadius = 24 * s
NSGraphicsContext.saveGraphicsState(); shadow.set(); NSColor.black.setFill(); shape.fill(); NSGraphicsContext.restoreGraphicsState()

// Black steel: graphite body, faint diagonal sheen, a machined rim bright along the top.
NSGradient(colors: [NSColor(srgbRed: 0.24, green: 0.245, blue: 0.26, alpha: 1), NSColor(srgbRed: 0.105, green: 0.108, blue: 0.118, alpha: 1),
                    NSColor(srgbRed: 0.065, green: 0.066, blue: 0.072, alpha: 1)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: shape, angle: -90)
NSGraphicsContext.saveGraphicsState(); shape.addClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.13), .clear])!.draw(in: body, angle: -55)
NSGraphicsContext.restoreGraphicsState()
let rim = NSBezierPath(roundedRect: body.insetBy(dx: 1.5 * s, dy: 1.5 * s), xRadius: 184 * s, yRadius: 184 * s)
ctx.cgContext.saveGState()
ctx.cgContext.addPath(rim.cgPath); ctx.cgContext.setLineWidth(3 * s); ctx.cgContext.replacePathWithStrokedPath(); ctx.cgContext.clip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.8), NSColor.white.withAlphaComponent(0.12), NSColor.white.withAlphaComponent(0.04)],
           atLocations: [0, 0.3, 1], colorSpace: .sRGB)!.draw(in: body, angle: -90)
ctx.cgContext.restoreGState()

// The yield triangle: point down, rounded corners, optically centred (a touch high).
let cx = 512 * s, top = 728 * s, bottom = 240 * s, half = 270 * s
let pts = [NSPoint(x: cx - half, y: top), NSPoint(x: cx + half, y: top), NSPoint(x: cx, y: bottom)]
let tri = NSBezierPath()
tri.move(to: NSPoint(x: cx, y: top))
for i in [1, 2, 0] { tri.appendArc(from: pts[i], to: pts[(i + 1) % 3], radius: 38 * s) }
tri.close()
let red = (top: NSColor(srgbRed: 1.0, green: 0.36, blue: 0.33, alpha: 1), bottom: NSColor(srgbRed: 0.80, green: 0.10, blue: 0.14, alpha: 1))
let lift = NSShadow(); lift.shadowColor = NSColor.black.withAlphaComponent(0.55); lift.shadowOffset = NSSize(width: 0, height: -6 * s); lift.shadowBlurRadius = 14 * s
NSGraphicsContext.saveGraphicsState(); lift.set(); red.bottom.setFill(); tri.fill(); NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: red.top, ending: red.bottom)!.draw(in: tri, angle: -90)
NSGraphicsContext.saveGraphicsState(); tri.addClip() // gloss on the top edge
NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!.draw(in: NSRect(x: 0, y: top - 240 * s, width: px, height: 240 * s), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// Like a real yield sign: a thin white rim, and a white triangle about half the size, sitting a little high.
let env = ProcessInfo.processInfo.environment
func scaled(_ k: CGFloat, about c: NSPoint, radius: CGFloat) -> NSBezierPath {
    let q = pts.map { NSPoint(x: c.x + ($0.x - c.x) * k, y: c.y + ($0.y - c.y) * k) }
    let p = NSBezierPath()
    p.move(to: NSPoint(x: (q[0].x + q[1].x) / 2, y: q[0].y))
    for i in [1, 2, 0] { p.appendArc(from: q[i], to: q[(i + 1) % 3], radius: radius * s) }
    p.close()
    return p
}
if env["ICON_RIM"] != "0" { // the white border is the sign's own edge, as on the real thing
    NSGraphicsContext.saveGraphicsState()
    tri.addClip()
    tri.lineWidth = 2 * CGFloat(Double(env["ICON_RIM_W"] ?? "12") ?? 12) * s // half of it falls outside the clip
    NSColor(white: 0.97, alpha: 1).setStroke()
    tri.stroke()
    NSGraphicsContext.restoreGraphicsState()
}
let innerScale = CGFloat(Double(env["ICON_INNER"] ?? "0.5") ?? 0.5)
if innerScale > 0 {
    let inner = scaled(innerScale, about: NSPoint(x: cx, y: CGFloat(Double(env["ICON_INNER_Y"] ?? "588") ?? 588) * s), radius: 22)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.25); sh.shadowOffset = NSSize(width: 0, height: -2 * s); sh.shadowBlurRadius = 4 * s
    sh.set()
    NSGradient(starting: NSColor(white: 1, alpha: 1), ending: NSColor(white: 0.9, alpha: 1))!.draw(in: inner, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[1]))
