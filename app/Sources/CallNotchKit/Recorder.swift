import Accelerate
import AVFoundation
import FluidAudio
import Foundation

public enum RecorderError: LocalizedError {
    case cannotWrite(URL, String), micDenied

    public var errorDescription: String? {
        switch self {
        case .cannotWrite(let url, let why): "Cannot write \(url.path): \(why)"
        case .micDenied: "Microphone access is off. Turn it on in System Settings > Privacy & Security > Microphone."
        }
    }
}

extension SlidingWindowAsrManager {
    /// Both halves of the running text in one actor hop, so a window promoted in between is never read twice or missed.
    var fullText: String { [confirmedTranscript, volatileTranscript].filter { !$0.isEmpty }.joined(separator: " ") }
}

/// One live transcription: microphone (or a file played in real time) -> Parakeet Ultra on the Neural Engine ->
/// a per-minute transcript at `output`, rewritten as it grows. Audio never touches disk. Publishes the state file
/// (mode listen, this process's pid) for the notch while it runs. Used by the app and by the Listen CLI.
// ponytail: `level` and `paused` are shared with the audio thread unsynchronised; a torn read only misdraws the orb
public final class Recorder: @unchecked Sendable {
    public enum Source: Sendable { case microphone, file(URL) }

    nonisolated(unsafe) private static var cached: AsrModels?

    /// Parakeet Ultra: downloaded (~600 MB) and compiled on first use, then loaded from FluidAudio's cache.
    public static func models(progress: ProgressHandler? = nil) async throws -> AsrModels {
        if let cached { return cached }
        let m = try await AsrModels.downloadAndLoad(version: .ultra, progressHandler: progress)
        cached = m
        return m
    }

    public static var micDenied: Bool { [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio)) }

    public let output: URL
    public private(set) var paused = false
    /// Each decoded window's text, and the minute label when it opens a new paragraph. Called off the main thread.
    public var onText: ((_ text: String, _ newMinute: String?) -> Void)?

    private var level = 0.0, stopped = false
    private let live = SlidingWindowAsrManager(config: .streaming)
    private var builder = TranscriptBuilder(start: Date())
    private var ticker: StateTicker?
    private var feed: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var pump, display, fileTask: Task<Void, Never>?
    private var engine: AVAudioEngine?, reconfig: NSObjectProtocol?

    /// Fails at once on an unwritable path, rather than after the lecture.
    public init(output: URL) throws {
        do { try "".write(to: output, atomically: true, encoding: .utf8) } catch {
            throw RecorderError.cannotWrite(output, error.localizedDescription)
        }
        self.output = output
    }

    public func start(_ source: Source, models: AsrModels) async throws {
        if case .microphone = source, Recorder.micDenied { throw RecorderError.micDenied }
        try await live.loadModels(models)
        let updates = await live.transcriptionUpdates
        try await live.startStreaming()
        builder = TranscriptBuilder(start: Date())
        display = Task { [self] in
            for await u in updates where !u.text.isEmpty {
                let full = await live.fullText
                let minute = builder.add(full: full, startTime: u.tokenTimings.first?.startTime)
                onText?(u.text, minute)
                try? builder.render(full).write(to: output, atomically: true, encoding: .utf8)  // a crash keeps what was heard
            }
        }
        let ticker = StateTicker { [unowned self] in
            SessionState(state: "listening", level: level, muted: paused, pid: getpid(), mode: .listen)
        }
        ticker.start()
        self.ticker = ticker
        let (audio, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        feed = cont
        pump = Task { [live] in for await b in audio { await live.streamAudio(b) } }  // one stream keeps buffers in order
        Cue.start.play()
        switch source {
        case .microphone: try startMicrophone()
        case .file(let url): fileTask = Task { [self] in play(url) }
        }
        Log.recorder.info("recording to \(self.output.path, privacy: .public)")
    }

    /// Paused audio is fed as silence rather than dropped, so the minute stamps stay on the clock.
    public func togglePause() {
        paused.toggle()
        (paused ? Cue.pause : Cue.start).play()
    }

    /// For a file source: returns once the whole file has been played in.
    public func waitForFile() async { await fileTask?.value }

    /// Stops listening, flushes the last window and writes the final transcript. Returns its word count. Safe to call twice.
    @discardableResult public func stop() async throws -> Int {
        guard !stopped else { return 0 }
        stopped = true
        if let engine {
            if let reconfig { NotificationCenter.default.removeObserver(reconfig) }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        fileTask?.cancel()
        Cue.stop.play()
        ticker?.stop(mode: .listen)
        feed?.finish()
        await pump?.value
        _ = try await live.finish()
        await live.cancel()  // ends transcriptionUpdates so the display task drains the last window and exits
        await display?.value
        let full = await live.fullText
        try builder.render(full).write(to: output, atomically: true, encoding: .utf8)
        Log.recorder.info("saved \(self.output.path, privacy: .public)")
        return full.split(separator: " ").count
    }

    private func take(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData else { return }
        var r: Float = 0
        vDSP_rmsqv(ch[0], 1, &r, vDSP_Length(buf.frameLength))
        level = min(1, Double(r) * 32768 / 6000)  // same scale as bridge.py's rms(): speech lands around 0.5-0.8
        if paused { for c in 0..<Int(buf.format.channelCount) { vDSP_vclr(ch[c], 1, vDSP_Length(buf.frameLength)) } }
        feed?.yield(buf)
    }

    private func startMicrophone() throws {
        let engine = AVAudioEngine()
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buf, _ in self?.take(buf) }
        try engine.start()
        // A new default input (AirPods connecting) stops the engine and changes the format: tap again and restart.
        // ponytail: audio missed during the switch shifts later minute stamps earlier by that gap (usually under a second)
        reconfig = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            engine.inputNode.removeTap(onBus: 0)
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buf, _ in self?.take(buf) }
            try? engine.start()
            Log.recorder.info("input device changed, listening on the new one")
        }
        self.engine = engine
    }

    /// Plays a file in at real time, like a microphone. Stops at its end or when cancelled.
    private func play(_ url: URL) {
        guard let file = try? AVAudioFile(forReading: url) else { Log.recorder.error("cannot read \(url.path, privacy: .public)"); return }
        let rate = file.processingFormat.sampleRate
        while !Task.isCancelled, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) {
            guard (try? file.read(into: buf)) != nil, buf.frameLength > 0 else { break }  // compressed files overstate their length
            take(buf)
            Thread.sleep(forTimeInterval: Double(buf.frameLength) / rate)
        }
    }
}
