// Listen: the /listen recorder as a command, for the agent-side skill. Transcribes the mic into a per-minute transcript
// at the path given (see Recorder in CallNotchKit). Ctrl-C (SIGINT) stops; SIGUSR1 pauses and resumes. Shows the
// recording in the notch: a resident CallNotch app picks it up from the state file, otherwise this launches the
// CallNotch executable next to it for the length of the recording, the way bridge.py does for a call.
// usage: Listen <transcript.txt> [--file audio.wav]   (--file plays a recording in real time instead of the mic, for testing)
//        Listen --cue start|pause|stop|wait|ready     (plays one cue sound at the CALL_SOUND_VOLUME level and exits)
import CallNotchKit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)  // line-buffered even when piped, so "listening started" shows up at once
var args = Array(CommandLine.arguments.dropFirst())
if args.count == 2, args[0] == "--cue" {  // `Listen --cue ready`: the skill's "notes are written" sound, from inside the app
    guard let cue = Cue(rawValue: args[1]) else { print("cues: \(Cue.allCases.map(\.rawValue).joined(separator: ", "))"); exit(2) }
    cue.play()
    exit(0)
}
var testFile: URL?
if let i = args.firstIndex(of: "--file"), i + 1 < args.count {
    testFile = URL(fileURLWithPath: args[i + 1])
    args.removeSubrange(i...(i + 1))
}
guard let outPath = args.first else {
    print("usage: Listen <transcript.txt> [--file audio.wav]")
    exit(2)
}

let recorder: Recorder
do {
    try Paths.ensureStateDir()
    recorder = try Recorder(output: URL(fileURLWithPath: outPath))
    if testFile == nil, Recorder.micDenied { throw RecorderError.micDenied }
} catch {
    print(error.localizedDescription)
    exit(2)
}

print("Loading Parakeet Ultra (first run downloads ~600 MB and compiles for the Neural Engine)…")
let models = try await Recorder.models()
recorder.onText = { text, minute in
    if let minute { print("\n\(minute)") }
    print(text)
}
try await recorder.start(testFile.map { .file($0) } ?? .microphone, models: models)

var notch: Process?
let resident = (try? String(contentsOf: Paths.appPID, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
let notchApp = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    .deletingLastPathComponent().appending(path: "CallNotch")
if resident.map({ kill($0, 0) == 0 }) != true, FileManager.default.isExecutableFile(atPath: notchApp.path) {
    let p = Process()
    p.executableURL = notchApp
    p.environment = ProcessInfo.processInfo.environment.merging(["CALL_BRIDGE_PID": "\(getpid())", "CALL_NOTCH_MODE": "listen"]) { $1 }
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    notch = p
}

let q = DispatchQueue(label: "listen.signals")
signal(SIGUSR1, SIG_IGN)
let pause = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: q)
pause.setEventHandler { recorder.togglePause(); print(recorder.paused ? "\npaused" : "\nlistening") }
pause.resume()

if testFile != nil {
    await recorder.waitForFile()
} else {
    print("listening started. Ctrl-C or the notch's stop button stops; its pause button pauses.")
    signal(SIGINT, SIG_IGN)
    let stop = DispatchSource.makeSignalSource(signal: SIGINT, queue: q)
    await withCheckedContinuation { c in
        stop.setEventHandler { stop.cancel(); c.resume() }
        stop.resume()
    }
}

notch?.terminate()  // the app folds its tab on SIGTERM, then exits
let words = try await recorder.stop()
print("\nsaved \(recorder.output.path) (\(words) words)")
