import AVFoundation
import MikeKit
import Foundation

enum LaunchError: LocalizedError {
    case noKey, micDenied
    var errorDescription: String? {
        switch self {
        case .noKey: "Add your OpenAI API key in Settings to make calls."
        case .micDenied: "Microphone access is off. Allow it in System Settings > Privacy & Security > Microphone."
        }
    }
}

/// Sessions the resident app runs itself: a plain GPT-Live call or a recording, both inside this process.
extension Notch {
    /// One session at a time, counting one still starting (model download, connecting) or still saving.
    var busy: Bool { state != "off" || launching || stopping || recorder != nil || call != nil }

    /// `testAudio` plays a file in real time instead of the microphone (the `--test-audio` launch argument).
    func launch(listen: Bool, testAudio: URL? = nil) {
        guard resident, !busy else { return }
        setOpen(false)
        starting = Date(); progress = nil; recorderMode = listen; cancelled = false; launching = true
        Task { @MainActor in
            defer { launching = false }
            do {
                try Paths.ensureStateDir()
                if testAudio == nil, !(await Self.microphoneAllowed()) { throw LaunchError.micDenied }
                if listen {
                    let models = try await Recorder.models { p in Task { @MainActor in self.progress = p.fractionCompleted } }
                    if cancelled { throw CancellationError() }  // stopped during the download: never start
                    let r = try Recorder(output: Paths.newRecording())  // only now, so a failed download leaves no empty file
                    r.onError = { message in Task { @MainActor in self.say(message) } }
                    do { try await r.start(testAudio.map { .file($0) } ?? .microphone, models: models) } catch {
                        try? FileManager.default.removeItem(at: r.output)
                        throw error
                    }
                    recorder = r
                    if cancelled { await stopAndWait() }
                } else {
                    guard let key = Keychain.openAIKey else { throw LaunchError.noKey }
                    let c = LiveCall(apiKey: key, instructions: LiveCall.soloInstructions)
                    c.hangUpAfterSilence = UserDefaults.standard.object(forKey: "silenceHangUp") as? Double ?? 30
                    c.onEnd = { url in  // the notch model lives as long as the app, so no capture cycle matters here
                        self.call = nil
                        if url != nil { self.say("Call saved to Library", for: 3) }
                    }
                    c.onError = { message in self.say(message) }
                    call = c
                    try await c.start()  // a hang-up while connecting makes this throw
                }
            } catch {
                starting = nil; progress = nil; call = nil
                if !cancelled {
                    Log.app.error("could not start: \(error.localizedDescription, privacy: .public)")
                    say(error.localizedDescription)
                }
            }
        }
    }

    func stopLocal() { Task { @MainActor in await stopAndWait() } }

    /// Ends this app's own session and returns once it is saved. Stopping a session that is still starting cancels it.
    func stopAndWait() async {
        if launching {
            cancelled = true
            starting = nil  // the notch folds now; the launch task gives up at its next step
        }
        if let c = call {
            c.hangUp()
            for _ in 0..<70 where call != nil { try? await Task.sleep(for: .milliseconds(100)) }  // onEnd clears it; close waits up to 5 s
        }
        guard let r = recorder else { return }
        recorder = nil
        stopping = true
        defer { stopping = false }
        do { _ = try await r.stop(); say("Recording saved to Library", for: 3) } catch { say(error.localizedDescription) }
    }

    /// Asks the first time; false once refused (the user then has to change it in System Settings).
    static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }
}
