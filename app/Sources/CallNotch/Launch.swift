import AVFoundation
import CallNotchKit
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
    var busy: Bool { state != "off" || starting != nil || recorder != nil || call != nil }

    func launch(listen: Bool) {
        guard resident, !busy else { return }
        setOpen(false)
        starting = Date(); progress = nil; recorderMode = listen
        Task { @MainActor in
            do {
                try Paths.ensureStateDir()
                guard await Self.microphoneAllowed() else { throw LaunchError.micDenied }
                if listen {
                    let r = try Recorder(output: Paths.newRecording())
                    let models = try await Recorder.models { p in
                        Task { @MainActor in self.progress = p.fractionCompleted }
                    }
                    try await r.start(.microphone, models: models)
                    recorder = r
                } else {
                    guard let key = Keychain.openAIKey else { throw LaunchError.noKey }
                    let c = LiveCall(apiKey: key, instructions: LiveCall.soloInstructions)
                    c.onEnd = { url in  // the notch model lives as long as the app, so no capture cycle matters here
                        self.call = nil
                        if url != nil { self.say("Call saved to Library", for: 3) }
                    }
                    c.onError = { message in self.say(message) }
                    call = c
                    try await c.start()
                }
            } catch {
                Log.app.error("could not start: \(error.localizedDescription, privacy: .public)")
                starting = nil; progress = nil; recorder = nil; call = nil
                say(error.localizedDescription)
            }
        }
    }

    func stopLocal() {
        call?.hangUp()
        guard let r = recorder else { return }
        recorder = nil
        Task { @MainActor in
            do { _ = try await r.stop(); say("Recording saved to Library", for: 3) } catch { say(error.localizedDescription) }
        }
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
