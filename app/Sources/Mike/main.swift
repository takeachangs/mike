// Mike: lives in the MacBook notch. Two ways to run:
// - On its own (the app, at login or from Finder) it is resident: clicking the notch opens Call / Listen / Library /
//   Settings / Quit. Calls (GPT-Live) and recordings (Parakeet Ultra, on-device) run inside the app, and it shows any
//   other session too (a skill's /call or /listen) from ~/.mike/state.json. Its pid goes in app.pid so those
//   sessions do not start a second notch.
//   `open -a Mike --args --listen` starts a recording right away; `--test-audio <file>` records a file played in
//   real time instead of the mic (for testing without speaking).
// - Launched by a session with CALL_BRIDGE_PID (bridge.py, the Listen CLI, notch/drive.py) it is only that session's
//   indicator and quits when the session ends. CALL_NOTCH_MODE=listen labels it as a recorder.
import AppKit
import MikeKit
import SwiftUI

let env = ProcessInfo.processInfo.environment
let envPID = env["CALL_BRIDGE_PID"].flatMap { pid_t($0) }
let resident = envPID == nil

if CommandLine.arguments.contains("--version") { print(appVersion); exit(0) }
if resident, let other = (try? String(contentsOf: Paths.appPID, encoding: .utf8)).flatMap({ pid_t($0) }), other != getpid(), kill(other, 0) == 0 {
    print("Mike is already at the notch (pid \(other))")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // no Dock icon; LSUIElement in Info.plist says the same for the bundle
// Never shown (no menu bar for an accessory app), but ⌘X/C/V/A/Z in text fields (the API key) only work through it.
app.mainMenu = {
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let item = NSMenuItem(), main = NSMenu()
    item.submenu = edit
    main.addItem(NSMenuItem())  // the app menu slot comes first
    main.addItem(item)
    return main
}()
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
Log.app.info("Mike \(appVersion, privacy: .public) started, \(resident ? "resident" : "session", privacy: .public)")

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
    let args = CommandLine.arguments
    let testAudio = args.firstIndex(of: "--test-audio").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
    MainActor.assumeIsolated {
        if args.contains("--listen") { model.launch(listen: true, testAudio: testAudio) }
        else if !UserDefaults.standard.bool(forKey: "onboarded") { Windows.settings(welcome: true) }
    }
}

/// Every way out goes through NSApp.terminate: the card's Quit, SIGTERM (bridge.py on hang-up, install.sh), logout,
/// Activity Monitor. Termination waits until this app's own session has stopped and saved, then folds the notch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Opening the app again (Finder, Spotlight, the Dock) while it runs: it has no window of its own, so show the
    /// notch card, and the setup window until setup is done.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated {
            if resident && !model.open { model.setOpen(true) }
            if !UserDefaults.standard.bool(forKey: "onboarded") { Windows.settings(welcome: true) }
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            if resident { try? FileManager.default.removeItem(at: Paths.appPID) }
            model.hangUp = true; model.poll()
            model.quitting = true  // the tab folds into the notch first
            Task { @MainActor in
                await model.stopAndWait()
                try? await Task.sleep(for: .milliseconds(resident ? 300 : 0))
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }
}
let delegate = AppDelegate()  // NSApplication holds its delegate weakly
app.delegate = delegate

@MainActor func quitApp() { NSApp.terminate(nil) }

signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
// Not terminate() inside the handler: it runs as a main-queue block, and .terminateLater's wait needs that queue free.
term.setEventHandler { RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { quitApp() } } }
term.resume()

app.run()
