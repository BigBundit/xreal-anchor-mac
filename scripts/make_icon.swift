import AppKit

// Draws the app icon: a pair of black sunglasses on a soft sky gradient.
let out = CommandLine.arguments[1]
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError() }

// Background squircle
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(red: 0.62, green: 0.86, blue: 1.00, alpha: 1),
                    NSColor(red: 0.98, green: 0.80, blue: 0.62, alpha: 1)])!
    .draw(in: bg, angle: -90)

/// One lens: flat top, wide rounded bottom, slightly narrower towards the nose.
func lens(centerX: CGFloat, mirrored: Bool) -> NSBezierPath {
    let w: CGFloat = 268, h: CGFloat = 200
    let top: CGFloat = 610, bottom = top - h
    let s: CGFloat = mirrored ? -1 : 1           // +1: outer edge is on the left
    let outer = centerX - s * w / 2, inner = centerX + s * w / 2
    let p = NSBezierPath()
    p.move(to: NSPoint(x: outer, y: top))
    p.line(to: NSPoint(x: inner, y: top))
    // Nose side: tucks in a little as it goes down.
    p.curve(to: NSPoint(x: inner - s * 40, y: bottom + 30),
            controlPoint1: NSPoint(x: inner + s * 4, y: top - 90),
            controlPoint2: NSPoint(x: inner - s * 6, y: bottom + 60))
    // Rounded bottom.
    p.curve(to: NSPoint(x: outer + s * 30, y: bottom + 40),
            controlPoint1: NSPoint(x: inner - s * 90, y: bottom - 22),
            controlPoint2: NSPoint(x: outer + s * 40, y: bottom - 22))
    // Outer side back up to the top bar.
    p.curve(to: NSPoint(x: outer, y: top),
            controlPoint1: NSPoint(x: outer + s * 18, y: bottom + 80),
            controlPoint2: NSPoint(x: outer - s * 4, y: top - 70))
    p.close()
    return p
}

// Centre the glasses vertically in the squircle.
ctx.translateBy(x: 0, y: -90)

let left = lens(centerX: 337, mirrored: false)
let right = lens(centerX: 687, mirrored: true)

// Soft shadow under the glasses
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: NSColor(white: 0, alpha: 0.35).cgColor)
NSColor.black.setFill()
left.fill(); right.fill()
ctx.restoreGState()

// Frame: thick top bar and bridge
NSColor(white: 0.06, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 188, y: 588, width: 648, height: 58), xRadius: 28, yRadius: 28).fill()
let bridge = NSBezierPath()
bridge.move(to: NSPoint(x: 466, y: 600))
bridge.curve(to: NSPoint(x: 558, y: 600), controlPoint1: NSPoint(x: 486, y: 556), controlPoint2: NSPoint(x: 538, y: 556))
bridge.line(to: NSPoint(x: 558, y: 625))
bridge.line(to: NSPoint(x: 466, y: 625))
bridge.close()
bridge.fill()
// Temples peeking out at the sides
NSBezierPath(roundedRect: NSRect(x: 160, y: 604, width: 60, height: 34), xRadius: 14, yRadius: 14).fill()
NSBezierPath(roundedRect: NSRect(x: 804, y: 604, width: 60, height: 34), xRadius: 14, yRadius: 14).fill()

// Lens tint and glossy reflections
for l in [left, right] {
    ctx.saveGState()
    l.addClip()
    NSGradient(colors: [NSColor(white: 0.22, alpha: 1), NSColor(white: 0.02, alpha: 1)])!.draw(in: l, angle: -70)
    let shine = NSBezierPath()
    let b = l.bounds
    shine.move(to: NSPoint(x: b.minX + 40, y: b.maxY))
    shine.line(to: NSPoint(x: b.minX + 120, y: b.maxY))
    shine.line(to: NSPoint(x: b.minX - 10, y: b.minY))
    shine.line(to: NSPoint(x: b.minX - 90, y: b.minY))
    shine.close()
    NSColor(white: 1, alpha: 0.22).setFill()
    shine.fill()
    let thin = NSBezierPath()
    thin.move(to: NSPoint(x: b.minX + 150, y: b.maxY))
    thin.line(to: NSPoint(x: b.minX + 180, y: b.maxY))
    thin.line(to: NSPoint(x: b.minX + 50, y: b.minY))
    thin.line(to: NSPoint(x: b.minX + 20, y: b.minY))
    thin.close()
    NSColor(white: 1, alpha: 0.12).setFill()
    thin.fill()
    ctx.restoreGState()
}

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
