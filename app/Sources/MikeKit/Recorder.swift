import Accelerate
import AVFoundation
import FluidAudio
import Foundation

public enum RecorderError: LocalizedError {
    case cannotWrite(URL, String), micDenied, noMicrophone

    public var errorDescription: String? {
        switch self {
        case .cannotWrite(let url, let why): "Cannot write \(url.path): \(why)"
        case .micDenied: "Microphone access is off. Turn it on in System Settings > Privacy & Security > Microphone."
        case .noMicrophone: "No microphone is available."
        }
    }
}

extension SlidingWindowAsrManager {
    /// Both halves of the running text in one actor hop, so a window promoted in between is never read twice or missed.
    var fullText: String { [confirmedTranscript, volatileTranscript].filter { !$0.isEmpty }.joined(separator: " ") }
}

/// The model load as the user sees it: downloading with a fraction, then preparing (compiling for the Neural Engine).
/// FluidAudio reports each of its several per-model loads from 0 again (download 0-0.5, compile 0.5-1), and the
/// first one fetches the whole repo, so only that first download phase is a real percentage; any compile after it
/// is preparing, for good.
public struct ModelProgress: Sendable, Equatable {
    public var fraction: Double, preparing: Bool

    public init(fraction: Double = 0, preparing: Bool = false) { (self.fraction, self.preparing) = (fraction, preparing) }

    mutating func add(_ p: DownloadProgress) {
        switch p.phase {
        case .downloading(_, let files) where files > 0 && !preparing:  // no files: the cached fast path
            fraction = max(fraction, min(1, p.fractionCompleted * 2))  // ponytail: FluidAudio's repo loads weigh download 0.5
        case .compiling: preparing = true
        default: break
        }
    }
}

/// One live transcription: microphone (or a file played in real time) -> Parakeet Ultra on the Neural Engine ->
/// a per-minute transcript at `output`, rewritten as it grows. Audio never touches disk. Publishes the state file
/// (mode listen, this process's pid) for the notch while it runs. Used by the app and by the Listen CLI.
// ponytail: `level` and `paused` are shared with the audio thread unsynchronised; a torn read only misdraws the orb
public final class Recorder: @unchecked Sendable {
    public enum Source: Sendable { case microphone, file(URL) }

    @MainActor private static var loading: Task<AsrModels, Error>?
    @MainActor private static var listeners: [@MainActor (ModelProgress) -> Void] = []
    /// The shared load's progress while it runs; nil when none is running (done, failed or cancelled).
    @MainActor public private(set) static var modelProgress: ModelProgress?

    /// Parakeet Ultra: downloaded (~600 MB) and compiled on first use, then loaded from FluidAudio's cache. Callers
    /// share one load, so Settings' "Download now" and a recording never fetch it twice; a failed load can be retried.
    /// `progress` is called on the main actor, never goes backwards, and never after the load ended.
    @MainActor public static func models(progress: (@MainActor (ModelProgress) -> Void)? = nil) async throws -> AsrModels {
        if let progress { listeners.append(progress) }
        if loading == nil {
            modelProgress = ModelProgress()
            loading = Task {
                try await AsrModels.downloadAndLoad(version: .ultra) { p in
                    Task { @MainActor in
                        guard var m = Recorder.modelProgress else { return }  // a late callback after the load ended
                        m.add(p)
                        Recorder.modelProgress = m
                        Recorder.listeners.forEach { $0(m) }
                    }
                }
            }
        }
        let task = loading!
        do {
            let m = try await task.value
            if loading == task { modelProgress = nil; listeners.removeAll() }
            return m
        } catch {
            if loading == task { loading = nil; modelProgress = nil; listeners.removeAll() }  // not when cancelled: already reset
            throw task.isCancelled ? CancellationError() : error  // one error type for a cancel, whatever FluidAudio threw
        }
    }

    /// Stops a running download; its callers get a CancellationError. FluidAudio keeps the bytes in `.partial` files
    /// and resumes from them next time.
    @MainActor public static func cancelModels() {
        guard modelProgress != nil else { return }  // nothing running (a finished load stays cached in `loading`)
        loading?.cancel()
        loading = nil; modelProgress = nil; listeners.removeAll()
    }

    /// The model is already in FluidAudio's cache, so the next recording only loads it (seconds) instead of downloading.
    public static var modelsOnDisk: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .ultra), version: .ultra)
    }

    /// Free bytes (for important use) on the volume the model downloads to.
    public static var modelVolumeFree: Int64? {
        var dir = AsrModels.defaultCacheDirectory(for: .ultra)
        while !FileManager.default.fileExists(atPath: dir.path) && dir.path != "/" { dir.deleteLastPathComponent() }  // not there before the first download
        return try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    }

    public static var micDenied: Bool { [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio)) }

    public let output: URL
    public private(set) var paused = false
    /// Each decoded window's text, and the minute label when it opens a new paragraph. Called off the main thread.
    public var onText: ((_ text: String, _ newMinute: String?) -> Void)?
    /// Problems after start (a device switch the engine could not follow). Called off the main thread.
    public var onError: ((String) -> Void)?

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
        do {
            switch source {
            case .microphone: try startMicrophone()
            case .file(let url): fileTask = Task { [self] in play(url) }
            }
        } catch {
            _ = try? await stop()  // ends the ticker (state off), the pump and the display task, so nothing is left running
            throw error
        }
        Cue.start.play()
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
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noMicrophone }  // installTap would raise
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buf, _ in self?.take(buf) }
        try engine.start()
        // A new default input (AirPods connecting) stops the engine and changes the format: tap again and restart.
        // ponytail: audio missed during the switch shifts later minute stamps earlier by that gap (usually under a second)
        reconfig = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            engine.inputNode.removeTap(onBus: 0)
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buf, _ in self?.take(buf) }
            do {
                try engine.start()
                Log.recorder.info("input device changed, listening on the new one")
            } catch {
                Log.recorder.error("could not restart on the new input: \(error.localizedDescription, privacy: .public)")
                self?.onError?("The microphone changed and recording could not continue. Stop and start again.")
            }
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
