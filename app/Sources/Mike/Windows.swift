import AppKit
import AVFoundation
import MikeKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// The app's ordinary windows. The app is an accessory (no Dock icon), so opening one also activates the app.
@MainActor enum Windows {
    private static var open: [String: NSWindow] = [:]

    static func library() { show("library", "Library", CGSize(width: 900, height: 600), Library()) }
    static func settings() { show("settings", "Settings", CGSize(width: 520, height: 440), SettingsView()) }
    static func setup() {
        if open["setup"]?.isVisible == false { open["setup"] = nil }  // a closed one starts over at Welcome
        show("setup", "Welcome to Mike", CGSize(width: 760, height: 540), Setup())
    }

    private static func show(_ id: String, _ title: String, _ size: CGSize, _ view: some View) {
        let w = open[id] ?? {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: view)
            w.center()
            open[id] = w
            return w
        }()
        w.title = title
        NSApp.activate()  // macOS 14 dropped activate(ignoringOtherApps:): the old call left the window behind
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }
}

// ------------------------------------------------------------------------------------------------ library

struct Library: View {
    @State private var sessions = Session.load()
    @State private var selection: URL?
    @State private var query = ""

    var shown: [Session] {
        query.isEmpty ? sessions : sessions.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.body.localizedCaseInsensitiveContains(query)
                || ($0.notes?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack {  // a plain field, not .searchable: this window has no SwiftUI-managed toolbar
                    TextField("Search transcripts", text: $query).textFieldStyle(.roundedBorder)
                    Button { sessions = Session.load() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Reload")
                }
                .padding(8)
                if shown.isEmpty {
                    Text(sessions.isEmpty ? "No calls or recordings yet.\nStart one from the notch." : "Nothing matches.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxHeight: .infinity)
                } else {
                    List(shown, selection: $selection) { s in Card(s: s).tag(s.id) }
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } detail: {
            if let s = sessions.first(where: { $0.id == selection }) {
                Detail(s: s) {
                    selection = nil
                    sessions = Session.load()
                }
            } else {
                Text("\(sessions.count) sessions").foregroundStyle(.secondary)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in sessions = Session.load() }
    }
}

struct Card: View {
    let s: Session
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: s.kind == .call ? "phone.fill" : "waveform").foregroundStyle(s.kind == .call ? .green : .orange)
                .frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(s.title).font(.headline).lineLimit(1)
                Text(s.date.formatted(date: .abbreviated, time: .shortened) + (s.minutes.map { " · \($0) min" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                Text(s.body.prefix(160)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

struct Detail: View {
    let s: Session
    let onDelete: () -> Void
    @State private var tab = 0

    var text: String { s.notes != nil && tab == 0 ? s.notes! : s.body }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(s.title).font(.title2.bold()).lineLimit(1)
                Spacer()
                if s.notes != nil {
                    Picker("", selection: $tab) { Text("Notes").tag(0); Text("Transcript").tag(1) }
                        .pickerStyle(.segmented).fixedSize()
                }
                Menu {
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                    Button("Export…") { export() }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([s.id]) }
                    Divider()
                    Button("Move to Trash", role: .destructive) { delete() }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            .padding()
            Divider()
            ScrollView {
                Text(s.notes != nil && tab == 0 ? markdown(s.notes!) : AttributedString(s.body))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
            }
        }
    }

    func markdown(_ text: String) -> AttributedString {
        // ponytail: inline markdown only (bold, italics, code, links); headings and lists show as plain lines
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = s.id.deletingPathExtension().lastPathComponent + (s.notes != nil && tab == 0 ? ".md" : ".txt")
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { NSAlert(error: error).runModal() }
    }

    func delete() {
        let alert = NSAlert()
        alert.messageText = "Move \"\(s.title)\" to the Trash?"
        alert.informativeText = "The transcript\(s.notes != nil ? " and its notes" : "") can be put back from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try s.trash(); onDelete() } catch { NSAlert(error: error).runModal() }
    }
}

// ------------------------------------------------------------------------------------------------ settings

/// Settings: what the app needs and why. First launch shows Setup instead.
struct SettingsView: View {
    @State private var key = Keychain.stored ?? ""
    @State private var keySaved = Keychain.stored != nil
    @AppStorage("soundVolume") private var volume = 0.25
    @AppStorage("silenceHangUp") private var silence = 30.0
    @State private var loginItem = SMAppService.mainApp.status == .enabled
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var model: String? = Recorder.modelsOnDisk ? "Downloaded" : nil
    @AppStorage("dictation") private var dictation = true
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                Form {
                    Section("Microphone") {
                        LabeledContent("Access") {
                            switch mic {
                            case .authorized: Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            case .notDetermined: Button("Allow microphone") { Task { _ = await Notch.microphoneAllowed(); mic = AVCaptureDevice.authorizationStatus(for: .audio) } }
                            default: Button("Open Privacy Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
                            }
                        }
                    }
                    Section {
                        Toggle("Dictate with the right ⌘ key", isOn: $dictation)
                        LabeledContent("Accessibility") {
                            if trusted { Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                            else { Button("Open Accessibility Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) } }
                        }
                    } header: { Text("Dictation") } footer: {
                        Text("Hold right ⌘ and speak, or tap it to start and tap again to stop; Esc cancels. The words are transcribed on this Mac and typed where your cursor is, which needs Accessibility access.")
                    }
                    Section("General") {
                        LabeledContent("Sound volume") {
                            HStack {
                                Slider(value: $volume, in: 0...1).frame(width: 160)
                                    .onChange(of: volume) { Cue.level = volume }
                                Button { Cue.ready.play() } label: { Image(systemName: "speaker.wave.2") }.buttonStyle(.borderless).help("Play a cue")
                            }
                        }
                        Toggle("Open at login", isOn: $loginItem)
                            .onChange(of: loginItem) { setLoginItem(loginItem) }
                            .disabled(Bundle.main.bundleIdentifier == nil)
                        LabeledContent("Data folder") { Button("Show in Finder") { NSWorkspace.shared.open(Paths.stateDir) } }
                        LabeledContent("Setup") { Button("Run setup again…") { Windows.setup() } }
                        LabeledContent("Version") { Text(appVersion).foregroundStyle(.secondary) }
                    }
                }
                .formStyle(.grouped)
                .tabItem { Label("General", systemImage: "gearshape") }

                Form {
                    Section {
                        LabeledContent("Speech model") {
                            if let model { Text(model).foregroundStyle(.secondary) } else { Button("Download now") { download() } }
                        }
                    } header: { Text("Recording") } footer: {
                        Text("Recordings are transcribed on this Mac with Parakeet Ultra (about 600 MB, downloaded once). Audio is never saved or uploaded.")
                    }
                }
                .formStyle(.grouped)
                .tabItem { Label("Listen", systemImage: "waveform") }

                // Everything a future paywall gates lives in this tab (see the paywall issue), so gating it is a single `if`.
                Form {
                    Section {
                        SecureField("OpenAI API key", text: $key, prompt: Text("sk-…"))
                            .onChange(of: key) { keySaved = false }
                        HStack {
                            Button(keySaved ? "Saved" : "Save key") { keySaved = Keychain.setOpenAIKey(key) }.disabled(keySaved)
                            if ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.isEmpty == false {
                                Text("OPENAI_API_KEY from the environment is used first.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Picker("Hang up after silence", selection: $silence) {
                            Text("Never").tag(0.0); Text("15 seconds").tag(15.0); Text("30 seconds").tag(30.0)
                            Text("1 minute").tag(60.0); Text("90 seconds").tag(90.0)
                        }
                    } header: { Text("Calls") } footer: {
                        Text("Calls use OpenAI's GPT-Live and are billed to this key per second, silence included. The key is kept in your Keychain. Saying goodbye also hangs up; a soft cue plays 10 seconds before a silent call ends.")
                    }
                }
                .formStyle(.grouped)
                .tabItem { Label("Call", systemImage: "phone") }
            }
        }
        .onAppear { mic = AVCaptureDevice.authorizationStatus(for: .audio); trusted = AXIsProcessTrusted() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in trusted = AXIsProcessTrusted() }
    }

    func download() {
        model = "Downloading…"
        Task { @MainActor in
            do {
                _ = try await Recorder.models { p in Task { @MainActor in model = "Downloading… \(Int(p.fractionCompleted * 100))%" } }
                model = "Ready"
            } catch {
                model = nil
                NSAlert(error: error).runModal()
            }
        }
    }

    func setLoginItem(_ on: Bool) {
        do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() } catch {
            loginItem = SMAppService.mainApp.status == .enabled
            NSAlert(error: error).runModal()
        }
    }
}

let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
