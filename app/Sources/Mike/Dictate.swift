import AppKit
import AVFoundation
import MikeKit

/// Dictation on the right ⌘ key (DictationKey has the rules): the words are transcribed on this Mac and pasted into
/// whatever has focus. A CGEventTap rather than NSEvent monitors, because Esc in click mode must not also reach the
/// front app. Both the tap and the paste need Accessibility. Resident app only.
extension Notch {
    static var dictationOn: Bool { UserDefaults.standard.object(forKey: "dictation") as? Bool ?? true }

    /// Installs the key tap once Accessibility allows it. Called at launch and every few seconds after, so granting
    /// access in System Settings takes effect without a relaunch.
    func installDictationTap() {
        guard tap == nil, Self.dictationOn else { return }
        guard AXIsProcessTrusted() else {
            if !UserDefaults.standard.bool(forKey: "askedAccessibility") {  // the system prompt once; Settings shows it after
                UserDefaults.standard.set(true, forKey: "askedAccessibility")
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            }
            return
        }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue | 1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                          callback: { _, type, event, me in
            let notch = Unmanaged<Notch>.fromOpaque(me!).takeUnretainedValue()
            return MainActor.assumeIsolated { notch.key(type, event) } ? nil : Unmanaged.passUnretained(event)  // nil swallows it
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { Log.app.error("could not install the dictation key tap"); return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        self.tap = tap
        Log.app.info("dictation on right ⌘")
    }

    /// Every flagsChanged and keyDown on the system, on the main thread: kept short. True swallows the event.
    func key(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard Self.dictationOn else { return false }
        let code = event.getIntegerValueField(.keyboardEventKeycode), action: DictationKey.Action?
        var swallow = false
        if type == .flagsChanged {
            guard code == 0x36 else { return false }  // kVK_RightCommand
            let down = event.flags.rawValue & 0x10 != 0  // NX_DEVICERCMDKEYMASK: right ⌘ alone, whatever left ⌘ is doing
            if down && !keys.latched && busy { return false }  // a call, a recording or the last dictation has the mic
            action = keys.rightCommand(down: down, at: ProcessInfo.processInfo.systemUptime)
        } else {
            let esc = code == 0x35, latched = keys.latched  // kVK_Escape
            action = keys.key(escape: esc)
            swallow = esc && latched && action == .cancel
        }
        if let action { DispatchQueue.main.async { MainActor.assumeIsolated { self.dictate(action) } } }  // starting the mic is slow
        return swallow
    }

    func dictate(_ action: DictationKey.Action) {
        switch action {
        case .start:
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                keys = DictationKey()
                Task { if !(await Self.microphoneAllowed()) { say(LaunchError.micDenied.localizedDescription) } }
                return
            }
            let d = Dictation()
            do { try d.start() } catch {
                keys = DictationKey()
                say(error.localizedDescription)
                return
            }
            dictation = d; dictatedAt = Date()
            panel?.setFrame(geo.expanded, display: true)  // room for the aura below the notch
            wake(true)
            if Recorder.modelsOnDisk { Task { try? await Dictation.warm() } }  // loads while you speak; kept loaded after
        case .cancel:
            dictation?.cancel(); dictation = nil; auraOut = 0.15
        case .finish:
            guard let d = dictation else { return }
            dictation = nil; transcribing = true
            if !Recorder.modelsOnDisk { say("Downloading the speech model (about 600 MB) for dictation…", for: 10) }
            Task { @MainActor in
                do {
                    let text = try await d.finish()
                    auraOut = text.isEmpty ? 0.15 : 0.6
                    if !text.isEmpty { paste(text) }
                } catch {
                    auraOut = 0.15
                    Log.app.error("dictation failed: \(error.localizedDescription, privacy: .public)")
                    say(error.localizedDescription)
                }
                transcribing = false
            }
        }
    }

    /// Pastes through the pasteboard with a synthesized ⌘V, then puts back what was there unless something else has
    /// been copied meanwhile. Marked transient so clipboard managers skip it.
    // ponytail: key code 9 is V on ANSI layouts, so on a layout without V there (Dvorak) the paste is a different key.
    func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved = (pb.pasteboardItems ?? []).map { item in  // copied now: clearContents() invalidates the originals
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let mine = pb.changeCount
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard pb.changeCount == mine else { return }
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
    }
}
