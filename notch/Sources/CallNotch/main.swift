// CallNotch: a black tab that grows out of the left of the MacBook notch while a /call is live.
// Reads ~/.claude-call/state.json ({"state": off|listening|thinking|speaking, "level": 0...1, "muted": bool?}) written by bridge.py.
// Clicking the tab drops a call card from the notch (the `.wide` variant of notch/prototype-expansion.html):
// state, elapsed time, mute (SIGUSR1 to $CALL_BRIDGE_PID) and hang up (SIGINT).
import AppKit
import SwiftUI

let env = ProcessInfo.processInfo.environment
let stateURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude-call/state.json")
let amber = Color(red: 0xFB / 255, green: 0xBF / 255, blue: 0x24 / 255)
let tabWidth = 42.0, ear = 10.0, overlap = 12.0  // overlap: black drawn under the notch so its rounded corner fills in
let cardHeight = 116.0, launched = Date()
let bridgePID = env["CALL_BRIDGE_PID"].flatMap { pid_t($0) }

func signalBridge(_ sig: Int32, _ name: String) {
    if let pid = bridgePID { kill(pid, sig) } else { print("no CALL_BRIDGE_PID: would send \(name)") }
}

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

/// Concave ears of size e flaring into the menu bar outside l and r: the tab's curve. Same winding as `hang`.
func ears(_ l: Double, _ r: Double, _ e: Double) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: l - e, y: 0))
    p.addCurve(to: CGPoint(x: l, y: e), control1: CGPoint(x: l - e + 0.552 * e, y: 0), control2: CGPoint(x: l, y: e - 0.552 * e))
    p.addLine(to: CGPoint(x: l, y: 0))
    p.closeSubpath()
    p.move(to: CGPoint(x: r, y: 0))
    p.addLine(to: CGPoint(x: r, y: e))
    p.addCurve(to: CGPoint(x: r + e, y: 0), control1: CGPoint(x: r, y: e - 0.552 * e), control2: CGPoint(x: r + e - 0.552 * e, y: 0))
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

@MainActor final class Notch {
    var state = "off", target = 0.0, level = 0.0, hangUp = false, muted = false, mutedAt = Date.distantPast
    var t = 0.0, spin = 0.0, last: Date?, offSince: Date?
    var width = Spring(0, response: 0.3), radius = Spring(0, response: 0.45), breath = Spring(0, response: 0.5)
    var reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    var open = false, hovered = false, overTab = false, pressed = false, outSince: Date?, closedAt = Date.distantPast
    // Card height reveal (fluid-interface 0.35 s, no bounce), ears 80 ms, Reduce Motion cross-fade 200 ms, orb hover/press 100 ms.
    var card = Spring(0, response: 0.35), earFade = Spring(0, response: 0.08), fade = Spring(0, response: 0.2), orb = Spring(1, response: 0.1)

    struct Payload: Decodable { let state: String; let level: Double; let muted: Bool? }

    /// The panel grows to hold the card before it opens and shrinks back once it has closed, so a closed card
    /// leaves nothing on screen to swallow clicks.
    // ponytail: while open (and ~0.4 s into closing) the panel's transparent corners, e.g. right of the right ear, eat clicks.
    func setOpen(_ o: Bool) {
        open = o; hovered = false; outSince = nil
        if o { panel.setFrame(expanded, display: true) } else { closedAt = Date() }
    }

    /// Like boring.notch: once the pointer has been over the drawn shape or the card, leaving it for 100 ms closes the card.
    // ponytail: sampled at the 20 Hz poll, so the close lands 100-150 ms after leaving; a tracking area if that shows.
    func hover(_ now: Date) {
        let q = NSEvent.mouseLocation, f = panel.frame, pt = CGPoint(x: q.x - f.minX, y: f.maxY - q.y)
        overTab = tabRect.contains(pt)
        guard open else {
            if card.value < 0.01, panel.frame != collapsed { panel.setFrame(collapsed, display: true) }
            return
        }
        if CGRect(x: 0, y: 0, width: collapsed.width, height: notchHeight).contains(pt)
            || hang(ear, cardRight, notchHeight + cardHeight, 20).contains(pt) { hovered = true; outSince = nil; return }
        guard hovered else { return }
        outSince = outSince ?? now
        if now.timeIntervalSince(outSince!) >= 0.1 { setOpen(false) }
    }

    /// 20 Hz. A file not rewritten for 3 s counts as missing (bridge died); off or missing for 3 s more quits.
    func poll() {
        let now = Date()
        let mtime = (try? FileManager.default.attributesOfItem(atPath: stateURL.path))?[.modificationDate] as? Date
        let p = mtime.map { now.timeIntervalSince($0) < 3 } == true
            ? try? JSONDecoder().decode(Payload.self, from: Data(contentsOf: stateURL)) : nil
        state = hangUp ? "off" : p?.state ?? "off"
        target = min(max(p?.level ?? 0, 0), 1)
        if (p?.muted ?? false) != muted { muted.toggle(); mutedAt = now }
        if state == "off" && open { setOpen(false) }  // hang-up: the card folds first, the tab follows 60 ms later (step)
        hover(now)
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
        width.target = state == "off" && now.timeIntervalSince(closedAt) >= 0.06 ? 0 : tabWidth
        width.response = reduce ? 0.15 : state == "off" ? 0.24 : 0.3  // exits faster than it enters
        radius.response = reduce ? 0.25 : thinking ? 0.45 : 0.5
        radius.target = thinking ? 9 : 0
        breath.target = state == "listening" && !reduce ? 1 : 0
        card.target = open ? 1 : 0; earFade.target = card.target; fade.target = card.target
        orb.target = reduce ? 1 : pressed ? 0.9 : overTab ? 1.1 : 1
        width.step(dt); radius.step(dt); breath.step(dt); card.step(dt); earFade.step(dt); fade.step(dt); orb.step(dt)
        let goal = thinking || state == "off" ? 0 : target
        level += (goal - level) * (1 - pow(1 - (goal > level ? 0.55 : 0.18), dt * 60))  // fast attack, slow release
    }

    func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        // Card: revealed downward, never scaled, so its corners stay 20 pt. Reduce Motion: full height, cross-faded.
        let a = reduce ? fade.value : 1, g = reduce ? 1 : card.value
        if a > 0.005 && g > 0.005 {
            ctx.fill(hang(ear, cardRight, (notchHeight + cardHeight) * g, 20), with: .color(.black.opacity(a)))
            ctx.fill(ears(ear, cardRight, ear), with: .color(.black.opacity(a * earFade.value)))
        }
        let h = notchHeight, notchX = ear + tabWidth, w = max(width.value, 0)
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
        // The notch body and its ears grow from the top with the tab: under a hardware cutout nobody sees the body,
        // on a screen without one it is the notch.
        let n = min(w / tabWidth, 1)
        var shape = tab
        shape.addPath(hang(notchX, notchX + notchWidth, h * n, 12))
        shape.addPath(ears(notchX, notchX + notchWidth, ear * n))
        ctx.fill(shape, with: .color(.black))

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
            l.scaleBy(x: (0.9 + 0.1 * presence) * self.orb.value, y: (0.9 + 0.1 * presence) * self.orb.value)
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
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)  // the orb shrinks on pointer-down; release over the tab toggles the card
                .onChanged { g in m.pressed = m.state != "off" && tabRect.contains(g.startLocation) }
                .onEnded { g in if m.pressed && tabRect.contains(g.location) { m.setOpen(!m.open) }; m.pressed = false })
            .overlay(alignment: .topLeading) { card(tl.date) }  // overlay: never resizes the root
        }
    }

    func card(_ now: Date) -> some View {
        let s = Int(now.timeIntervalSince(launched))
        return VStack(spacing: 10) {
            reveal(Text(m.muted ? "Muted" : m.state.capitalized).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)), after: 0.11)
            reveal(Text(String(format: "%02d:%02d", s / 60, s % 60)).font(.system(size: 26, weight: .medium)).monospacedDigit()
                .tracking(-0.26).frame(height: 26), after: 0.11)
            reveal(HStack(spacing: 16) {
                mute(now)
                Button { signalBridge(SIGINT, "SIGINT (hang up)"); m.setOpen(false) } label: { Image(systemName: "phone.down.fill") }
                    .buttonStyle(Round(fill: Color(red: 1, green: 0x3B / 255, blue: 0x30 / 255), lit: Color(red: 1, green: 0x55 / 255, blue: 0x4A / 255)))
                    .accessibilityLabel("Hang up")
            }.padding(.top, 4), after: 0.15)
        }
        .foregroundStyle(.white)
        .frame(width: cardRight - ear, height: cardHeight)
        .allowsHitTesting(m.open)
        .offset(x: ear, y: notchHeight)
    }

    /// In: fade 160 ms and settle 6 pt down with a strong ease-out, after `delay`. Out: 120 ms at once. Reduce Motion: fade only.
    func reveal(_ v: some View, after delay: Double) -> some View {
        let o = m.open, r = m.reduce
        let fade: Animation = r ? .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.2) : o ? .easeOut(duration: 0.16).delay(delay) : .easeOut(duration: 0.12)
        let settle: Animation = o ? .timingCurve(0.23, 1, 0.32, 1, duration: 0.24).delay(delay) : .easeOut(duration: 0.12)
        return v.animation(fade) { $0.opacity(o ? 1 : 0) }.animation(settle) { $0.offset(y: o || r ? 0 : -6) }
    }

    /// The icon fades and shrinks out for 120 ms, swaps, and comes back in 120 ms; the circle recolours meanwhile.
    func mute(_ now: Date) -> some View {
        let k = now.timeIntervalSince(m.mutedAt) / 0.12, shown = k < 1 ? !m.muted : m.muted
        let v = k < 1 ? 1 - cssEase(k, 0, 0, 0.58, 1) : cssEase(min(k - 1, 1), 0, 0, 0.58, 1)
        return Button { signalBridge(SIGUSR1, "SIGUSR1 (mute)") } label: {
            Image(systemName: shown ? "mic.slash.fill" : "mic.fill").foregroundStyle(m.muted ? Color.black : .white)
                .opacity(v).scaleEffect(m.reduce ? 1 : 0.9 + 0.1 * v)
        }
        .buttonStyle(Round(fill: m.muted ? .white : .white.opacity(0.14), lit: m.muted ? .white : .white.opacity(0.22)))
        .accessibilityLabel(m.muted ? "Unmute" : "Mute")
    }
}

/// 36-pt circle, 18-pt symbol: lightens on hover, presses to 0.97.
struct Round: ButtonStyle {
    let fill: Color, lit: Color
    func makeBody(configuration: Configuration) -> some View { Face(c: configuration, fill: fill, lit: lit) }

    struct Face: View {
        let c: ButtonStyleConfiguration, fill: Color, lit: Color
        @State var over = false
        var body: some View {
            c.label.font(.system(size: 18)).frame(width: 36, height: 36)
                .background(Circle().fill(over ? lit : fill).animation(.easeOut(duration: 0.15), value: over ? lit : fill))
                .contentShape(Circle())
                .scaleEffect(c.isPressed ? 0.97 : 1).animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.12), value: c.isPressed)
                .onHover { over = $0 }
        }
    }
}

/// First click on a button acts even though the panel is never key and the app never activates.
final class Host: NSHostingView<NotchView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.main!
let notchLeft: Double, notchRight: Double, notchHeight: Double
if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
    (notchLeft, notchRight, notchHeight) = (l.maxX, r.minX, screen.safeAreaInsets.top)
} else {
    // No cutout: a centred 180-pt notch, as tall as the menu bar.
    // ponytail: 24 pt is the menu bar since Big Sur (NSStatusBar.system.thickness still says 22); measure it if that changes.
    (notchLeft, notchRight, notchHeight) = (screen.frame.midX - 90, screen.frame.midX + 90, 24)
}
let notchWidth = notchRight - notchLeft, cardRight = ear + 2 * tabWidth + notchWidth  // the card: tab's left edge to a tab past the notch
let tabRect = CGRect(x: 0, y: 0, width: ear + tabWidth, height: notchHeight)
print("notch x \(notchLeft)...\(notchRight), height \(notchHeight)")

let model = Notch()
let collapsed = NSRect(x: notchLeft - tabWidth - ear, y: screen.frame.maxY - notchHeight, width: 2 * ear + tabWidth + notchWidth, height: notchHeight)
let expanded = NSRect(x: collapsed.minX, y: collapsed.maxY - notchHeight - cardHeight, width: cardRight + ear, height: notchHeight + cardHeight)
let panel = NSPanel(contentRect: collapsed, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = false
panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
let host = Host(rootView: NotchView(m: model))
host.sizingOptions = []
panel.contentView = host
panel.setFrame(collapsed, display: true)
panel.orderFrontRegardless()
if env["CALL_NOTCH_OPEN"] != nil { model.setOpen(true) }  // ponytail: debug, starts with the card open

Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in MainActor.assumeIsolated { model.poll() } }

// bridge.py sends SIGTERM on hang-up: fold the card, then the tab, then exit.
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler {
    MainActor.assumeIsolated { model.hangUp = true; model.poll() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
}
term.resume()

app.run()
