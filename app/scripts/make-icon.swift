// Draws Resources/AppIcon.icns: the notch's amber orb at the foot of a lowercase m, its orbit trail arching through
// two satellites, on a dark macOS squircle. Run from app/: swift scripts/make-icon.swift
import AppKit

let amber = NSColor(red: 0xFB / 255, green: 0xBF / 255, blue: 0x24 / 255, alpha: 1)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: s / 2 + x * s, y: s / 2 + y * s) }  // unit coords, centre 0
        // Body: Apple's grid (824/1024) as a superellipse, with the soft top-to-bottom gradient of the system's dark icons.
        let w = s * 0.8, body = NSBezierPath()
        for i in 0...360 {
            let t = CGFloat(i) / 360 * 2 * .pi, c = cos(t), n = sin(t)
            let p = CGPoint(x: s / 2 + w / 2 * copysign(pow(abs(c), 0.4), c), y: s / 2 + w / 2 * copysign(pow(abs(n), 0.4), n))
            i == 0 ? body.move(to: p) : body.line(to: p)
        }
        body.close()
        NSGradient(starting: NSColor(white: 0.16, alpha: 1), ending: NSColor(white: 0.04, alpha: 1))!.draw(in: body, angle: -90)
        NSGraphicsContext.saveGraphicsState(); body.addClip()

        // The orbit: a trail from the core over two arches to the feet, fading as it goes (Catmull-Rom through the knots).
        let knots = [(-0.26, -0.16), (-0.26, 0.10), (-0.13, 0.20), (0.0, 0.10), (0.0, -0.14), (0.0, 0.10), (0.13, 0.20), (0.26, 0.10), (0.26, -0.16)].map { at($0.0, $0.1) }
        var pts: [CGPoint] = []
        for i in 0..<(knots.count - 1) {
            let p0 = knots[max(i - 1, 0)], p1 = knots[i], p2 = knots[i + 1], p3 = knots[min(i + 2, knots.count - 1)]
            for k in 0..<24 {
                let t = CGFloat(k) / 24, t2 = t * t, t3 = t2 * t
                pts.append(CGPoint(x: 0.5 * (2 * p1.x + (p2.x - p0.x) * t + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 + (3 * p1.x - p0.x - 3 * p2.x + p3.x) * t3),
                                   y: 0.5 * (2 * p1.y + (p2.y - p0.y) * t + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 + (3 * p1.y - p0.y - 3 * p2.y + p3.y) * t3)))
            }
        }
        pts.append(knots.last!)
        // One stroke, filled with a left-to-right gradient (the trail runs left to right), so no segment seams show.
        let line = CGMutablePath(); line.addLines(between: pts)
        let trail = line.copy(strokingWithWidth: max(s * 0.028, 1.5), lineCap: .round, lineJoin: .round, miterLimit: 10)  // never thinner than 1.5 px
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current!.cgContext.addPath(trail); NSGraphicsContext.current!.cgContext.clip()
        NSGradient(starting: amber.withAlphaComponent(0.95), ending: amber.withAlphaComponent(0.35))!
            .draw(in: NSRect(x: knots[0].x, y: 0, width: knots.last!.x - knots[0].x, height: s), angle: 0)
        NSGraphicsContext.restoreGraphicsState()

        func ball(_ x: CGFloat, _ y: CGFloat, _ d: CGFloat, _ a: CGFloat) {
            let c = at(x, y), d = d * s
            amber.withAlphaComponent(a).setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)).fill()
        }
        let c = at(-0.26, -0.16), g = s * 0.24  // the core's halo
        NSGradient(starting: amber.withAlphaComponent(0.35), ending: amber.withAlphaComponent(0))!
            .draw(in: NSBezierPath(ovalIn: NSRect(x: c.x - g, y: c.y - g, width: 2 * g, height: 2 * g)), relativeCenterPosition: .zero)
        ball(-0.26, -0.16, 0.24, 1); ball(0, -0.16, 0.10, 0.9); ball(0.26, -0.16, 0.08, 0.7)
        NSGraphicsContext.restoreGraphicsState()
        return true
    }
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: set.appending(path: "icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: set.appending(path: "icon_\(size)x\(size)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
