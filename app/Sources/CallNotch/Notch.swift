import AppKit
import CallNotchKit
import SwiftUI

/// The notch's state and drawing. Reads ~/.claude-call/state.json at 20 Hz, whoever wrote it: this app's own call or
/// recorder, the Listen CLI, or bridge.py.
@MainActor final class Notch: ObservableObject {
    let resident: Bool, envPID: pid_t?
    weak var panel: NSPanel?
    var state = "off", target = 0.0, level = 0.0, hangUp = false, muted = false, mutedAt = Date.distantPast
    var t = 0.0, spin = 0.0, last: Date?, offSince: Date?
    var pid: pid_t?, recorderMode: Bool, since = Date(), live = false  // the session's, from the state file
    var starting: Date?, progress: Double?  // a session this app is starting: model download / load, or connecting
    var notice: String?, noticeUntil = Date.distantPast
    var recorder: Recorder?, call: LiveCall?  // sessions running inside this app
    var launching = false, cancelled = false, stopping = false  // their lifecycle, see Launch.swift
    var peek = Spring(0, response: 0.2)  // resident and idle: the notch swells a little under the pointer
    var width = Spring(0, response: 0.3), radius = Spring(0, response: 0.45), breath = Spring(0, response: 0.5)
    var reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    var open = false, hovered = false, overTab = false, pressed = false, outSince: Date?
    // The card morphs out of the notch on two springs, width (cx) and height (cy), 0 = the closed shape, 1 = the card:
    // opening leads with width (the notch widens, then drops), closing leads with height (it ends as a notch-tall pill
    // narrowing into the cutout). Responses are set per direction in step(). Reduce Motion cross-fades instead (fade).
    var cx = Spring(0, response: 0.26), cy = Spring(0, response: 0.30), fade = Spring(0, response: 0.2)
    var orb = Spring(1, response: 0.1), press = Spring(1, response: 0.1)  // orb hover/press; the notch's press dip
    /// False when nothing is drawn or moving: the view's timeline pauses, so an idle app costs no frames.
    @Published var awake = true

    init(resident: Bool, envPID: pid_t?, recorderMode: Bool) {
        self.resident = resident; self.envPID = envPID; self.recorderMode = recorderMode
    }

    /// What a click opens: the tab during a session; while resident and idle, the notch itself.
    func clickable(_ pt: CGPoint) -> Bool { state == "off" ? resident && geo.notchRect.contains(pt) : geo.tabRect.contains(pt) }

    /// A short message in the card (an error, "Saved"), opening the card when idle so it is seen.
    func say(_ text: String, for seconds: TimeInterval = 6) {
        notice = text
        noticeUntil = Date().addingTimeInterval(seconds)
        if resident && state == "off" && !open { setOpen(true) }
    }

    /// The panel grows to hold the card before it opens and shrinks back once it has closed, so a closed card
    /// leaves nothing on screen to swallow clicks.
    // ponytail: while open (and ~0.4 s into closing) the panel's transparent corners, e.g. right of the right ear, eat clicks.
    func setOpen(_ o: Bool) {
        open = o; hovered = false; outSince = nil
        if o { panel?.setFrame(geo.expanded, display: true); wake(true) }
    }

    /// How much of the card is showing: the morph, or the Reduce Motion fade.
    var shown: Double { reduce ? fade.value : max(cx.value, cy.value) }

    func wake(_ on: Bool) {
        guard on != awake else { return }
        awake = on
        last = nil  // the first frame after waking steps from zero instead of jumping across the pause
    }

    /// The card at this frame, in panel coordinates: a `hang` whose edges, depth and corners interpolate from the
    /// closed shape to the card, with the menu-bar ears riding its top corners. Also the clip for the card's content.
    func cardShape() -> Path {
        let h = geo.height, notchX = ear + tabWidth, pk = peek.value * press.value
        let x = reduce ? 1 : min(max(cx.value, 0), 1), y = reduce ? 1 : min(max(cy.value, 0), 1)
        // Closed: the hover swell over the notch when idle, the tab plus the notch during a session.
        let l0 = notchX - max(max(width.value, 0), 2 * pk), r0 = notchX + geo.notchWidth + 2 * pk, b0 = h + 4 * pk
        let l = l0 + (ear - l0) * x, r = r0 + (geo.cardRight - r0) * x, b = b0 + (h + cardHeight - b0) * y
        var path = hang(l, r, b, 12 + 8 * y)
        path.addPath(ears(l, r, min(ear, max(ear * pk, r - r0))))  // ears grow as the edges leave the notch
        return path
    }

    /// Like boring.notch: once the pointer has been over the drawn shape or the card, leaving it for 100 ms closes the card.
    // ponytail: sampled at the 20 Hz poll, so the close lands 100-150 ms after leaving; a tracking area if that shows.
    func hover(_ now: Date) {
        guard let panel else { return }
        let q = NSEvent.mouseLocation, f = panel.frame, pt = CGPoint(x: q.x - f.minX, y: f.maxY - q.y)
        overTab = clickable(pt)
        if resident { panel.ignoresMouseEvents = !(open || overTab) }  // beside the notch, clicks reach the menu bar
        // ponytail: the 20 Hz sample above can lag a very fast move-and-click onto the notch by up to 50 ms
        guard open else {
            if shown < 0.02, panel.frame != geo.collapsed { panel.setFrame(geo.collapsed, display: true) }
            return
        }
        if CGRect(x: 0, y: 0, width: geo.collapsed.width, height: geo.height).contains(pt)
            || hang(ear, geo.cardRight, geo.height + cardHeight, 20).contains(pt) { hovered = true; outSince = nil; return }
        guard hovered else { return }
        outSince = outSince ?? now
        if now.timeIntervalSince(outSince!) >= 0.1 { setOpen(false) }
    }

    /// 20 Hz. A file not rewritten for 3 s counts as missing (session died); off or missing for 3 s more quits,
    /// unless resident, which folds back to idle instead.
    func poll() {
        let now = Date()
        let p = StateFile.read(now: now)
        if p?.isLive == true { starting = nil; progress = nil }
        let waiting = starting.map { now.timeIntervalSince($0) < 600 } == true  // first run downloads ~600 MB
        let was = state
        state = hangUp ? "off" : p?.isLive == true ? p!.state : waiting ? "thinking" : "off"
        // The timer starts when the session itself does (recorder running, call connected), not while it loads.
        if p?.isLive == true && !live { since = now }
        live = p?.isLive == true
        pid = p?.isLive == true ? p?.pid : nil  // never keep a finished session's pid: it may be reused by then
        if let p, p.isLive { recorderMode = p.mode == .listen || ProcessInfo.processInfo.environment["CALL_NOTCH_MODE"] == "listen" }
        target = min(max(p?.level ?? 0, 0), 1)
        if (p?.muted ?? false) != muted { muted.toggle(); mutedAt = now }
        if notice != nil && now > noticeUntil { notice = nil }
        if state == "off" && was != "off" && open { setOpen(false) }  // hang-up: the card folds onto the tab, then the tab goes (step)
        hover(now)
        reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        func still(_ s: Spring) -> Bool { abs(s.value - s.target) < 0.001 && abs(s.velocity) < 0.01 }
        wake(state != "off" || open || pressed || overTab || starting != nil
             || ![cx, cy, fade, peek, width, press, orb].allSatisfy(still))
        if state != "off" || resident { offSince = nil; return }
        offSince = offSince ?? now
        if now.timeIntervalSince(offSince!) > 3 { NSApp.terminate(nil) }
    }

    /// The card's pause and stop buttons: sessions inside this app directly, others by signal (SIGUSR1 pause or mute,
    /// SIGINT stop or hang up), the same signals Ctrl-C and bridge.py use.
    func signalSession(_ sig: Int32) {
        if resident && launching {  // still starting: Stop cancels it, there is nothing to pause yet
            if sig == SIGINT { stopLocal() }
            return
        }
        guard let target = envPID ?? pid, target > 0 else { Log.app.error("no session pid to signal"); return }
        if target == getpid() {
            if sig == SIGUSR1 { recorder?.togglePause(); call?.toggleMute() } else { stopLocal() }
        } else {
            kill(target, sig)
        }
    }

    func step(_ now: Date) {
        let dt = min(0.05, last.map { now.timeIntervalSince($0) } ?? 0)
        last = now; t += dt
        spin += dt / (reduce ? 4 : 1.4)
        let thinking = state == "thinking"
        // The tab belongs to a session; after a hang-up it stays until the card has landed on it. It never grows for the idle menu.
        width.target = state != "off" || (width.value > 0.1 && cy.value >= 0.2) ? tabWidth : 0
        width.response = reduce ? 0.15 : state == "off" ? 0.24 : 0.3  // exits faster than it enters
        radius.response = reduce ? 0.25 : thinking ? 0.45 : 0.5
        radius.target = thinking ? 9 : 0
        breath.target = state == "listening" && !reduce ? 1 : 0
        cx.target = open ? 1 : 0; cy.target = cx.target; fade.target = cx.target
        cx.response = open ? 0.26 : 0.34; cy.response = open ? 0.30 : 0.26  // see cx/cy; retargeting keeps velocity
        orb.target = reduce ? 1 : pressed ? 0.9 : overTab ? 1.1 : 1
        press.target = pressed ? 0.6 : 1
        peek.target = state == "off" && overTab && !open && !reduce ? 1 : 0
        width.step(dt); radius.step(dt); breath.step(dt); cx.step(dt); cy.step(dt); fade.step(dt); orb.step(dt); peek.step(dt); press.step(dt)
        let goal = thinking || state == "off" ? 0 : target
        level += (goal - level) * (1 - pow(1 - (goal > level ? 0.55 : 0.18), dt * 60))  // fast attack, slow release
    }

    /// The rim: a thin light line along the edge of whatever is drawn, so you can see the app is at the notch. It
    /// fades to nothing toward the top of the screen, thinning out along the ears where the shape meets the bezel.
    static let rimOpacity = 0.35, rimWidth = 1.0, ring = 1.5  // ring: black just outside the idle cutout, to carry the rim

    func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let h = geo.height, notchX = ear + tabWidth, w = max(width.value, 0), pk = peek.value * press.value
        var outline = Path()
        // Card: the notch itself growing into it (cardShape), never scaled, so its corners stay round. Reduce Motion:
        // the full card cross-fades. Closing, the tail of the springs settles inside the hardware cutout, out of sight.
        if shown > 0.002 {
            let card = cardShape()
            ctx.fill(card, with: .color(.black.opacity(reduce ? fade.value : 1)))
            outline = card
        }
        // Idle (resident, on a real notch): the cutout plus a thin black ring, swelling 2 pt a side and 4 pt down under
        // the pointer. On a screen without a cutout nothing is drawn at idle, so no fake notch covers the menu bar.
        if w <= 0.1 && (geo.hasCutout && resident || peek.value > 0.01) {
            let g = geo.hasCutout ? Notch.ring : 0, l = notchX - 2 * pk - g, r = notchX + geo.notchWidth + 2 * pk + g
            var idle = hang(l, r, h + 4 * pk + g, 12 + g)
            idle.addPath(ears(l, r, ear))
            ctx.fill(idle, with: .color(.black))
            outline.addPath(idle)
        }
        var tab = Path()
        if w > 0.1 {
            let e = min(ear, w), left = notchX - w, r = min(12, w, h / 2)
            tab.move(to: CGPoint(x: left - e, y: 0))
            tab.addCurve(to: CGPoint(x: left, y: e), control1: CGPoint(x: left - e + 0.552 * e, y: 0), control2: CGPoint(x: left, y: e - 0.552 * e))
            tab.addLine(to: CGPoint(x: left, y: h - r))
            tab.addArc(tangent1End: CGPoint(x: left, y: h), tangent2End: CGPoint(x: left + r, y: h), radius: r)
            tab.addLine(to: CGPoint(x: notchX + min(overlap, w), y: h))
            tab.addLine(to: CGPoint(x: notchX + min(overlap, w), y: 0))
            tab.closeSubpath()
            // The notch body and its ears grow from the top with the tab: under a hardware cutout nobody sees the
            // body, on a screen without one it is the notch.
            let n = min(w / tabWidth, 1)
            var shape = tab
            shape.addPath(hang(notchX, notchX + geo.notchWidth, h * n, 12))
            shape.addPath(ears(notchX, notchX + geo.notchWidth, ear * n))
            ctx.fill(shape, with: .color(.black))
            outline.addPath(shape)
        }
        if !outline.isEmpty {  // normalized: one outline of everything drawn, so no seams show inside the black
            let rim = Gradient(stops: [.init(color: .white.opacity(0), location: 0), .init(color: .white.opacity(Notch.rimOpacity * (reduce ? fade.value : 1)), location: 1)])
            ctx.stroke(outline.normalized(eoFill: false), with: .linearGradient(rim, startPoint: .zero, endPoint: CGPoint(x: 0, y: h)), lineWidth: Notch.rimWidth)
        }
        guard w > 0.1 else { return }

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
