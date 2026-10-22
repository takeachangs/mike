// CallNotch: lives in the MacBook notch. Two ways to run:
// - On its own (the app, at login or from Finder) it is resident: clicking the notch opens Call / Listen / Library /
//   Settings / Quit. Calls (GPT-Live) and recordings (Parakeet Ultra, on-device) run inside the app, and it shows any
//   other session too (a skill's /call or /listen) from ~/.claude-call/state.json. Its pid goes in app.pid so those
//   sessions do not start a second notch.
// - Launched by a session with CALL_BRIDGE_PID (bridge.py, the Listen CLI, notch/drive.py) it is only that session's
//   indicator and quits when the session ends. CALL_NOTCH_MODE=listen labels it as a recorder.
import AppKit
import CallNotchKit
import SwiftUI

let env = ProcessInfo.processInfo.environment
let envPID = env["CALL_BRIDGE_PID"].flatMap { pid_t($0) }
let resident = envPID == nil

if CommandLine.arguments.contains("--version") { print(appVersion); exit(0) }
if resident, let other = (try? String(contentsOf: Paths.appPID, encoding: .utf8)).flatMap({ pid_t($0) }), other != getpid(), kill(other, 0) == 0 {
    print("CallNotch is already at the notch (pid \(other))")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // no Dock icon; LSUIElement in Info.plist says the same for the bundle
if resident, let v = UserDefaults.standard.object(forKey: "soundVolume") as? Double { Cue.level = v }

let model = MainActor.assumeIsolated { Notch(resident: resident, envPID: envPID, recorderMode: env["CALL_NOTCH_MODE"] == "listen") }
let panel = NSPanel(contentRect: geo.collapsed, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = false
panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
let host = Host(rootView: NotchView(m: model))
host.sizingOptions = []
panel.contentView = host
panel.setFrame(geo.collapsed, display: true)
panel.orderFrontRegardless()
MainActor.assumeIsolated {
    model.panel = panel
    if env["CALL_NOTCH_OPEN"] != nil { model.setOpen(true) }  // ponytail: debug, starts with the card open
}
Log.app.info("CallNotch \(appVersion, privacy: .public) started, \(resident ? "resident" : "session", privacy: .public)")

Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in MainActor.assumeIsolated { model.poll() } }

// A display plugged in or out, or a resolution change, moves the notch: rebuild the geometry and re-seat the panel.
NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
    MainActor.assumeIsolated {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        geo = NotchGeometry(screen: screen)
        model.setOpen(false)
        panel.setFrame(geo.collapsed, display: true)
        Log.app.info("screen changed, notch at \(geo.notchLeft, privacy: .public)...\(geo.notchRight, privacy: .public)")
    }
}

if resident {
    try? Paths.ensureStateDir()
    try? "\(getpid())".write(to: Paths.appPID, atomically: true, encoding: .utf8)
    if !UserDefaults.standard.bool(forKey: "onboarded") { MainActor.assumeIsolated { Windows.settings(welcome: true) } }
}

/// Leave the notch: end this app's own session first (so its transcript is saved), fold the card and tab, exit.
/// A resident app also gives up app.pid.
@MainActor func quitApp() {
    model.stopLocal()
    model.hangUp = true; model.poll()
    if resident { try? FileManager.default.removeItem(at: Paths.appPID) }
    let wait = model.recorder != nil || model.call != nil ? 6.0 : 0.5  // ponytail: a fixed wait for the final save, not a join
    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { exit(0) }
}

// bridge.py sends SIGTERM on hang-up (when it launched us); logout sends it to a resident app. Same exit either way.
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler { MainActor.assumeIsolated { quitApp() } }
term.resume()

app.run()
