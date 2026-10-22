// Draws Resources/AppIcon.icns: the notch's amber orb with its two satellites on a black macOS squircle.
// Run from app/: swift scripts/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        let inset = s * 0.1, r = (s - 2 * inset) * 0.225  // Apple's icon grid: 824/1024 body, ~22% corner
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset), xRadius: r, yRadius: r).fill()
        let amber = NSColor(red: 0xFB / 255, green: 0xBF / 255, blue: 0x24 / 255, alpha: 1)
        let c = CGPoint(x: s / 2, y: s / 2)
        func ball(_ x: CGFloat, _ y: CGFloat, _ d: CGFloat, _ a: CGFloat) {
            amber.withAlphaComponent(a).setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x + x - d / 2, y: c.y + y - d / 2, width: d, height: d)).fill()
        }
        ball(0, 0, s * 0.30, 1)
        ball(s * 0.27, s * 0.06, s * 0.11, 0.9)
        ball(-s * 0.22, -s * 0.17, s * 0.09, 0.7)
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
