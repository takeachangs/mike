// Draws Resources/AppIcon.icns: the notch's indicator, a 3x3 lattice of white dots caught mid-ripple, on a dark
// macOS squircle. Run from app/: swift scripts/make-icon.swift
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
        // The ripple one beat out from the centre: centre bright, edges half, corners at rest; lit dots a little larger.
        let pitch = s * 0.21, d = s * 0.105
        for row in -1...1 {
            for col in -1...1 {
                let lit: CGFloat = row == 0 && col == 0 ? 1 : abs(row) + abs(col) == 1 ? 0.55 : 0.2
                let dd = d * (1 + 0.18 * lit), c = CGPoint(x: s / 2 + CGFloat(col) * pitch, y: s / 2 - CGFloat(row) * pitch)
                NSColor(white: 1, alpha: lit).setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - dd / 2, y: c.y - dd / 2, width: dd, height: dd)).fill()
            }
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
