// Renders Resources/AppIcon.icns: a gradient squircle with stacked documents flowing into a queue.
import AppKit

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // Squircle body (Apple grid: 824pt body, centered, with drop shadow).
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let path = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.33, blue: 0.95, alpha: 1),
                        NSColor(srgbRed: 0.05, green: 0.72, blue: 0.86, alpha: 1)])!
        .draw(in: body, angle: -60)
    // Soft highlight.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: 100, y: 520, width: 824, height: 404), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Queue of three documents, fading back, plus a progress ring around the front one.
    func doc(_ rect: NSRect, alpha: CGFloat) {
        let fold: CGFloat = rect.width * 0.28
        let p = NSBezierPath()
        p.move(to: NSPoint(x: rect.minX, y: rect.minY + 24))
        p.appendArc(from: NSPoint(x: rect.minX, y: rect.minY), to: NSPoint(x: rect.minX + 24, y: rect.minY), radius: 24)
        p.line(to: NSPoint(x: rect.maxX - 24, y: rect.minY))
        p.appendArc(from: NSPoint(x: rect.maxX, y: rect.minY), to: NSPoint(x: rect.maxX, y: rect.minY + 24), radius: 24)
        p.line(to: NSPoint(x: rect.maxX, y: rect.maxY - fold))
        p.line(to: NSPoint(x: rect.maxX - fold, y: rect.maxY))
        p.line(to: NSPoint(x: rect.minX + 24, y: rect.maxY))
        p.appendArc(from: NSPoint(x: rect.minX, y: rect.maxY), to: NSPoint(x: rect.minX, y: rect.maxY - 24), radius: 24)
        p.close()
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.18 * alpha)
        sh.shadowBlurRadius = 18
        sh.shadowOffset = NSSize(width: 0, height: -6)
        sh.set()
        NSColor.white.withAlphaComponent(alpha).setFill()
        p.fill()
        NSGraphicsContext.restoreGraphicsState()
        let f = NSBezierPath()
        f.move(to: NSPoint(x: rect.maxX - fold, y: rect.maxY))
        f.line(to: NSPoint(x: rect.maxX - fold, y: rect.maxY - fold + 18))
        f.appendArc(from: NSPoint(x: rect.maxX - fold, y: rect.maxY - fold), to: NSPoint(x: rect.maxX - fold + 18, y: rect.maxY - fold), radius: 18)
        f.line(to: NSPoint(x: rect.maxX, y: rect.maxY - fold))
        f.close()
        NSColor(srgbRed: 0.75, green: 0.85, blue: 1, alpha: alpha).setFill()
        f.fill()
    }
    doc(NSRect(x: 560, y: 470, width: 210, height: 270), alpha: 0.45)
    doc(NSRect(x: 445, y: 410, width: 230, height: 295), alpha: 0.7)
    let front = NSRect(x: 300, y: 330, width: 260, height: 330)
    doc(front, alpha: 1)

    // Lines of text on the front doc.
    NSColor(srgbRed: 0.16, green: 0.4, blue: 0.95, alpha: 0.35).setFill()
    for (i, w) in [150.0, 180, 120].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: front.minX + 40, y: front.minY + 190 - CGFloat(i) * 42, width: w, height: 18),
                     xRadius: 9, yRadius: 9).fill()
    }

    // Progress badge.
    let c = NSPoint(x: 590, y: 330)
    let badge = NSBezierPath(ovalIn: NSRect(x: c.x - 120, y: c.y - 120, width: 240, height: 240))
    NSGraphicsContext.saveGraphicsState()
    let bs = NSShadow()
    bs.shadowColor = NSColor.black.withAlphaComponent(0.25)
    bs.shadowBlurRadius = 20
    bs.shadowOffset = NSSize(width: 0, height: -6)
    bs.set()
    NSColor(srgbRed: 0.07, green: 0.16, blue: 0.45, alpha: 1).setFill()
    badge.fill()
    NSGraphicsContext.restoreGraphicsState()
    let track = NSBezierPath()
    track.appendArc(withCenter: c, radius: 82, startAngle: 0, endAngle: 360)
    track.lineWidth = 30
    NSColor.white.withAlphaComponent(0.2).setStroke()
    track.stroke()
    let arc = NSBezierPath()
    arc.appendArc(withCenter: c, radius: 82, startAngle: 90, endAngle: 90 - 250, clockwise: true)
    arc.lineWidth = 30
    arc.lineCapStyle = .round
    NSColor(srgbRed: 0.35, green: 0.95, blue: 0.85, alpha: 1).setStroke()
    arc.stroke()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: c.x, y: c.y + 38))
    arrow.line(to: NSPoint(x: c.x, y: c.y - 34))
    arrow.move(to: NSPoint(x: c.x - 30, y: c.y - 4))
    arrow.line(to: NSPoint(x: c.x, y: c.y - 34))
    arrow.line(to: NSPoint(x: c.x + 30, y: c.y - 4))
    arrow.lineWidth = 20
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor.white.setStroke()
    arrow.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments[1]
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = render(base * scale).representation(using: .png, properties: [:])!
        try! data.write(to: iconset.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try! p.run()
p.waitUntilExit()
try? render(1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out).deletingPathExtension().appendingPathExtension("png"))
