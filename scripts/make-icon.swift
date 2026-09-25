// Renders the pairprogram app icon: design/icon.svg on a macOS-style rounded square.
// Used by scripts/make-icon.sh.
import AppKit
// usage: makeicon <svg> <out.png> <size> <variant: rose|dark>
let a = CommandLine.arguments
let glyph = NSImage(contentsOf: URL(fileURLWithPath: a[1]))!
let px = CGFloat(Double(a[3])!)
let variant = a[4]
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
let s = px / 1024 // design at 1024
// macOS icon grid: 824×824 body centered, corner radius ~185, soft shadow below.
let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
let shape = NSBezierPath(roundedRect: body, xRadius: 185.4 * s, yRadius: 185.4 * s)
let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.28); shadow.shadowOffset = NSSize(width: 0, height: -10 * s); shadow.shadowBlurRadius = 24 * s
NSGraphicsContext.saveGraphicsState(); shadow.set(); NSColor.black.setFill(); shape.fill(); NSGraphicsContext.restoreGraphicsState()
let rose = NSColor(srgbRed: 244/255, green: 63/255, blue: 94/255, alpha: 1)
let (top, bottom, mark): (NSColor, NSColor, NSColor) = variant == "rose"
    ? (NSColor(srgbRed: 1, green: 0.42, blue: 0.51, alpha: 1), NSColor(srgbRed: 0.86, green: 0.15, blue: 0.33, alpha: 1), .white)
    : (NSColor(srgbRed: 0.20, green: 0.21, blue: 0.24, alpha: 1), NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1), rose)
NSGradient(starting: top, ending: bottom)!.draw(in: shape, angle: -90)
// A faint top highlight edge, like Apple's icons.
NSGraphicsContext.saveGraphicsState(); shape.addClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(variant == "rose" ? 0.18 : 0.08), .clear])!.draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
NSGraphicsContext.restoreGraphicsState()
// The mark: its drawn area spans ~355 of the SVG's 512 units; make it ~57% of the body.
let target = 470 * s, scale = target / 355
let side = 512 * scale
let glyphRect = NSRect(x: 512 * s - side / 2 + 2 * s, y: 512 * s - side / 2 + 4 * s, width: side, height: side)
let tinted = NSImage(size: glyph.size, flipped: false) { r in
    glyph.draw(in: r); mark.set(); r.fill(using: .sourceAtop); return true
}
let markShadow = NSShadow(); markShadow.shadowColor = NSColor.black.withAlphaComponent(variant == "rose" ? 0.18 : 0.35); markShadow.shadowOffset = NSSize(width: 0, height: -4 * s); markShadow.shadowBlurRadius = 10 * s
NSGraphicsContext.saveGraphicsState(); markShadow.set()
tinted.draw(in: glyphRect)
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
