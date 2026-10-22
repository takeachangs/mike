import AppKit
import SwiftUI

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
                .onChanged { g in m.pressed = m.clickable(g.startLocation) }
                .onEnded { g in if m.pressed && m.clickable(g.location) { m.setOpen(!m.open) }; m.pressed = false })
            .overlay(alignment: .topLeading) { card(tl.date) }  // overlay: never resizes the root
        }
    }

    @ViewBuilder func card(_ now: Date) -> some View {
        if m.state == "off" && m.resident { actions() } else { session(now) }
    }

    /// Resident and idle: what the app can start.
    func actions() -> some View {
        VStack(spacing: 10) {
            reveal(label(m.notice ?? "CallNotch", alert: m.notice != nil), after: 0.11)
            reveal(HStack(spacing: 14) {
                action("phone.fill", "Call", fill: Color(red: 0.19, green: 0.78, blue: 0.35), lit: Color(red: 0.3, green: 0.85, blue: 0.45)) { m.launch(listen: false) }
                action("waveform", "Listen") { m.launch(listen: true) }
                action("rectangle.stack.fill", "Library") { m.setOpen(false); Windows.library() }
                action("gearshape.fill", "Settings") { m.setOpen(false); Windows.settings() }
                action("power", "Quit") { quitApp() }
            }, after: 0.15)
        }
        .foregroundStyle(.white)
        .frame(width: geo.cardRight - ear, height: cardHeight)
        .allowsHitTesting(m.open)
        .offset(x: ear, y: geo.height)
    }

    func label(_ text: String, alert: Bool = false) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(alert ? amber : .white.opacity(0.5))
            .lineLimit(2).multilineTextAlignment(.center).padding(.horizontal, 16)
    }

    func action(_ icon: String, _ label: String, fill: Color = .white.opacity(0.14), lit: Color = .white.opacity(0.22),
                _ run: @escaping () -> Void) -> some View {
        VStack(spacing: 5) {
            Button(action: run) { Image(systemName: icon) }.buttonStyle(Round(fill: fill, lit: lit)).accessibilityLabel(label)
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
        }
    }

    func session(_ now: Date) -> some View {
        let s = Int(now.timeIntervalSince(m.since)), recorder = m.recorderMode
        let status = m.notice ?? (m.starting != nil ? (recorder ? m.progress.map { "Loading speech model \(Int($0 * 100))%" } ?? "Loading speech model" : "Connecting")
            : recorder ? (m.muted ? "Paused" : "Recording") : m.muted ? "Muted" : m.state.capitalized)
        return VStack(spacing: 10) {
            reveal(label(status, alert: m.notice != nil), after: 0.11)
            reveal(Text(s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)).font(.system(size: 26, weight: .medium)).monospacedDigit()
                .tracking(-0.26).frame(height: 26), after: 0.11)
            reveal(HStack(spacing: 16) {
                mute(now)
                Button { m.signalSession(SIGINT); m.setOpen(false) } label: { Image(systemName: recorder ? "stop.fill" : "phone.down.fill") }
                    .buttonStyle(Round(fill: Color(red: 1, green: 0x3B / 255, blue: 0x30 / 255), lit: Color(red: 1, green: 0x55 / 255, blue: 0x4A / 255)))
                    .accessibilityLabel(recorder ? "Stop" : "Hang up")
            }.padding(.top, 4), after: 0.15)
        }
        .foregroundStyle(.white)
        .frame(width: geo.cardRight - ear, height: cardHeight)
        .allowsHitTesting(m.open)
        .offset(x: ear, y: geo.height)
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
        return Button { m.signalSession(SIGUSR1) } label: {
            Image(systemName: m.recorderMode ? (shown ? "play.fill" : "pause.fill") : shown ? "mic.slash.fill" : "mic.fill").foregroundStyle(m.muted ? Color.black : .white)
                .opacity(v).scaleEffect(m.reduce ? 1 : 0.9 + 0.1 * v)
        }
        .buttonStyle(Round(fill: m.muted ? .white : .white.opacity(0.14), lit: m.muted ? .white : .white.opacity(0.22)))
        .accessibilityLabel(m.recorderMode ? (m.muted ? "Resume" : "Pause") : m.muted ? "Unmute" : "Mute")
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
