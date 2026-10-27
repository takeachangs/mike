import AppKit
import AVFoundation
import MikeKit
import ServiceManagement
import SwiftUI

/// The first-launch setup, one step at a time: microphone, speech model, dictation's Accessibility grant, the optional
/// OpenAI key, and a real dictation into the window. Also opened from Settings' "Run setup again…". The window (and so
/// this state) lives until Done, so closing it mid-setup and reopening resumes where it was.
struct Setup: View {
    static let steps = ["Welcome", "Microphone", "Speech model", "Dictation", "Voice calls", "Try it", "Done"]
    @State private var step = 0
    @State private var forward = true
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var download: Double? = Recorder.modelsOnDisk ? 1 : nil  // nil: not started; 1: ready
    @State private var downloadError: String?
    @State private var warmed = Dictation.warmed
    @AppStorage("dictation") private var dictation = true
    @State private var trusted = AXIsProcessTrusted()
    @State private var askedAX: Date?
    @State private var stale = false  // still untrusted 10 s after opening the pane: likely a grant pinned to an older build
    @State private var hasKey = false
    @State private var replacing = false
    @State private var key = ""
    @State private var checking = false
    @State private var keyError: String?
    @State private var unreachable = false
    @State private var tried = ""
    @State private var nothingCame = false
    @State private var loginItem = SMAppService.mainApp.status == .enabled || !UserDefaults.standard.bool(forKey: "onboarded")
    @FocusState private var fieldFocused: Bool
    @AccessibilityFocusState private var headingFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce
    let envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.isEmpty == false

    var canTry: Bool { mic == .authorized && dictation && trusted }
    var blocked: Bool { (step == 1 && mic != .authorized) || (step == 3 && dictation && !trusted) || checking }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Self.steps.indices, id: \.self) { i in
                    Group {  // done steps jump back; the current and later ones don't
                        if i < step { Button { jump(to: i) } label: { railItem(i) }.buttonStyle(.plain) } else { railItem(i) }
                    }
                    .accessibilityElement(children: .ignore)
                    // Numbered like the headers: Welcome and Done aren't steps
                    .accessibilityLabel(Self.steps[i] + (i == 0 || i == 6 ? "" : ", step \(i) of 5") + (i < step ? ", completed" : i == step ? ", current" : ""))
                    .accessibilityAddTraits(i < step ? .isButton : [])
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
                    if step > 0 && step < 6 { Button("Back") { jump(to: step - 1) }.keyboardShortcut("[", modifiers: .command) }
                    Spacer()
                    if step == 4 || (step == 5 && tried.isEmpty) { Button(step == 4 ? "Skip" : "Skip test") { jump(to: step + 1) }.buttonStyle(.borderless) }
                    Button(step == 0 ? "Get started" : step == 6 ? "Done" : step == 4 && !key.isEmpty ? (checking ? "Checking…" : "Save and continue") : "Continue") { next() }
                        .keyboardShortcut(.defaultAction).disabled(blocked)
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 48).padding(.top, 32).padding(.bottom, 24)
        }
        .frame(width: 760, height: 540)
        .task(id: download == 1) {  // load the model once it's on disk, so Try it doesn't wait out the first load
            guard download == 1, !warmed else { return }
            do { try await Dictation.warm(); warmed = true } catch {
                download = nil
                downloadError = "The speech model didn't load. Download it again."
            }
        }
    }

    func railItem(_ i: Int) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(i < step ? AnyShapeStyle(.green) : i == step ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                // Numbered like the headers: Welcome and Done aren't steps, so they get a symbol
                if i < step { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                else if i == 0 || i == 6 { Image(systemName: i == 0 ? "hand.wave.fill" : "flag.checkered").font(.system(size: 9, weight: .semibold)) }
                else { Text("\(i)").font(.system(size: 11, weight: .semibold)) }
            }
            .foregroundStyle(i <= step ? .white : .secondary)
            .frame(width: 20, height: 20)
            Text(Self.steps[i]).fontWeight(i == step ? .semibold : .regular).foregroundStyle(i == step ? .primary : .secondary)
            Spacer()
            if i == 2 && step != 2, let d = download, d < 1 { ProgressView(value: d).progressViewStyle(.circular).controlSize(.mini) }
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .background(i == step ? AnyShapeStyle(.background) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }

    func jump(to i: Int) {
        forward = i > step
        withAnimation(reduce ? .easeInOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.15)) { step = i }
    }

    func next() {
        switch step {
        case 4 where !key.isEmpty: Task { await saveKey(check: true) }
        case 6:
            if Bundle.main.bundleIdentifier != nil && loginItem != (SMAppService.mainApp.status == .enabled) { setLoginItem(loginItem) }
            UserDefaults.standard.set(true, forKey: "onboarded")
            Windows.finishSetup()
        default: jump(to: step + 1)
        }
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
                .accessibilityHidden(true)
                heading("Mike lives in your notch.", size: 26).padding(.top, 8)
                prose("Dictate anywhere with the right ⌘ key, record lectures with on-device transcripts, and make voice calls. A few permissions first. It takes about a minute.")
            case 1:
                header(1, "Microphone")
                prose("Mike hears you only while you dictate, record or call. Audio is never saved or uploaded for dictation and recordings.")
                row(footer: [.denied, .restricted].contains(mic) ? "In Privacy & Security › Microphone, turn on Mike. This window notices on its own." : nil) {
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
                row(footer: downloadError, error: true) {
                    VStack(spacing: 10) {
                        HStack {
                            Text("Parakeet Ultra").fontWeight(.medium)
                            Spacer()
                            Text(modelStatus).foregroundStyle(.secondary).monospacedDigit()
                            if download == nil { Button(downloadError == nil ? "Download" : "Try again") { fetchModel() } }
                        }
                        ProgressView(value: download ?? 0).tint(download ?? 0 >= 1 ? .green : nil)
                    }
                }
            case 3:
                header(3, "Dictation")
                prose("Hold right ⌘ to talk, release to type it. Tap it once to keep going, tap again to finish, Esc to cancel. To type into other apps, Mike needs Accessibility.")
                row(footer: trusted || askedAX == nil ? nil : stale
                    ? "Mike is on but this still says Waiting? Select Mike in the list, remove it with −, add it again with +, and turn it on."
                    : "In Privacy & Security › Accessibility, turn on Mike. This window notices on its own.") {
                    Text("Accessibility").fontWeight(.medium)
                    Spacer()
                    pill(trusted ? "Allowed" : askedAX != nil ? "Waiting…" : "Not yet", ok: trusted, waiting: askedAX != nil)
                    if !trusted { Button("Open System Settings") { openAccessibility() } }  // kept while waiting: the pane may have been closed
                }
                Toggle("Use dictation (you can change this later in Settings)", isOn: $dictation).foregroundStyle(.secondary)
            case 4:
                header(4, "Voice calls", optional: true)
                prose("Calls use OpenAI's GPT-Live with your own key, billed per second. Skip this if you only want dictation and recordings.")
                if hasKey && !replacing {
                    row {
                        Text("OpenAI API key").fontWeight(.medium)
                        Spacer()
                        pill("A key is saved", ok: true)
                        Button("Replace") { replacing = true }
                    }
                } else {
                    Text("OpenAI API key").fontWeight(.medium)
                    SecureField("OpenAI API key", text: $key, prompt: Text("sk-…")).labelsHidden().textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                        .onChange(of: key) { keyError = nil; unreachable = false }
                        .onSubmit { if !key.isEmpty && !checking { next() } }
                    if let keyError {
                        HStack {
                            Text(keyError).font(.caption).foregroundStyle(.red)
                            if unreachable { Button("Save anyway") { Task { await saveKey(check: false) } }.controlSize(.small) }
                        }
                    }
                    Text("Kept in your Keychain, never in a file.").font(.caption).foregroundStyle(.secondary)
                }
                if envKey { Text("OPENAI_API_KEY from the environment is used first.").font(.caption).foregroundStyle(.secondary) }
            case 5:
                header(5, "Try it")
                if !canTry {
                    let fix = mic != .authorized ? 1 : 3
                    prose(mic != .authorized ? "Mike can't hear you yet: the microphone isn't allowed." : !dictation ? "Dictation is turned off, so there's nothing to try."
                          : "Dictation can't type until Mike has Accessibility.")
                    Button("Go to \(Self.steps[fix])") { jump(to: fix) }
                } else {
                    if warmed {
                        prose("Hold right ⌘ and say something. The m in your notch opens into a circle when it's listening.")
                    } else if download == 1 {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); prose("Preparing the speech model…") }
                    } else {
                        prose("The speech model isn't downloaded yet. Download it first, or skip the test.")
                        Button("Go to Speech model") { jump(to: 2) }
                    }
                    // A real dictation: the paste's ⌘V lands here through the hidden Edit menu (main.swift). A field's own
                    // prompt rather than an overlay on a TextEditor, so the placeholder starts exactly where the text does.
                    TextField("Try it", text: $tried, prompt: Text("Your words appear here."), axis: .vertical)
                        .textFieldStyle(.plain).labelsHidden().font(.system(size: 14)).lineLimit(3...)
                        .focused($fieldFocused)
                        .padding(12)
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(fieldFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator)))
                    if !tried.isEmpty {
                        Label { Text("It works.").fontWeight(.medium) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    } else if nothingCame {
                        Text("Nothing came through? Make sure the box is focused (click in it), then hold right ⌘ while you speak and let go when you're done.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            default:
                heading("You're set.", size: 26).padding(.top, 8)
                prose("Click the notch any time for Call, Listen, Library and Settings. Hold right ⌘ anywhere to dictate.")
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    summary("Microphone", mic == .authorized ? "Allowed" : "Not allowed", ok: mic == .authorized, fix: mic == .authorized ? nil : 1)
                    summary("Speech model", download == 1 ? "Ready" : download != nil ? "Downloading… \(Int(download! * 100))%" : "Not downloaded",
                            ok: download == 1, waiting: download != nil, fix: download == nil ? 2 : nil)
                    summary("Dictation", !dictation ? "Off" : trusted ? "On" : "Needs Accessibility", ok: dictation && trusted, fix: dictation && !trusted ? 3 : nil)
                    summary("Voice calls", hasKey || envKey ? "Set up" : "Skipped", ok: hasKey || envKey, fix: hasKey || envKey ? nil : 4)
                }
                .padding(.top, 4)
                Toggle("Open Mike at login", isOn: $loginItem).disabled(Bundle.main.bundleIdentifier == nil).padding(.top, 4)
            }
        }
        .task(id: step) {
            headingFocused = true  // VoiceOver lands on the new step's heading
            if step == 4 { hasKey = Keychain.stored != nil }  // read here, not at open: an ad-hoc build may ask for Keychain access
            if step == 5 { fieldFocused = true }
            // Neither grant has a change notification: poll while a step that needs them shows. Try it also watches the
            // dictation end, to say so when nothing arrived.
            guard [1, 3, 5, 6].contains(step) else { return }
            var busy = false
            while !Task.isCancelled {
                let m = AVCaptureDevice.authorizationStatus(for: .audio), t = AXIsProcessTrusted()
                if t && !trusted { model.installDictationTap() }  // now, rather than on main.swift's next 2 s tick
                if (step == 1 && m == .authorized && mic != .authorized) || (step == 3 && t && !trusted) { Windows.setup() }  // back from System Settings
                mic = m; trusted = t
                stale = askedAX.map { Date().timeIntervalSince($0) > 10 } ?? false
                let now = model.dictation != nil || model.transcribing
                if step == 5 && busy && !now {
                    try? await Task.sleep(for: .seconds(0.7))  // the paste lands after the transcript
                    nothingCame = tried.isEmpty
                }
                busy = now
                try? await Task.sleep(for: .seconds(step == 5 ? 0.25 : 1))
            }
        }
    }

    var modelStatus: String {
        guard let d = download else { return "600 MB" }
        // ponytail: FluidAudio reports a fraction only, so the megabytes are of the nominal 600 MB
        return d >= 1 ? "Ready" : "\(Int(d * 100))% · about \(Int((1 - d) * 600)) MB left"
    }

    func heading(_ text: String, size: CGFloat) -> some View {
        Text(text).font(.system(size: size, weight: .semibold)).tracking(-0.02 * size)
            .accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocused)
    }
    func prose(_ text: String) -> some View {
        Text(text).font(.system(size: 14)).lineSpacing(3).foregroundStyle(.secondary).frame(maxWidth: 430, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder func header(_ n: Int, _ title: String, optional: Bool = false) -> some View {
        Text("Step \(n) of 5" + (optional ? " · Optional" : "")).font(.system(size: 12, weight: .semibold)).textCase(.uppercase).tracking(0.7).foregroundStyle(.secondary)
        heading(title, size: 24)
    }
    /// A bordered box: one line of content, and below it a caption (red for an error) when there is one.
    func row(footer: String? = nil, error: Bool = false, @ViewBuilder _ v: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) { v() }
            if let footer { Text(footer).font(.caption).foregroundStyle(error ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary)).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.vertical, 14).padding(.horizontal, 16)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
    /// A status: the text in the primary colour (legible in every appearance), the colour carried by the symbol.
    func pill(_ text: String, ok: Bool, waiting: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.circle.fill" : waiting ? "clock.fill" : "circle.dashed")
                .foregroundStyle(ok ? AnyShapeStyle(.green) : waiting ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)).accessibilityHidden(true)
            Text(text)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.vertical, 2).padding(.horizontal, 8).background(.quaternary.opacity(0.6), in: Capsule())
        .accessibilityElement(children: .combine)
    }
    func summary(_ name: String, _ status: String, ok: Bool, waiting: Bool = false, fix: Int?) -> some View {
        GridRow {
            Text(name).fontWeight(.medium)
            pill(status, ok: ok, waiting: waiting)
            if let fix { Button(fix == 4 ? "Set up" : "Fix") { jump(to: fix) }.buttonStyle(.link).accessibilityLabel("\(fix == 4 ? "Set up" : "Fix") \(name)") }
        }
    }

    /// The same shared load as Settings' "Download now": it runs on in Recorder after this step (or window) is gone.
    func fetchModel() {
        download = 0; downloadError = nil
        Task { @MainActor in
            do {
                _ = try await Recorder.models { p in Task { @MainActor in download = min(p.fractionCompleted, 0.99) } }
                download = 1
            } catch {
                download = nil
                downloadError = offline(error) ? "You seem to be offline. Connect to the internet and try again." : "The download stopped: \(error.localizedDescription)"
            }
        }
    }

    /// No connection at all, here or in the underlying error; a timeout or a bad response is a different failure.
    func offline(_ error: Error) -> Bool {
        let codes: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                                      .dataNotAllowed, .internationalRoamingOff]
        return [error as NSError, (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError].contains {
            $0?.domain == NSURLErrorDomain && codes.map(\.rawValue).contains($0!.code)
        }
    }

    /// Checks the key with one free request (listing models) before saving it, unless the user chose to save anyway.
    func saveKey(check: Bool) async {
        keyError = nil; unreachable = false
        if check {
            checking = true
            defer { checking = false }
            var req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!, timeoutInterval: 10)
            req.setValue("Bearer \(key.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
            do {
                let (_, response) = try await URLSession(configuration: .ephemeral).data(for: req)
                if (response as? HTTPURLResponse)?.statusCode == 401 { keyError = "OpenAI didn't accept this key."; return }
            } catch {
                keyError = "Couldn't reach OpenAI to check the key."; unreachable = true
                return
            }
        }
        guard Keychain.setOpenAIKey(key) else { keyError = "The Keychain didn't save the key."; return }
        hasKey = true; replacing = false; key = ""
        jump(to: 5)
    }

    func openAccessibility() {
        askedAX = Date(); stale = false
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
