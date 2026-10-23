import AppKit
import SwiftUI

let amber = Color(red: 0xFB / 255, green: 0xBF / 255, blue: 0x24 / 255)
let tabWidth = 42.0, margin = 10.0, overlap = 12.0  // margin: panel room left of the tab; overlap: black under the notch so its corner fills in
let cardHeight = 116.0, idleCardHeight = 80.0  // the session card; the idle one, just the row of actions

/// Where the notch is on the main screen, and the panel frames built around it. Panel coordinates have y down.
struct NotchGeometry {
    let notchLeft: Double, notchRight: Double, height: Double, screenTop: Double, hasCutout: Bool

    init(screen: NSScreen) {
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            (notchLeft, notchRight, height) = (l.maxX, r.minX, screen.safeAreaInsets.top)
            hasCutout = true
        } else {
            // No cutout: a centred 180-pt notch, as tall as the menu bar. Idle, only the tab shows, centred on it (Notch.dock).
            hasCutout = false
            // ponytail: 24 pt is the menu bar since Big Sur (NSStatusBar.system.thickness still says 22); measure it if that changes.
            (notchLeft, notchRight, height) = (screen.frame.midX - 90, screen.frame.midX + 90, 24)
        }
        screenTop = screen.frame.maxY
    }

    var notchWidth: Double { notchRight - notchLeft }
    var cardRight: Double { margin + 2 * tabWidth + notchWidth }  // the card: tab's left edge to a tab past the notch
    var tabRect: CGRect { CGRect(x: 0, y: 0, width: margin + tabWidth, height: height) }
    var loneRect: CGRect { CGRect(x: margin + tabWidth + notchWidth / 2 - tabWidth / 2, y: 0, width: tabWidth, height: height) }  // the tab alone, centred on the notch
    var notchRect: CGRect { CGRect(x: margin + tabWidth, y: 0, width: notchWidth, height: height) }
    var collapsed: NSRect { NSRect(x: notchLeft - tabWidth - margin, y: screenTop - height, width: 2 * margin + tabWidth + notchWidth, height: height) }
    var expanded: NSRect { NSRect(x: collapsed.minX, y: collapsed.maxY - height - cardHeight, width: cardRight + margin, height: height + cardHeight) }
}

/// Recomputed when displays change (main.swift); read on the main thread only.
nonisolated(unsafe) var geo = NotchGeometry(screen: NSScreen.main ?? NSScreen.screens[0])

/// Black hanging from the screen top down to b between panel x l and r, bottom corners k (shrunk when short, as CSS does).
func hang(_ l: Double, _ r: Double, _ b: Double, _ k: Double) -> Path {
    let k = min(k, b / 2, (r - l) / 2)
    var p = Path()
    p.move(to: CGPoint(x: l, y: 0))
    p.addLine(to: CGPoint(x: l, y: b - k))
    p.addArc(tangent1End: CGPoint(x: l, y: b), tangent2End: CGPoint(x: l + k, y: b), radius: k)
    p.addArc(tangent1End: CGPoint(x: r, y: b), tangent2End: CGPoint(x: r, y: b - k), radius: k)
    p.addLine(to: CGPoint(x: r, y: 0))
    p.closeSubpath()
    return p
}

/// Critically damped spring, solved in closed form so any frame time is stable. Retargeting keeps value and velocity.
/// Settles (99 %) in about its response, so a 0.08 response stands in for an 80 ms ease-out.
struct Spring {
    var value: Double, velocity = 0.0, target: Double, response: Double
    init(_ v: Double, response: Double) { value = v; target = v; self.response = response }
    mutating func step(_ dt: Double) {
        let w = 2 * .pi / response, c1 = value - target, c2 = velocity + w * c1, e = exp(-w * dt)
        value = target + (c1 + c2 * dt) * e
        velocity = (c2 - w * (c1 + c2 * dt)) * e
    }
}

/// CSS cubic-bezier(x1, y1, x2, y2), default `ease`, solved by bisection.
func cssEase(_ x: Double, _ x1: Double = 0.25, _ y1: Double = 0.1, _ x2: Double = 0.25, _ y2: Double = 1) -> Double {
    func bez(_ s: Double, _ p1: Double, _ p2: Double) -> Double { 3 * (1 - s) * (1 - s) * s * p1 + 3 * (1 - s) * s * s * p2 + s * s * s }
    var lo = 0.0, hi = 1.0
    for _ in 0..<16 { let m = (lo + hi) / 2; if bez(m, x1, x2) < x { lo = m } else { hi = m } }
    return bez((lo + hi) / 2, y1, y2)
}
