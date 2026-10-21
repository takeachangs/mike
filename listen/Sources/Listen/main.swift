// Listen: the /listen recorder. Transcribes the mic live with Parakeet Ultra (FluidAudio, on the Neural Engine) and keeps
// a TwinMind-style transcript, one paragraph per clock minute ("14:05 ..."), at the path given. Audio never touches disk.
// Drives the notch app the way bridge.py does: ~/.claude-call/state.json at 20 Hz, and CALL_BRIDGE_PID so its mute
// button (SIGUSR1) pauses listening and its hang-up button (SIGINT, same as Ctrl-C) stops it.
// usage: Listen <transcript.txt> [--file audio.wav]   (--file plays a recording in real time instead of the mic, for testing)
import Accelerate
import AVFoundation
import FluidAudio
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
var testFile: URL?
if let i = args.firstIndex(of: "--file"), i + 1 < args.count {
    testFile = URL(fileURLWithPath: args[i + 1])
    args.removeSubrange(i...(i + 1))
}
guard let outPath = args.first else {
    print("usage: Listen <transcript.txt> [--file audio.wav]")
    exit(2)
}
let out = URL(fileURLWithPath: outPath)
let stateDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude-call")
let stateURL = stateDir.appending(path: "state.json")
// ponytail: #filePath is where this file was compiled; fine for the local build this repo assumes
let notchApp = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../notch/.build/release/CallNotch").standardized
let sounds = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../sounds").standardized
let volume = ProcessInfo.processInfo.environment["CALL_SOUND_VOLUME"] ?? "0.25"  // afplay -v, as in bridge.py: quiet, 0 = off

/// Play sounds/<name>.wav without waiting; the same cue files and volume as the bridge. A missing file is skipped.
func cue(_ name: String) {
    let f = sounds.appending(path: "\(name).wav")
    guard (Double(volume) ?? 0) > 0, FileManager.default.fileExists(atPath: f.path) else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    p.arguments = ["-v", volume, f.path]
    try? p.run()
}

print("Loading Parakeet Ultra (first run downloads ~600 MB and compiles for the Neural Engine)…")
let models = try await AsrModels.downloadAndLoad(version: .ultra)
let live = SlidingWindowAsrManager(config: .streaming)
try await live.loadModels(models)

// Transcript: the manager keeps the running text (and fixes words at window seams); we only remember where in that
// text each clock minute starts.
let clock = DateFormatter()
clock.dateFormat = "HH:mm"
var blocks: [(minute: String, offset: Int)] = []

func fullText() async -> String {
    [await live.confirmedTranscript, await live.volatileTranscript].filter { !$0.isEmpty }.joined(separator: " ")
}

func render(_ full: String) -> String {
    blocks.indices.map { i in
        let end = i + 1 < blocks.count ? blocks[i + 1].offset : full.count
        let text = full.dropFirst(blocks[i].offset).prefix(max(0, end - blocks[i].offset))
        return blocks[i].minute + " " + text.trimmingCharacters(in: .whitespaces)
    }.joined(separator: "\n\n")
}

let start = Date()  // wall-clock time of the first audio sample; token timings are seconds of audio since then
let updates = await live.transcriptionUpdates
let display = Task {
    var lastCount = 0
    for await update in updates where !update.text.isEmpty {
        let full = await fullText()
        // ponytail: a window's text goes under the minute its first word was spoken, so a paragraph can run up to ~11 s past the minute
        if let t = update.tokenTimings.first?.startTime {
            let minute = clock.string(from: start.addingTimeInterval(t))
            if blocks.last?.minute != minute {
                blocks.append((minute, min(lastCount, full.count)))
                print("\n\(minute)")
            }
        }
        print(update.text)
        lastCount = full.count
        try? render(full).write(to: out, atomically: true, encoding: .utf8)  // rewritten as it grows: a crash keeps what was heard
    }
}
try await live.startStreaming()

// Notch: same state file and signals as a call. `level` and `muted` are written from the audio thread and the signal
// queue and read by the 20 Hz writer.
// ponytail: unsynchronised; a torn read only misdraws the orb for one frame
var level = 0.0, muted = false
let q = DispatchQueue(label: "listen")
func writeState(_ state: String) {
    let json = ["state": state, "level": (level * 1000).rounded() / 1000, "muted": muted] as [String: Any]
    try? JSONSerialization.data(withJSONObject: json).write(to: stateURL, options: .atomic)  // the app never reads half a file
}
try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
writeState("listening")
let ticker = DispatchSource.makeTimerSource(queue: q)
ticker.schedule(deadline: .now(), repeating: 0.05)
ticker.setEventHandler { writeState("listening") }  // every tick even when unchanged: a 3 s old file means a dead recorder
ticker.resume()
var notch: Process?
if FileManager.default.isExecutableFile(atPath: notchApp.path) {
    let p = Process()
    p.executableURL = notchApp
    p.environment = ProcessInfo.processInfo.environment.merging(["CALL_BRIDGE_PID": "\(getpid())", "CALL_NOTCH_MODE": "listen"]) { $1 }  // its buttons signal us; recorder look
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    notch = p
}
signal(SIGUSR1, SIG_IGN)
let pause = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: q)
pause.setEventHandler { muted.toggle(); cue(muted ? "pause" : "start"); print(muted ? "\npaused" : "\nlistening") }
pause.resume()

// One stream so buffers reach the model in order (a Task per buffer can reorder them).
let (audio, feed) = AsyncStream<AVAudioPCMBuffer>.makeStream()
let pump = Task { for await buf in audio { await live.streamAudio(buf) } }

/// Mic level for the orb, then hand the buffer on. Paused audio goes in as silence rather than being dropped,
/// so token timings keep matching the wall clock.
func take(_ buf: AVAudioPCMBuffer) {
    guard let ch = buf.floatChannelData else { return }
    var r: Float = 0
    vDSP_rmsqv(ch[0], 1, &r, vDSP_Length(buf.frameLength))
    level = min(1, Double(r) * 32768 / 6000)  // same scale as bridge.py's rms(): speech lands around 0.5-0.8
    if muted { for c in 0..<Int(buf.format.channelCount) { vDSP_vclr(ch[c], 1, vDSP_Length(buf.frameLength)) } }
    feed.yield(buf)
}

cue("start")
if let testFile {
    let file = try AVAudioFile(forReading: testFile)
    while file.framePosition < file.length {
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        try file.read(into: buf)
        take(buf)
        try await Task.sleep(for: .seconds(Double(buf.frameLength) / file.processingFormat.sampleRate))  // real time, like a mic
    }
} else {
    let engine = AVAudioEngine()
    engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buf, _ in take(buf) }
    try engine.start()
    print("listening started. Ctrl-C or the notch's hang-up button stops; its mute button pauses.")
    signal(SIGINT, SIG_IGN)
    let stop = DispatchSource.makeSignalSource(signal: SIGINT, queue: q)
    await withCheckedContinuation { c in
        stop.setEventHandler { stop.cancel(); c.resume() }
        stop.resume()
    }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
}

cue("stop")
ticker.cancel()
q.sync { level = 0; writeState("off") }
notch?.terminate()  // the app folds its tab on SIGTERM, then exits

feed.finish()
await pump.value
_ = try await live.finish()
await live.cancel()  // ends transcriptionUpdates so the display task drains the last window and exits
await display.value
let full = await fullText()
try render(full).write(to: out, atomically: true, encoding: .utf8)
print("\nsaved \(out.path) (\(full.split(separator: " ").count) words, \(Int(Date().timeIntervalSince(start) / 60)) min)")
