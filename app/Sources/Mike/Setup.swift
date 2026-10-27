import AppKit
import AVFoundation
import MikeKit
import SwiftUI

/// The first-launch setup, one step at a time: microphone, speech model, dictation's Accessibility grant, the optional
/// OpenAI key, and a real dictation into the window. Also opened from Settings' "Run setup again…".
struct Setup: View {
    static let steps = ["Welcome", "Microphone", "Speech model", "Dictation", "Voice calls", "Try it", "Done"]
    @State private var step = 0
    @State private var forward = true
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var download: Double? = Recorder.modelsOnDisk ? 1 : nil  // nil: not started; 1: ready
    @AppStorage("dictation") private var dictation = true
    @State private var trusted = AXIsProcessTrusted()
    @State private var askedAX = false
    @State private var key = ""
    @State private var tried = ""
    @Environment(\.accessibilityReduceMotion) private var reduce

    var blocked: Bool { (step == 1 && mic != .authorized) || (step == 3 && dictation && !trusted) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Self.steps.indices, id: \.self) { i in
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(i < step ? AnyShapeStyle(.green) : i == step ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                            if i < step { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                            else { Text("\(i + 1)").font(.system(size: 11, weight: .semibold)) }
                        }
                        .foregroundStyle(i <= step ? .white : .secondary)
                        .frame(width: 20, height: 20)
                        Text(Self.steps[i]).fontWeight(i == step ? .semibold : .regular).foregroundStyle(i == step ? .primary : .secondary)
                        Spacer()
                    }
                    .padding(.vertical, 7).padding(.horizontal, 10)
                    .background(i == step ? AnyShapeStyle(.background) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 7))
                }
                Spacer()
            }
            .padding(16).padding(.top, 8)
            .frame(width: 210)
            .background(.background.secondary)
            Divider()

            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    content.id(step)  // a new identity per step, so the old one leaves and the new one comes in
                        .transition(.asymmetric(insertion: reduce ? .opacity : .opacity.combined(with: .offset(x: forward ? 24 : -24)),
                                                removal: .opacity.animation(.easeOut(duration: 0.1))))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider().padding(.bottom, 16)
                HStack {
                    if step > 0 && step < 6 { Button("Back") { go(-1) } }
                    Spacer()
                    if step == 4 || step == 5 { Button(step == 4 ? "Skip" : "Skip test") { go(1) }.buttonStyle(.borderless) }
                    Button(step == 0 ? "Get started" : step == 6 ? "Done" : step == 4 && !key.isEmpty ? "Save and continue" : "Continue") { next() }
                        .keyboardShortcut(.defaultAction).disabled(blocked)
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 48).padding(.top, 32).padding(.bottom, 24)
        }
        .frame(width: 760, height: 540)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            mic = AVCaptureDevice.authorizationStatus(for: .audio)  // back from System Settings
        }
    }

    func go(_ by: Int) {
        forward = by > 0
        withAnimation(reduce ? .easeInOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.15)) { step += by }
    }

    func next() {
        switch step {
        case 4 where !key.isEmpty:
            guard Keychain.setOpenAIKey(key) else {
                let alert = NSAlert()
                alert.messageText = "The Keychain did not save the key."
                alert.runModal()
                return
            }
        case 6:
            UserDefaults.standard.set(true, forKey: "onboarded")
            NSApp.keyWindow?.close()
            return
        default: break
        }
        go(1)
    }

    @ViewBuilder var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch step {
            case 0:
                Canvas { ctx, size in  // the notch with the resting m, drawn like Notch.draw does
                    for (x, y) in Notch.mShape {
                        ctx.fill(Path(ellipseIn: CGRect(x: 30 + x * 1.5 - 2.25, y: size.height / 2 + y * 1.5 - 2.25, width: 4.5, height: 4.5)), with: .color(.white))
                    }
                }
                .frame(width: 220, height: 44)
                .background(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16).fill(.black))
                heading("Mike lives in your notch.", size: 26).padding(.top, 8)
                prose("Dictate anywhere with the right ⌘ key, record lectures with on-device transcripts, and make voice calls. A few permissions first. It takes about a minute.")
            case 1:
                header(1, "Microphone")
                prose("Mike hears you only while you dictate, record or call. Audio is never saved or uploaded for dictation and recordings.")
                row {
                    Text("Microphone access").fontWeight(.medium)
                    Spacer()
                    pill(mic == .authorized ? "Allowed" : mic == .notDetermined ? "Not yet" : "Not allowed", ok: mic == .authorized)
                    if mic == .notDetermined {
                        Button("Allow…") { Task { _ = await Notch.microphoneAllowed(); mic = AVCaptureDevice.authorizationStatus(for: .audio) } }
                    } else if mic != .authorized {
                        Button("Open System Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
                    }
                }
            case 2:
                header(2, "Speech model")
                prose("Dictation and recordings are transcribed on this Mac with Parakeet. It's about 600 MB, downloaded once. You can continue while it downloads.")
                row {
                    VStack(spacing: 10) {
                        HStack {
                            Text("Parakeet Ultra").fontWeight(.medium)
                            Spacer()
                            Text(download == nil ? "600 MB" : download! >= 1 ? "Ready" : "Downloading… \(Int(download! * 100))%").foregroundStyle(.secondary).monospacedDigit()
                            if download == nil { Button("Download") { fetchModel() } }
                        }
                        ProgressView(value: download ?? 0).tint(download ?? 0 >= 1 ? .green : nil)
                    }
                }
            case 3:
                header(3, "Dictation")
                prose("Hold right ⌘ to talk, release to type it. Tap it once to keep going, tap again to finish, Esc to cancel. To type into other apps, Mike needs Accessibility.")
                row {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Accessibility").fontWeight(.medium)
                            Spacer()
                            pill(trusted ? "Allowed" : askedAX ? "Waiting…" : "Not yet", ok: trusted, waiting: askedAX)
                            if !trusted && !askedAX { Button("Open System Settings") { openAccessibility() } }
                        }
                        if askedAX && !trusted {
                            Text("In Privacy & Security › Accessibility, turn on Mike. This window notices on its own.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle("Use dictation (you can change this later in Settings)", isOn: $dictation).foregroundStyle(.secondary)
            case 4:
                header(4, "Voice calls", optional: true)
                prose("Calls use OpenAI's GPT-Live with your own key, billed per second. Skip this if you only want dictation and recordings.")
                Text("OpenAI API key").fontWeight(.medium)
                SecureField("OpenAI API key", text: $key, prompt: Text("sk-…")).labelsHidden().textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                Text("Kept in your Keychain, never in a file.").font(.caption).foregroundStyle(.secondary)
            case 5:
                header(5, "Try it")
                prose("Click in the box, then hold right ⌘ and say something. The m in your notch opens into a circle when it's listening.")
                // A real dictation: the paste's ⌘V lands here through the hidden Edit menu (main.swift).
                TextEditor(text: $tried).font(.system(size: 14)).scrollContentBackground(.hidden)
                    .padding(8).frame(height: 90)
                    .overlay(alignment: .topLeading) {
                        if tried.isEmpty { Text("Your words appear here.").font(.system(size: 14)).foregroundStyle(.tertiary).padding(13).allowsHitTesting(false) }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            default:
                heading("You're set.", size: 26).padding(.top, 24)
                prose("Click the notch any time for Call, Listen, Library and Settings. Hold right ⌘ anywhere to dictate.")
            }
        }
        .task(id: step) {  // Accessibility has no change notification: poll while its step shows
            guard step == 3 else { return }
            while !Task.isCancelled && !trusted {
                try? await Task.sleep(for: .seconds(1))
                trusted = AXIsProcessTrusted()
            }
            if trusted { model.installDictationTap() }  // now, rather than on main.swift's next 2 s tick
        }
    }

    func heading(_ text: String, size: CGFloat) -> some View { Text(text).font(.system(size: size, weight: .semibold)).tracking(-0.02 * size) }
    func prose(_ text: String) -> some View {
        Text(text).font(.system(size: 14)).lineSpacing(3).foregroundStyle(.secondary).frame(maxWidth: 430, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder func header(_ n: Int, _ title: String, optional: Bool = false) -> some View {
        Text("Step \(n) of 5" + (optional ? " · Optional" : "")).font(.system(size: 12, weight: .semibold)).textCase(.uppercase).tracking(0.7).foregroundStyle(.secondary)
        heading(title, size: 24)
    }
    func row(@ViewBuilder _ v: () -> some View) -> some View {
        HStack(spacing: 12) { v() }.padding(.vertical, 14).padding(.horizontal, 16)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
    func pill(_ text: String, ok: Bool, waiting: Bool = false) -> some View {
        let tint: Color = ok ? .green : waiting ? .orange : .secondary
        return Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(tint)
            .padding(.vertical, 2).padding(.horizontal, 9).background(tint.opacity(0.15), in: Capsule())
    }

    /// The same shared load as Settings' "Download now": it runs on in Recorder after this step (or window) is gone.
    func fetchModel() {
        download = 0
        Task { @MainActor in
            do {
                _ = try await Recorder.models { p in Task { @MainActor in download = min(p.fractionCompleted, 0.99) } }
                download = 1
            } catch {
                download = nil
                NSAlert(error: error).runModal()
            }
        }
    }

    func openAccessibility() {
        askedAX = true
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
