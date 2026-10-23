// Draws Resources/AppIcon.icns: the notch's seven dots at rest, the m, on a dark macOS squircle.
// Run from app/: swift scripts/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        // Body: Apple's grid (824/1024) as a superellipse, with the soft top-to-bottom gradient of the system's dark icons.
        let w = s * 0.8, body = NSBezierPath()
        for i in 0...360 {
            let t = CGFloat(i) / 360 * 2 * .pi, c = cos(t), n = sin(t)
            let p = CGPoint(x: s / 2 + w / 2 * copysign(pow(abs(c), 0.4), c), y: s / 2 + w / 2 * copysign(pow(abs(n), 0.4), n))
            i == 0 ? body.move(to: p) : body.line(to: p)
        }
        body.close()
        NSGradient(starting: NSColor(white: 0.16, alpha: 1), ending: NSColor(white: 0.04, alpha: 1))!.draw(in: body, angle: -90)
        // The m: the notch's seven dots (Notch.mShape, y down there) centred exactly, 7 units = 21 % of the icon.
        let unit = s * 0.03, d = s * 0.095
        for (x, y) in [(-7.0, 4.75), (-7.0, -0.75), (-3.5, -4.75), (0.0, -0.25), (3.5, -4.75), (7.0, -0.75), (7.0, 4.75)] {
            let c = CGPoint(x: s / 2 + CGFloat(x) * unit, y: s / 2 - CGFloat(y) * unit)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)).fill()
        }
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
