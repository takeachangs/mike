// CallNotch: a black tab that grows out of the left of the MacBook notch while a /call is live.
// Reads ~/.claude-call/state.json ({"state": off|listening|thinking|speaking, "level": 0...1}) written by bridge.py.
import AppKit
import SwiftUI

let stateURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude-call/state.json")
let amber = Color(red: 0xFB / 255, green: 0xBF / 255, blue: 0x24 / 255)
let tabWidth = 42.0, ear = 10.0, overlap = 12.0  // overlap: black drawn under the notch so its rounded corner fills in

/// Critically damped spring, solved in closed form so any frame time is stable. Retargeting keeps value and velocity.
struct Spring {
    var value: Double, velocity = 0.0, target: Double, response: Double
    init(_ v: Double, response: Double) { value = v; target = v; self.response = response }
    mutating func step(_ dt: Double) {
        let w = 2 * .pi / response, c1 = value - target, c2 = velocity + w * c1, e = exp(-w * dt)
        value = target + (c1 + c2 * dt) * e
        velocity = (c2 - w * (c1 + c2 * dt)) * e
    }
}

/// CSS `ease` = cubic-bezier(0.25, 0.1, 0.25, 1), solved by bisection.
func cssEase(_ x: Double) -> Double {
    func bez(_ s: Double, _ p1: Double, _ p2: Double) -> Double { 3 * (1 - s) * (1 - s) * s * p1 + 3 * (1 - s) * s * s * p2 + s * s * s }
    var lo = 0.0, hi = 1.0
    for _ in 0..<16 { let m = (lo + hi) / 2; if bez(m, 0.25, 0.25) < x { lo = m } else { hi = m } }
    return bez((lo + hi) / 2, 0.1, 1)
}

@MainActor final class Notch {
    var state = "off", target = 0.0, level = 0.0, hangUp = false
    var t = 0.0, spin = 0.0, last: Date?, offSince: Date?
    var width = Spring(0, response: 0.3), radius = Spring(0, response: 0.45), breath = Spring(0, response: 0.5)
    var reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    struct Payload: Decodable { let state: String; let level: Double }

    /// 20 Hz. A file not rewritten for 3 s counts as missing (bridge died); off or missing for 3 s more quits.
    func poll() {
        let now = Date()
        let mtime = (try? FileManager.default.attributesOfItem(atPath: stateURL.path))?[.modificationDate] as? Date
        let p = mtime.map { now.timeIntervalSince($0) < 3 } == true
            ? try? JSONDecoder().decode(Payload.self, from: Data(contentsOf: stateURL)) : nil
        state = hangUp ? "off" : p?.state ?? "off"
        target = min(max(p?.level ?? 0, 0), 1)
        reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if state != "off" { offSince = nil; return }
        offSince = offSince ?? now
        if now.timeIntervalSince(offSince!) > 3 { NSApp.terminate(nil) }
    }

    func step(_ now: Date) {
        let dt = min(0.05, last.map { now.timeIntervalSince($0) } ?? 0)
        last = now; t += dt
        spin += dt / (reduce ? 4 : 1.4)
        let thinking = state == "thinking"
        width.target = state == "off" ? 0 : tabWidth
        width.response = reduce ? 0.15 : state == "off" ? 0.24 : 0.3  // exits faster than it enters
        radius.response = reduce ? 0.25 : thinking ? 0.45 : 0.5
        radius.target = thinking ? 9 : 0
        breath.target = state == "listening" && !reduce ? 1 : 0
        width.step(dt); radius.step(dt); breath.step(dt)
        let goal = thinking || state == "off" ? 0 : target
        level += (goal - level) * (1 - pow(1 - (goal > level ? 0.55 : 0.18), dt * 60))  // fast attack, slow release
    }

    func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let h = size.height, notchX = ear + tabWidth, w = max(width.value, 0)
        guard w > 0.1 else { return }
        let e = min(ear, w), left = notchX - w, r = min(12, w, h / 2)
        var tab = Path()
        tab.move(to: CGPoint(x: left - e, y: 0))
        tab.addCurve(to: CGPoint(x: left, y: e), control1: CGPoint(x: left - e + 0.552 * e, y: 0), control2: CGPoint(x: left, y: e - 0.552 * e))
        tab.addLine(to: CGPoint(x: left, y: h - r))
        tab.addArc(tangent1End: CGPoint(x: left, y: h), tangent2End: CGPoint(x: left + r, y: h), radius: r)
        tab.addLine(to: CGPoint(x: notchX + min(overlap, w), y: h))
        tab.addLine(to: CGPoint(x: notchX + min(overlap, w), y: 0))
        tab.closeSubpath()
        ctx.fill(tab, with: .color(.black))

        // Orb: 24-pt box, 8 pt before the notch, vertically centred. Fades in as the tab uncovers it.
        let presence = min(max((w - 12) / 30, 0), 1)
        let core = 1 + 0.75 * level + 0.08 * breath.value * (1 - cos(2 * .pi * t / 2.8)) / 2
        let rad = radius.value, sat = 0.85 + 0.15 * min(max(rad / 9, 0), 1)
        var orb = ctx
        orb.clip(to: tab)
        orb.opacity = presence
        orb.addFilter(.alphaThreshold(min: 0.5, color: amber))  // metaball: blur, then cut at half alpha
        orb.addFilter(.blur(radius: 1.5))
        orb.drawLayer { l in
            l.translateBy(x: notchX - 8 - 12, y: h / 2)
            l.scaleBy(x: 0.9 + 0.1 * presence, y: 0.9 + 0.1 * presence)
            func ball(_ x: Double, _ y: Double, _ d: Double) {
                l.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)), with: .color(.white))
            }
            ball(0, 0, 6 * core)
            for lag in [0.0, 0.5] {  // second satellite half a revolution (0.7 s) behind
                let u = spin - lag, a = 2 * .pi * (floor(u) + cssEase(u - floor(u)))
                ball(rad * cos(a), rad * sin(a), 6 * sat)
            }
        }
    }
}

struct NotchView: View {
    let m: Notch
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { tl in
            Canvas { ctx, size in
                m.step(tl.date)
                m.draw(&ctx, size)
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.main!
let notchLeft: Double, notchHeight: Double
if let area = screen.auxiliaryTopLeftArea, screen.safeAreaInsets.top > 0 {
    (notchLeft, notchHeight) = (area.maxX, screen.safeAreaInsets.top)
} else {
    (notchLeft, notchHeight) = (screen.frame.midX - 90, 32)  // no notch: pretend a centred 180-pt one
}
print("notch left x \(notchLeft), height \(notchHeight)")

let model = Notch()
let frame = NSRect(x: notchLeft - tabWidth - ear, y: screen.frame.maxY - notchHeight, width: ear + tabWidth + overlap, height: notchHeight)
let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = false
panel.ignoresMouseEvents = true
panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
let host = NSHostingView(rootView: NotchView(m: model))
host.sizingOptions = []
panel.contentView = host
panel.setFrame(frame, display: true)
panel.orderFrontRegardless()

Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in MainActor.assumeIsolated { model.poll() } }

// bridge.py sends SIGTERM on hang-up: collapse the tab, then exit.
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler {
    MainActor.assumeIsolated { model.hangUp = true; model.poll() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
}
term.resume()

app.run()
