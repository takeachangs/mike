import AppKit
import MikeKit

/// Hold the right ⌘ key, speak, let go: the words are pasted where the cursor is. Parakeet on this Mac, nothing saved.
/// Off until Settings turns it on; needs Accessibility access to see the key and to paste into other apps.
@MainActor final class Dictation {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "dictation") }
    static var trusted: Bool { AXIsProcessTrusted() }
    private let notch: Notch
    private var recorder: Recorder?, held = false, cancelled = false, gen = 0

    init(_ notch: Notch) {
        self.notch = notch
        if Self.enabled { Self.warm() }
        // The global monitor sees keys only once the app is trusted for Accessibility; the local one covers our own windows.
        NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { e in MainActor.assumeIsolated { self.handle(e) } }
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { e in MainActor.assumeIsolated { self.handle(e) }; return e }
    }

    /// Loads the speech model now, so the first hold does not wait for it. Loaded models stay for the app's life.
    static func warm() { Task { @MainActor in _ = try? await Recorder.models() } }

    /// The system prompt for Accessibility access (it offers to open System Settings).
    static func askTrust() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) }

    private func handle(_ e: NSEvent) {
        guard Self.enabled else { return }
        if e.type == .keyDown { if held { cancelled = true }; return }  // ⌘C, ⌘Tab while held: a shortcut, not dictation
        guard e.keyCode == 54 else { return }  // the right ⌘
        let down = e.modifierFlags.contains(.command)
        if down && !held { held = true; cancelled = false; start() } else if !down && held { held = false; stop() }
    }

    // ponytail: the mic takes ~0.3 s to come up after the key goes down (the start cue marks it); pre-arming the engine would close that
    private func start() {
        guard !notch.busy else { return }
        gen += 1
        let g = gen
        Task { @MainActor in
            do {
                guard await Notch.microphoneAllowed() else { throw LaunchError.micDenied }
                let models = try await Recorder.models()
                let r = try Recorder(output: FileManager.default.temporaryDirectory.appending(path: "mike-dictation.txt"))
                try await r.start(.microphone, models: models)
                guard g == gen, held else { _ = try? await r.stop(); return }  // let go before the mic was up
                recorder = r
            } catch { notch.say(error.localizedDescription) }
        }
    }

    private func stop() {
        gen += 1
        guard let r = recorder else { return }
        recorder = nil
        let discard = cancelled
        Task { @MainActor in
            do {
                _ = try await r.stop()
                if !discard, !r.transcript.isEmpty { Self.paste(r.transcript) }
            } catch { notch.say(error.localizedDescription) }
        }
    }

    /// Through the front app's own ⌘V, which works everywhere, then the clipboard is put back.
    // ponytail: only text is put back; an image or files on the clipboard before are gone
    private static func paste(_ text: String) {
        let pb = NSPasteboard.general, old = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: down)  // V
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { pb.clearContents(); if let old { pb.setString(old, forType: .string) } }
    }
}
