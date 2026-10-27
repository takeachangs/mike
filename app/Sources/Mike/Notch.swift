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
    var width = Spring(0, response: 0.3), morph = Spring(0, response: 0.3)  // morph: the dots, 0 = at rest as the M, 1 = on their cycle
    var dock = Spring(1, response: 0.3)  // 0 = the tab alone, centred (no cutout, idle), 1 = the tab beside the notch
    var depth = Spring(cardHeight, response: 0.3)  // the card's height: short for the idle actions, full for a session or a notice
    var round = Spring(0, response: 0.3)  // the resting dots: 0 = the M, 1 = the circle, which they become while the card is open
    var reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    var open = false, hovered = false, overTab = false, pressed = false, quitting = false, outSince: Date?
    // The card morphs out of the notch on two springs, width (cx) and height (cy), 0 = the closed shape, 1 = the card:
    // opening leads with width (the notch widens, then drops), closing leads with height (it ends as a notch-tall pill
    // narrowing into the cutout). Responses are set per direction in step(). Reduce Motion cross-fades instead (fade).
    var cx = Spring(0, response: 0.26), cy = Spring(0, response: 0.30), fade = Spring(0, response: 0.2)
    var orb = Spring(1, response: 0.1)  // the dots' hover grow and press shrink
    // Dictation (Dictate.swift): the key tap and its rules, the capture, and the aura they light around the notch.
    var tap: CFMachPort?, keys = DictationKey(), dictation: Dictation?, transcribing = false, dictatedAt = Date.distantPast
    var dictationReady = false, tapNoted = false  // ready: mic live and model loaded, the circle and the start cue
    var aura = Spring(0, response: 0.4), spread = Spring(1, response: 0.4), sheen = Spring(0, response: 0.3), voice = 0.0
    var auraOut = 0.6  // how the aura leaves: slow and spreading after an insert, quick and drawn in after a cancel
    /// False when nothing is drawn or moving: the view's timeline pauses, so an idle app costs no frames.
    @Published var awake = true

    init(resident: Bool, envPID: pid_t?, recorderMode: Bool) {
        self.resident = resident; self.envPID = envPID; self.recorderMode = recorderMode
        dock = Spring(geo.hasCutout ? 1 : 0, response: 0.3)
    }

    /// What a click opens: the tab during a session; while resident and idle, the notch itself.
    /// What a click opens: the tab during a session; while resident and idle, the tab or the notch.
    func clickable(_ pt: CGPoint) -> Bool {
        if state == "off" && resident && dock.value < 0.5 { return geo.loneRect.contains(pt) }  // no cutout, idle: only the centred tab
        return state == "off" ? resident && geo.tabRect.union(geo.notchRect).contains(pt) : geo.tabRect.contains(pt)
    }

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

    /// The idle card is just the row of actions; a session, or a notice, needs the full height.
    var cardDepth: Double { state == "off" && resident && notice == nil ? idleCardHeight : cardHeight }

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
        let h = geo.height
        let x = reduce ? 1 : min(max(cx.value, 0), 1), y = reduce ? 1 : min(max(cy.value, 0), 1)
        let (l0, r0) = closedEdges(), b0 = h  // closed: the tab plus the notch
        let l = l0 + (margin - l0) * x, r = r0 + (geo.cardRight - r0) * x, b = b0 + (h + depth.value - b0) * y
        return hang(l, r, b, 12 + 8 * y)
    }

    /// The closed shape's left and right edges: the tab plus the notch, sliding (dock) to the tab alone centred on the notch.
    func closedEdges() -> (Double, Double) {
        let notchX = margin + tabWidth, w = max(width.value, 0), c = notchX + geo.notchWidth / 2, u = 1 - dock.value
        return (notchX - w + (c - w / 2 - notchX + w) * u, notchX + geo.notchWidth + (c + w / 2 - notchX - geo.notchWidth) * u)
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
            if shown < 0.02, aura.value < 0.002, dictation == nil, panel.frame != geo.collapsed { panel.setFrame(geo.collapsed, display: true) }
            return
        }
        if CGRect(x: 0, y: 0, width: geo.collapsed.width, height: geo.height).contains(pt)
            || hang(margin, geo.cardRight, geo.height + depth.value, 20).contains(pt) { hovered = true; outSince = nil; return }
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
        wake(state != "off" || open || pressed || overTab || starting != nil || dictation != nil || transcribing
             || ![cx, cy, fade, width, orb, morph, depth, round, dock, aura, spread, sheen].allSatisfy(still))
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
        // The resident app keeps the tab out (its dots are the M) until it quits; a session's notch shows it while the
        // session runs and, after a hang-up, until the card has landed on it.
        width.target = (resident && !quitting) || state != "off" || (width.value > 0.1 && cy.value >= 0.2) ? tabWidth : 0
        width.response = reduce ? 0.15 : state == "off" ? 0.24 : 0.3  // exits faster than it enters
        // No cutout: the tab sits alone, centred, until a session or the card needs the notch; docks again only once the card is gone.
        dock.target = geo.hasCutout || !resident || state != "off" || open || shown > 0.002 ? 1 : 0
        dock.response = reduce ? 0.15 : 0.3
        // Dictation: the dots cycle while it gets ready and while it transcribes, and open into the circle once you can speak.
        let heard = dictation != nil && Date().timeIntervalSince(dictatedAt) > 0.12, busy = heard || transcribing
        let dictWaiting = (heard && !dictationReady) || transcribing
        morph.target = (thinking || state == "speaking" || dictWaiting) && !muted && !reduce ? 1 : 0  // the dots cycle while waiting or speaking
        depth.target = cardDepth
        round.target = (open || (state == "listening" && !muted && !recorderMode) || dictationReady) && !reduce ? 1 : 0  // the circle: card open, a call listening, or dictation ready
        cx.target = open ? 1 : 0; cy.target = cx.target; fade.target = cx.target
        cx.response = open ? 0.26 : 0.34; cy.response = open ? 0.30 : 0.26  // see cx/cy; retargeting keeps velocity
        orb.target = reduce ? 1 : pressed ? 0.9 : overTab ? 1.1 : 1
        // The aura waits out the first 120 ms, so right ⌘ in a shortcut (⌘C) never lights it. Transcribing it settles
        // lower with a sheen; then it leaves the way auraOut says. Reduce Motion: it only fades.
        aura.target = heard ? 1 : transcribing ? 0.6 : 0
        aura.response = busy ? 0.4 : reduce ? 0.2 : auraOut
        spread.target = busy || reduce ? 1 : auraOut < 0.3 ? 0.6 : 1.6
        spread.response = aura.response
        sheen.target = transcribing && !reduce ? 1 : 0
    }

    func step(_ now: Date) {
        let dt = min(0.05, last.map { now.timeIntervalSince($0) } ?? 0)
        last = now; t += dt
        retarget()
        width.step(dt); morph.step(dt); depth.step(dt); round.step(dt); cx.step(dt); cy.step(dt); fade.step(dt); orb.step(dt); dock.step(dt)
        aura.step(dt); spread.step(dt); sheen.step(dt)
        let heard = reduce ? 0 : dictation?.level ?? 0
        voice += (heard - voice) * (1 - pow(1 - (heard > voice ? 0.3 : 0.08), dt * 60))  // softer than the dots: the aura breathes
        let goal = state == "thinking" || state == "off" ? 0 : target
        level += (goal - level) * (1 - pow(1 - (goal > level ? 0.55 : 0.18), dt * 60))  // fast attack, slow release
    }

    func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let h = geo.height, notchX = margin + tabWidth, w = max(width.value, 0)
        drawAura(&ctx)
        // Card: the notch itself growing into it (cardShape), never scaled, so its corners stay round. Reduce Motion:
        // the full card cross-fades. Closing, the tail of the springs settles inside the hardware cutout, out of sight.
        if shown > 0.002 { ctx.fill(cardShape(), with: .color(.black.opacity(reduce ? fade.value : 1))) }
        var tab = Path()
        if w > 0.1 && geo.hasCutout {
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
        } else if w > 0.1 {  // no cutout: one pill, the tab alone while idle, widening into the tab plus the notch
            let (l, r) = closedEdges()
            tab = hang(l, r, h, 12)
            ctx.fill(tab, with: .color(.black))
        }
        guard w > 0.1 else { return }

        // The indicator: seven white dots in a 24-pt box 8 pt before the notch (centred on the lone tab), vertically centred, fading in as the tab
        // uncovers it. At rest they are the m (two arches on flat feet), opening into the circle while the card is open
        // or a call is listening. Waiting, they run the morph cycle: the M
        // expands into a circle, which unfolds by quarter turns, then gathers back into the M (4.8 s, 5 % holds, 20 %
        // glides). Speaking, the circle keeps unfolding. Listening, the M brightens and swells with the level; paused
        // or muted, it dims with the centre lit. `morph` glides between the resting M and the cycle on state changes.
        let presence = min(max((w - 12) / 30, 0), 1)
        var dots = ctx
        dots.clip(to: tab)
        dots.opacity = presence
        dots.translateBy(x: notchX - 8 - 12 + (geo.notchWidth / 2 + 8 + 12) * (1 - dock.value), y: h / 2)  // alone, centred on the tab
        let k = (0.9 + 0.1 * presence) * orb.value
        dots.scaleBy(x: k, y: k)
        let speaking = state == "speaking", m = min(max(morph.value, 0), 1), o = min(max(round.value, 0), 1)
        let cycle = Notch.pose(speaking ? Notch.unfolding : Notch.morphing, at: (t / 4.8).truncatingRemainder(dividingBy: 1))
        let hearing = state == "listening" && !muted, call = hearing && !recorderMode, recording = hearing && recorderMode
        // On a call the circle breathes: a slow 3 s swell at rest, and it grows and brightens with your voice.
        // Dictating once ready, it breathes the same way with the dictation's mic.
        let breathe = (call || dictationReady) && !reduce ? 1 + 0.2 * (call ? level : voice) + 0.04 * (1 - cos(2 * .pi * t / 3)) / 2 : 1
        let dictWaiting = (dictation != nil && Date().timeIntervalSince(dictatedAt) > 0.12 && !dictationReady) || transcribing  // Reduce Motion: dim instead of the cycle
        for i in 0..<7 {
            let rm = Notch.mShape[i], rc = Notch.circle(0)[i], c = cycle[i]
            let r = (rm.0 + (rc.0 * breathe - rm.0) * o, rm.1 + (rc.1 * breathe - rm.1) * o)  // at rest: the m, or the circle
            let x = r.0 + (c.0 - r.0) * m, y = r.1 + (c.1 - r.1) * m
            // Recording: a soft glow walks the m from foot to foot every 2.8 s, and the dots swell with the level.
            let walk = recording && !reduce ? max(0, 1 - abs(((t / 2.8 * 7 - Double(i) + 3.5).truncatingRemainder(dividingBy: 7) + 7).truncatingRemainder(dividingBy: 7) - 3.5)) : 0
            let a = muted ? (i == 3 ? 1 : 0.35) : hearing ? max(0.55 + 0.45 * walk, 0.6 + 0.4 * level) : dictWaiting && reduce ? 0.45 : 1
            let d = 3 * (hearing && !reduce ? 1 + 0.15 * walk + 0.3 * level : 1)
            dots.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)), with: .color(.white.opacity(a)))
        }
    }

    /// While dictating: light around the closed notch's outline, under the black so only the outside shows. A soft
    /// blue-violet-pink-amber edge glow (Apple Intelligence's colours, quieter) that drifts slowly and swells and
    /// brightens with your voice; a bright line rides the edge. Transcribing, it dims and a sheen sweeps across.
    func drawAura(_ ctx: inout GraphicsContext) {
        let a = min(max(aura.value, 0), 1)
        guard a > 0.002 else { return }
        let (l, r) = closedEdges(), h = geo.height, shape = hang(l, r, h, 12), k = max(spread.value, 0)
        let drift = reduce ? 0 : (r - l) * 0.35 * sin(2 * .pi * t / 9)
        let light = GraphicsContext.Shading.linearGradient(Gradient(colors: Notch.auraColors), startPoint: CGPoint(x: l + drift, y: 0),
                                                           endPoint: CGPoint(x: r + drift, y: h))
        var glow = ctx
        glow.addFilter(.blur(radius: (10 + 6 * voice) * k))  // stays inside the 52 pt either side of the notch
        glow.opacity = a * (0.5 + 0.5 * voice)
        glow.stroke(shape, with: light, lineWidth: 6 * k)
        var rim = ctx
        rim.addFilter(.blur(radius: 1.5))
        rim.opacity = a * 0.9
        rim.stroke(shape, with: light, lineWidth: 2)
        let s = min(max(sheen.value, 0), 1)
        guard s > 0.002 else { return }
        let x = l - 40 + (r - l + 80) * (t / 1.6).truncatingRemainder(dividingBy: 1)  // left to right every 1.6 s
        var band = ctx
        band.addFilter(.blur(radius: 4))
        band.opacity = s * 0.8
        band.stroke(shape, with: .linearGradient(Gradient(colors: [.clear, .white, .clear]), startPoint: CGPoint(x: x - 30, y: 0),
                                                 endPoint: CGPoint(x: x + 30, y: 0)), lineWidth: 3)
    }
    static let auraColors = [Color(red: 0.55, green: 0.62, blue: 1), Color(red: 0.74, green: 0.51, blue: 0.95),
                             Color(red: 0.96, green: 0.73, blue: 0.92), Color(red: 1, green: 0.73, blue: 0.44)]

    /// The m: two arches on flat feet, in order left foot, left shoulder, left top, the valley, right top, right
    /// shoulder, right foot (y down). The feet sit a little closer to the shoulders than the tops do.
    // Sits 0.75 above the geometric centre: two feet make it look low when it is centred exactly.
    static let mShape: [(Double, Double)] = [(-7, 4), (-7, -1.5), (-3.5, -5.5), (0, -1), (3.5, -5.5), (7, -1.5), (7, 4)]
    /// The circle of 7, turned by `turn`: each dot takes the slot nearest its own angle (the valley takes the top), so
    /// the glide between them expands outward instead of crossing.
    static func circle(_ turn: Double) -> [(Double, Double)] {
        [4, 5, 6, 0, 1, 2, 3].map { let a = Double($0) / 7 * 2 * .pi - .pi / 2 + turn; return (cos(a) * 7, sin(a) * 7) }
    }
    static let morphing = [mShape, circle(0), circle(.pi / 2), circle(.pi)]
    static let unfolding = [circle(0), circle(.pi / 2), circle(.pi), circle(.pi * 1.5)]
    /// Where the dots are at phase `u` of a four-pose cycle: each quarter holds its pose for a fifth, then glides to
    /// the next on cubic-bezier(0.4, 0, 0.2, 1), the reference's morph timing.
    static func pose(_ poses: [[(Double, Double)]], at u: Double) -> [(Double, Double)] {
        let q = u * 4, slot = Int(q) % 4, f = q - floor(q), k = f < 0.2 ? 0 : cssEase((f - 0.2) / 0.8, 0.4, 0, 0.2, 1)
        let a = poses[slot], b = poses[(slot + 1) % 4]
        return (0..<7).map { (a[$0].0 + (b[$0].0 - a[$0].0) * k, a[$0].1 + (b[$0].1 - a[$0].1) * k) }
    }
}
