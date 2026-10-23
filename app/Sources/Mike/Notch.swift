import AppKit
import MikeKit
import SwiftUI

/// The notch's state and drawing. Reads ~/.mike/state.json at 20 Hz, whoever wrote it: this app's own call or
/// recorder, the Listen CLI, or bridge.py.
@MainActor final class Notch: ObservableObject {
    let resident: Bool, envPID: pid_t?
    weak var panel: NSPanel?
    var state = "off", target = 0.0, level = 0.0, hangUp = false, muted = false, mutedAt = Date.distantPast
    var t = 0.0, last: Date?, offSince: Date?
    var pid: pid_t?, recorderMode: Bool, since = Date(), live = false  // the session's, from the state file
    var starting: Date?, progress: Double?  // a session this app is starting: model download / load, or connecting
    var notice: String?, noticeUntil = Date.distantPast
    var recorder: Recorder?, call: LiveCall?  // sessions running inside this app
    var launching = false, cancelled = false, stopping = false  // their lifecycle, see Launch.swift
    var peek = Spring(0, response: 0.2)  // resident and idle: the notch swells a little under the pointer
    var width = Spring(0, response: 0.3), grid = Spring(0, response: 0.3)  // grid: the indicator, 1 = lattice, 0 = ring
    var reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    var open = false, hovered = false, overTab = false, pressed = false, outSince: Date?
    // The card morphs out of the notch on two springs, width (cx) and height (cy), 0 = the closed shape, 1 = the card:
    // opening leads with width (the notch widens, then drops), closing leads with height (it ends as a notch-tall pill
    // narrowing into the cutout). Responses are set per direction in step(). Reduce Motion cross-fades instead (fade).
    var cx = Spring(0, response: 0.26), cy = Spring(0, response: 0.30), fade = Spring(0, response: 0.2)
    var orb = Spring(1, response: 0.1), press = Spring(1, response: 0.1)  // indicator hover/press; the notch's press dip
    /// False when nothing is drawn or moving: the view's timeline pauses, so an idle app costs no frames.
    @Published var awake = true

    init(resident: Bool, envPID: pid_t?, recorderMode: Bool) {
        self.resident = resident; self.envPID = envPID; self.recorderMode = recorderMode
    }

    /// What a click opens: the tab during a session; while resident and idle, the notch itself.
    // Idle: the swollen outline too (2 pt a side, 4 pt down), so the pointer on the swell does not flicker it off.
    func clickable(_ pt: CGPoint) -> Bool { state == "off" ? resident && geo.notchRect.insetBy(dx: -2, dy: -4).contains(pt) : geo.tabRect.contains(pt) }

    /// A short message in the card (an error, "Saved"), opening the card when idle so it is seen.
    func say(_ text: String, for seconds: TimeInterval = 6) {
        notice = text
        noticeUntil = Date().addingTimeInterval(seconds)
        if resident && state == "off" && !open { setOpen(true) }
    }

    /// The panel grows to hold the card before it opens and shrinks back once it has closed, so a closed card
    /// leaves nothing on screen to swallow clicks.
    // ponytail: while open (and ~0.4 s into closing) the panel's transparent corners, e.g. right of the card, eat clicks.
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
    /// closed shape to the card. Top corners stay square, meeting the bezel as the notch does. Also the content's clip.
    func cardShape() -> Path {
        let h = geo.height, notchX = margin + tabWidth, pk = peek.value * press.value
        let x = reduce ? 1 : min(max(cx.value, 0), 1), y = reduce ? 1 : min(max(cy.value, 0), 1)
        // Closed: the hover swell over the notch when idle, the tab plus the notch during a session.
        let l0 = notchX - max(max(width.value, 0), 2 * pk), r0 = notchX + geo.notchWidth + 2 * pk, b0 = h + 4 * pk
        let l = l0 + (margin - l0) * x, r = r0 + (geo.cardRight - r0) * x, b = b0 + (h + cardHeight - b0) * y
        return hang(l, r, b, 12 + 8 * y)
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
            || hang(margin, geo.cardRight, geo.height + cardHeight, 20).contains(pt) { hovered = true; outSince = nil; return }
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
        retarget()  // before the stillness check, or a spring whose target just moved (pointer left) pauses the timeline a poll
        wake(state != "off" || open || pressed || overTab || starting != nil
             || ![cx, cy, fade, peek, width, press, orb, grid].allSatisfy(still))
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

    /// Where every spring is heading, from the current state. Called per frame and at each poll.
    func retarget() {
        let thinking = state == "thinking"
        // The tab belongs to a session; after a hang-up it stays until the card has landed on it. It never grows for the idle menu.
        width.target = state != "off" || (width.value > 0.1 && cy.value >= 0.2) ? tabWidth : 0
        width.response = reduce ? 0.15 : state == "off" ? 0.24 : 0.3  // exits faster than it enters
        grid.target = thinking || (muted && state != "speaking") ? 1 : 0  // lattice while waiting or paused, else the ring
        cx.target = open ? 1 : 0; cy.target = cx.target; fade.target = cx.target
        cx.response = open ? 0.26 : 0.34; cy.response = open ? 0.30 : 0.26  // see cx/cy; retargeting keeps velocity
        orb.target = reduce ? 1 : pressed ? 0.9 : overTab ? 1.1 : 1
        press.target = pressed ? 0.6 : 1
        peek.target = state == "off" && overTab && !open && !reduce ? 1 : 0
    }

    func step(_ now: Date) {
        let dt = min(0.05, last.map { now.timeIntervalSince($0) } ?? 0)
        last = now; t += dt
        retarget()
        width.step(dt); grid.step(dt); cx.step(dt); cy.step(dt); fade.step(dt); orb.step(dt); peek.step(dt); press.step(dt)
        let goal = state == "thinking" || state == "off" ? 0 : target
        level += (goal - level) * (1 - pow(1 - (goal > level ? 0.55 : 0.18), dt * 60))  // fast attack, slow release
    }

    func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let h = geo.height, notchX = margin + tabWidth, w = max(width.value, 0), pk = peek.value * press.value
        // Card: the notch itself growing into it (cardShape), never scaled, so its corners stay round. Reduce Motion:
        // the full card cross-fades. Closing, the tail of the springs settles inside the hardware cutout, out of sight.
        if shown > 0.002 { ctx.fill(cardShape(), with: .color(.black.opacity(reduce ? fade.value : 1))) }
        if w <= 0.1 && peek.value > 0.01 {  // idle hover: 2 pt wider each side and 4 pt deeper than the cutout
            ctx.fill(hang(notchX - 2 * pk, notchX + geo.notchWidth + 2 * pk, h + 4 * pk, 12), with: .color(.black))
        }
        var tab = Path()
        if w > 0.1 {
            let left = notchX - w, r = min(12, w, h / 2)
            tab.move(to: CGPoint(x: left, y: 0))
            tab.addLine(to: CGPoint(x: left, y: h - r))
            tab.addArc(tangent1End: CGPoint(x: left, y: h), tangent2End: CGPoint(x: left + r, y: h), radius: r)
            tab.addLine(to: CGPoint(x: notchX + min(overlap, w), y: h))
            tab.addLine(to: CGPoint(x: notchX + min(overlap, w), y: 0))
            tab.closeSubpath()
            // The notch body grows from the top with the tab: under a hardware cutout nobody sees it, on a screen
            // without one it is the notch.
            var shape = tab
            shape.addPath(hang(notchX, notchX + geo.notchWidth, h * min(w / tabWidth, 1), 12))
            ctx.fill(shape, with: .color(.black))
        }
        guard w > 0.1 else { return }

        // The indicator: white dots in a 24-pt box 8 pt before the notch, vertically centred, fading in as the tab
        // uncovers it. A 3x3 lattice while waiting (a ripple from the centre, 1.7 s) or paused (the centre dot steady);
        // a ring of 8 while the mic is open (the dots brighten and swell with the level over a slow pulse) or the
        // voice speaks (a comet runs round, 1.8 s). The two cross-fade on `grid`. Reduce Motion: nothing moves.
        let presence = min(max((w - 12) / 30, 0), 1), rest = 0.2
        var dots = ctx
        dots.clip(to: tab)
        dots.opacity = presence
        dots.translateBy(x: notchX - 8 - 12, y: h / 2)
        let k = (0.9 + 0.1 * presence) * orb.value
        dots.scaleBy(x: k, y: k)
        func dot(_ x: Double, _ y: Double, _ d: Double, _ a: Double) {
            guard a > 0.001 else { return }
            dots.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)), with: .color(.white.opacity(a)))
        }
        func wrap(_ u: Double) -> Double { u - floor(u) }
        let g = min(max(grid.value, 0), 1)
        if g > 0.001 {  // lattice: pitch 7, dots 3.5
            for row in -1...1 {
                for col in -1...1 {
                    var lit = row == 0 && col == 0 ? 1.0 : 0.0  // at rest, and under Reduce Motion: the centre
                    if state == "thinking" && !reduce {
                        let delay = hypot(Double(col), Double(row)) * 0.7 - (row == 0 && col == 0 ? 0.18 : 0)
                        let u = wrap((t - delay) / 1.7)
                        lit = u < 0.28 ? cssEase(u / 0.28, 0.66, 0, 0.34, 1) : u < 0.56 ? 1 - cssEase((u - 0.28) / 0.28, 0.66, 0, 0.34, 1) : 0
                    }
                    dot(Double(col) * 7, Double(row) * 7, 3.5 * (1 + 0.18 * lit), g * (rest + (1 - rest) * lit))
                }
            }
        }
        if g < 0.999 {  // ring: 8 dots on radius 8, dots 3
            let speaking = state == "speaking"
            for i in 0..<8 {
                let a = Double(i) / 8 * 2 * .pi, lit: Double
                if reduce {
                    lit = 0.7
                } else if speaking {
                    let u = wrap(t / 1.8 - Double(i) / 8)
                    lit = u < 0.12 ? 0.08 + 0.92 * u / 0.12 : u < 0.35 ? 1 - 0.5 * (u - 0.12) / 0.23 : u < 0.6 ? 0.5 - 0.38 * (u - 0.35) / 0.25 : 0.12 - 0.04 * (u - 0.6) / 0.4
                } else {
                    lit = max(0.35 * (1 - cos(2 * .pi * (t / 2 - Double(i) / 8))) / 2, level)
                }
                dot(8 * cos(a), 8 * sin(a), 3 * (speaking || reduce ? 1 : 0.9 + 0.25 * level), (1 - g) * (rest + (1 - rest) * lit))
            }
        }
    }
}
