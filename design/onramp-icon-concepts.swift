import AppKit
let a = CommandLine.arguments
let variant = a[2], px: CGFloat = 512
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
let s = px / 1024
let body = NSRect(x: 100*s, y: 100*s, width: 824*s, height: 824*s)
let shape = NSBezierPath(roundedRect: body, xRadius: 185.4*s, yRadius: 185.4*s)
let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.3); sh.shadowOffset = NSSize(width: 0, height: -10*s); sh.shadowBlurRadius = 24*s
NSGraphicsContext.saveGraphicsState(); sh.set(); NSColor.black.setFill(); shape.fill(); NSGraphicsContext.restoreGraphicsState()
NSGradient(colors: [NSColor(srgbRed: 0.24, green: 0.245, blue: 0.26, alpha: 1), NSColor(srgbRed: 0.105, green: 0.108, blue: 0.118, alpha: 1), NSColor(srgbRed: 0.065, green: 0.066, blue: 0.072, alpha: 1)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: shape, angle: -90)
NSGraphicsContext.saveGraphicsState(); shape.addClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.13), .clear])!.draw(in: body, angle: -55)
NSGraphicsContext.restoreGraphicsState()
// silver paint for strokes: draw path into a mask image, then fill with a metal gradient
func silver(_ build: @escaping (NSBezierPath) -> Void, width: CGFloat) {
    let img = NSImage(size: NSSize(width: px, height: px), flipped: false) { r in
        let p = NSBezierPath(); build(p)
        p.lineWidth = width; p.lineCapStyle = .round; p.lineJoinStyle = .round
        NSColor.black.setStroke(); p.stroke()
        NSGraphicsContext.current?.compositingOperation = .sourceAtop
        NSGradient(colors: [NSColor(white: 1, alpha: 1), NSColor(white: 0.88, alpha: 1), NSColor(white: 0.66, alpha: 1)], atLocations: [0, 0.5, 1], colorSpace: .sRGB)!.draw(in: r, angle: -90)
        return true
    }
    let m = NSShadow(); m.shadowColor = NSColor.black.withAlphaComponent(0.5); m.shadowOffset = NSSize(width: 0, height: -5*s); m.shadowBlurRadius = 12*s
    NSGraphicsContext.saveGraphicsState(); m.set(); img.draw(in: NSRect(x: 0, y: 0, width: px, height: px)); NSGraphicsContext.restoreGraphicsState()
}
// rounded inverted triangle (yield), centered, points: top-left, top-right, bottom
func triangle(_ p: NSBezierPath, inset: CGFloat) {
    let i = inset * s
    let cx = 512*s, top = (512 + 205)*s - i*0.6, bottom = (512 - 250)*s + i*1.25, half = 250*s - i*1.1
    let pts = [NSPoint(x: cx - half, y: top), NSPoint(x: cx + half, y: top), NSPoint(x: cx, y: bottom)]
    let r = 34*s
    p.move(to: NSPoint(x: (pts[0].x + pts[1].x)/2, y: top))
    for i in [1, 2, 0] { p.appendArc(from: pts[i], to: pts[(i+1)%3 == 0 ? 0 : (i+1)%3], radius: r) }
    p.close()
}
switch variant {
case "yield":
    silver({ triangle($0, inset: 0) }, width: 42*s)
    silver({ triangle($0, inset: 58) }, width: 12*s)
case "yieldramp":
    silver({ triangle($0, inset: 0) }, width: 38*s)
    // Inside the sign: the main lane going up, and the onramp joining it from lower left.
    silver({ p in
        p.move(to: NSPoint(x: 548*s, y: 380*s)); p.line(to: NSPoint(x: 548*s, y: 640*s))
        p.move(to: NSPoint(x: 452*s, y: 470*s)); p.curve(to: NSPoint(x: 540*s, y: 610*s), controlPoint1: NSPoint(x: 452*s, y: 545*s), controlPoint2: NSPoint(x: 540*s, y: 560*s))
    }, width: 26*s)
default: // merge: the ramp joins the lane from below-left; the lane carries on up
    silver({ p in
        p.move(to: NSPoint(x: 580*s, y: 250*s)); p.line(to: NSPoint(x: 580*s, y: 700*s))
        p.move(to: NSPoint(x: 490*s, y: 690*s)); p.line(to: NSPoint(x: 580*s, y: 780*s)); p.line(to: NSPoint(x: 670*s, y: 690*s))
        p.move(to: NSPoint(x: 390*s, y: 250*s)); p.curve(to: NSPoint(x: 566*s, y: 560*s), controlPoint1: NSPoint(x: 390*s, y: 420*s), controlPoint2: NSPoint(x: 560*s, y: 440*s))
    }, width: 46*s)
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[1]))
