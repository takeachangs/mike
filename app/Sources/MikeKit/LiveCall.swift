import AVFoundation
import Foundation
import os

public struct LiveCallError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// One solo GPT-Live call on the default mic and speaker: bridge.py's `solo` mode without Python. No delegation.
/// Socket events, ending and the transcript run on `q`; the levels the notch draws sit in `meter`, which the audio
/// threads and the state ticker touch.
public final class LiveCall: @unchecked Sendable {
    /// bridge.py's SOLO_INSTRUCTIONS, verbatim.
    public static let soloInstructions = "You are a friendly, concise voice assistant on the user's Mac. Answer from your own knowledge in short spoken "
        + "sentences. You have no tools, no internet and no access to the user's files, so say so plainly when asked for "
        + "something current or personal. When the user says goodbye, say goodbye and end with exactly: Hanging up now."
    static let signOff = "Hanging up now"  // hearing it in the output transcript ends the call
    static let closeWait: TimeInterval = 5, startWait: TimeInterval = 15, silenceWarning: TimeInterval = 10
    static let chunkBytes = LiveProtocol.rate / 10 * 2  // 100 ms of PCM16

    /// Hang up after this long with neither side speaking (0 = never). "Speaking" means the server transcribed your
    /// words, or the voice's audio is playing: noise, typing and a fan never count, unlike a mic loudness threshold.
    /// The `wait` cue plays `silenceWarning` seconds before; a muted call never hangs up on silence.
    public var hangUpAfterSilence: TimeInterval = 30
    public var onEnd: ((URL?) -> Void)?
    public var onError: ((String) -> Void)?
    public var muted: Bool { meter.withLock { $0.muted } }

    struct Meter {
        var mic = 0.0, spkAt = 0.0, activeAt = 0.0
        /// Output slices scheduled and not yet finished, by the time each one ends. Playback is tracked by the clock,
        /// not by AVAudioPlayerNode's completion callbacks, which can stop arriving and left a call "speaking" forever.
        var slices: [(end: TimeInterval, level: Double)] = []
        var playEnd = 0.0

        /// Drops finished slices; a finished slice with voice in it moves `spkAt`. Silent slices never count as speech.
        mutating func advance(_ now: TimeInterval) {
            while let first = slices.first, first.end <= now {
                if first.level > Meter.voiced { spkAt = max(spkAt, first.end) }
                slices.removeFirst()
            }
        }
        var voiceAhead: Bool { slices.contains { $0.level > Meter.voiced } }
        func speaking(_ now: TimeInterval) -> Bool { voiceAhead || now - spkAt < 0.3 }
        static let voiced = 0.02  // rms on bridge.py's scale (speech ~0.5): anything quieter is silence or padding
        var muted = false, sending = false
    }

    private enum Phase { case idle, connecting, live, closing, done }

    private let model: String, instructions: String
    private let task: URLSessionWebSocketTask?
    private let q = DispatchQueue(label: "mike.call")
    private let meter = OSAllocatedUnfairLock(initialState: Meter())
    private let ticker: StateTicker
    private let mic = AVAudioEngine(), out = AVAudioEngine(), player = AVAudioPlayerNode()
    private var micPending = Data()  // tap thread only
    private var audioOn = false
    private var observers: [NSObjectProtocol] = []
    // on q
    private var phase = Phase.idle
    private var lastPing = LiveCall.now
    private var waiter: CheckedContinuation<Void, Error>?
    private var transcript: [[String]] = []
    private var seconds: Double?, reason: String?, signedOff = false, warned = false

    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    public init(apiKey: String, instructions: String, model: String = "gpt-live-1") {
        self.model = model
        self.instructions = instructions
        task = URL(string: LiveProtocol.endpoint).map { url in
            var req = URLRequest(url: url)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            return URLSession.shared.webSocketTask(with: req)
        }
        ticker = StateTicker { [meter] in
            let now = LiveCall.now
            let m = meter.withLock { m in m.advance(now); return m }
            let speaking = m.speaking(now)
            return SessionState(state: speaking ? "speaking" : "listening", level: speaking ? m.slices.first?.level ?? 0 : m.mic,
                                muted: m.muted, pid: getpid(), mode: .call)
        }
    }

    /// Opens the mic and speaker, then the session; returns once session.started arrived.
    public func start() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw LiveCallError(message: "Microphone access is off: System Settings > Privacy & Security > Microphone")
        }
        do {
            try startAudio()
            try await connect()
        } catch {
            teardownAudio()
            throw error
        }
    }

    public func hangUp() { q.async { self.close("hung up") } }

    public func toggleMute() {
        q.async { [self] in
            guard phase == .live else { return }
            let m = meter.withLock { $0.muted.toggle(); return $0.muted }
            send(LiveProtocol.mute(m))
            (m ? Cue.pause : Cue.start).play()
            Log.call.info("\(m ? "mic muted" : "mic live", privacy: .public)")
        }
    }

    // MARK: session

    /// Socket, session.start, and the wait for session.started (or an error, a refused handshake, the timeout).
    func connect() async throws {
        guard let task else { throw LiveCallError(message: "bad endpoint URL") }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            q.async { [self] in
                guard phase == .idle else { c.resume(throwing: LiveCallError(message: "Hung up before the call started")); return }
                phase = .connecting
                waiter = c
                task.resume()
                send(LiveProtocol.sessionStart(model: model, instructions: instructions))
                receive()
                q.asyncAfter(deadline: .now() + LiveCall.startWait) { [self] in failStart("No answer from OpenAI within \(Int(LiveCall.startWait)) s") }
            }
        }
    }

    private func receive() {
        task?.receive { [self] result in
            q.async { [self] in
                switch result {
                case .success(.string(let s)): handle(LiveProtocol.decode(Data(s.utf8))); receive()
                case .success(.data(let d)): handle(LiveProtocol.decode(d)); receive()
                case .success: receive()
                case .failure(let error): socketFailed(error)
                }
            }
        }
    }

    private func handle(_ event: LiveProtocol.ServerEvent) {
        switch event {
        case .started:
            guard phase == .connecting, let c = waiter else { return }
            phase = .live
            waiter = nil
            meter.withLock { $0.activeAt = LiveCall.now; $0.sending = true }
            ticker.start()
            Cue.start.play()
            Log.call.info("call started")
            watch()
            c.resume()
        case .audio(let pcm): play(pcm)
        case .inputTranscript(let d):
            add("user", d)
            meter.withLock { $0.activeAt = LiveCall.now }  // the server heard words: real speech, not noise
        case .outputTranscript(let d):
            add("assistant", d)
            if !signedOff, transcript.last?[1].contains(LiveCall.signOff) == true {
                signedOff = true  // watch() closes once the goodbye has played
                Log.call.info("sign-off heard")
            }
        case .usage(let s): seconds = s
        case .error(let message):
            Log.call.error("error: \(message, privacy: .public)")
            if phase == .connecting { failStart("OpenAI: \(message)") } else { report(message) }
        case .closed(let s, let r):
            seconds = s ?? seconds
            reason = r
            if phase == .connecting { failStart("OpenAI closed the session: \(r ?? "no reason")") } else { finish() }
        case .other: break
        }
    }

    private func socketFailed(_ error: Error) {
        switch phase {
        case .connecting:
            let status = (task?.response as? HTTPURLResponse)?.statusCode
            if status == 401 || status == 403 { failStart("OpenAI refused the API key (HTTP \(status ?? 0))") }
            else { failStart("Could not reach OpenAI\(status.map { " (HTTP \($0))" } ?? ""): \(error.localizedDescription)") }
        case .live:
            report("Connection lost: \(error.localizedDescription)")
            reason = "connection lost"
            finish()
        case .closing:
            reason = reason ?? "socket closed before session.closed"
            finish()
        case .idle, .done: break
        }
    }

    private func failStart(_ message: String) {
        guard phase == .connecting, let c = waiter else { return }
        phase = .done
        waiter = nil
        task?.cancel(with: .goingAway, reason: nil)
        Log.call.error("start failed: \(message, privacy: .public)")
        c.resume(throwing: LiveCallError(message: message))
    }

    /// What the silence guard does after `quiet` seconds with no speech either way: warn once, then hang up.
    static func silence(quiet: TimeInterval, limit: TimeInterval, warned: Bool) -> (warn: Bool, hangUp: Bool) {
        guard limit > 0 else { return (false, false) }
        return (!warned && quiet >= max(0, limit - silenceWarning) && quiet < limit, quiet >= limit)
    }

    /// Every 100 ms while live: close once the sign-off has played out, or after `hangUpAfterSilence` of silence.
    private func watch() {
        q.asyncAfter(deadline: .now() + 0.1) { [self] in
            guard phase == .live else { return }
            let now = LiveCall.now
            let m = meter.withLock { m in
                m.advance(now)
                if m.muted { m.activeAt = now }  // muting is a deliberate pause: it never counts as silence
                return m
            }
            if now - lastPing > 15 {  // URLSessionWebSocketTask has no keepalive: a silently dropped socket shows up here
                lastPing = now
                task?.sendPing { [self] error in if let error { q.async { self.socketFailed(error) } } }
            }
            let quiet = now - max(m.activeAt, m.spkAt, m.voiceAhead ? now : 0)
            let s = LiveCall.silence(quiet: quiet, limit: hangUpAfterSilence, warned: warned)
            if quiet < max(0, hangUpAfterSilence - LiveCall.silenceWarning) { warned = false }  // talking again re-arms it
            if s.warn { warned = true; Cue.wait.play() }
            if signedOff, !m.voiceAhead, now - m.spkAt > 0.8 { close("sign-off played") }  // the goodbye has played out
            else if s.hangUp { close("silent for \(Int(hangUpAfterSilence)) s") }
            else { watch() }
        }
    }

    /// session.close, then up to `closeWait` for session.closed and its final usage.
    private func close(_ why: String) {
        if phase == .idle { phase = .done; return }  // hung up while the audio was still starting: connect() will refuse
        if phase == .connecting { failStart("Hung up before the call started"); return }
        guard phase == .live else { return }
        phase = .closing
        meter.withLock { $0.sending = false }
        Log.call.info("closing: \(why, privacy: .public)")
        send(LiveProtocol.close)
        q.asyncAfter(deadline: .now() + LiveCall.closeWait) { [self] in
            if phase == .closing { reason = reason ?? "no session.closed within \(Int(LiveCall.closeWait)) s"; finish() }
        }
    }

    private func finish() {
        guard phase == .live || phase == .closing else { return }
        phase = .done
        teardownAudio()
        task?.cancel(with: .normalClosure, reason: nil)
        ticker.stop(mode: .call)
        Cue.stop.play()
        Log.call.info("closed: \(self.reason ?? "?", privacy: .public), \(self.seconds.map { "\($0)" } ?? "null", privacy: .public) s billed")
        let url = save()
        DispatchQueue.main.async { self.onEnd?(url) }
    }

    /// `{"seconds": <Double or null>, "transcript": [[role, text], ...]}`, like bridge.py's write_closed (no inbox line).
    private func save() -> URL? {
        let url = Paths.newCallTranscript()
        do {
            try Paths.ensureStateDir()
            let body: [String: Any] = ["seconds": seconds ?? NSNull(), "transcript": transcript]
            try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            return url
        } catch {
            Log.call.error("transcript not saved: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Consecutive deltas of one role make one turn; the last 40 turns are kept, as in bridge.py's add().
    private func add(_ role: String, _ delta: String) {
        if transcript.last?.first == role { transcript[transcript.count - 1][1] += delta } else {
            transcript.append([role, delta])
            if transcript.count > 40 { transcript.removeFirst(transcript.count - 40) }
        }
    }

    private func send(_ text: String) {
        task?.send(.string(text)) { error in
            if let error { Log.call.error("send failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { self.onError?(message) }
    }

    // MARK: audio

    private func startAudio() throws {
        audioOn = true
        guard let float = AVAudioFormat(standardFormatWithSampleRate: Double(LiveProtocol.rate), channels: 1) else {
            throw LiveCallError(message: "no 24 kHz audio format")
        }
        out.attach(player)
        out.connect(player, to: out.mainMixerNode, format: float)
        try out.start()
        player.play()
        try startMic()
        // A new default device (AirPods connecting) stops an engine: start it again on the new one.
        observers = [mic, out].map { engine in
            NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [self] _ in
                q.async { self.restart(engine) }
            }
        }
    }

    private func startMic() throws {
        let input = mic.inputNode, format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(LiveProtocol.rate), channels: 1, interleaved: true),
              let conv = AVAudioConverter(from: format, to: pcm) else { throw LiveCallError(message: "No usable microphone") }
        conv.downmix = true
        input.removeTap(onBus: 0)
        micPending = Data()
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format) { [self] buf, _ in take(buf, conv) }
        mic.prepare()
        try mic.start()
    }

    /// Tap thread: resample to 24 kHz mono PCM16, then level, idle clock and input_audio.append per 100 ms.
    private func take(_ buf: AVAudioPCMBuffer, _ conv: AVAudioConverter) {
        let cap = AVAudioFrameCount(Double(buf.frameLength) * conv.outputFormat.sampleRate / buf.format.sampleRate) + 32
        guard let pcm = AVAudioPCMBuffer(pcmFormat: conv.outputFormat, frameCapacity: cap) else { return }
        var fed = false, error: NSError?
        conv.convert(to: pcm, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }  // not .endOfStream: that would end the converter for good
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard error == nil, let ch = pcm.int16ChannelData else { return }
        micPending.append(UnsafeBufferPointer(start: ch[0], count: Int(pcm.frameLength)))
        while micPending.count >= LiveCall.chunkBytes {
            let chunk = Data(micPending.prefix(LiveCall.chunkBytes))
            micPending.removeFirst(LiveCall.chunkBytes)
            let level = LiveProtocol.rms(chunk)
            let sending = meter.withLock { m in
                m.mic = level
                return m.sending
            }
            if sending { send(LiveProtocol.appendAudio(chunk)) }
        }
    }

    /// Schedules output audio in 100 ms slices, noting when each will have played (see Meter.slices).
    // ponytail: audio already queued keeps playing after the user interrupts, as in bridge.py; stop the player on input_transcript if it bothers
    private func play(_ pcm: Data) {
        let format = player.outputFormat(forBus: 0), samples = pcm.count / 2
        for start in stride(from: 0, to: samples, by: LiveProtocol.rate / 10) {
            let n = min(LiveProtocol.rate / 10, samples - start)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)), let ch = buf.floatChannelData else { return }
            buf.frameLength = AVAudioFrameCount(n)
            pcm.withUnsafeBytes { raw in
                for i in 0..<n { ch[0][i] = Float(raw.loadUnaligned(fromByteOffset: (start + i) * 2, as: Int16.self)) / 32768 }
            }
            let level = LiveProtocol.rms(pcm.subdata(in: start * 2 ..< (start + n) * 2))
            let now = LiveCall.now
            meter.withLock { m in  // slices play back to back: this one ends a slice-length after the last, or after now
                m.playEnd = max(m.playEnd, now) + Double(n) / Double(LiveProtocol.rate)
                m.slices.append((m.playEnd, level))
            }
            player.scheduleBuffer(buf)
        }
    }

    private func restart(_ engine: AVAudioEngine) {
        guard phase == .live || phase == .closing else { return }
        do {
            if engine === mic {
                mic.stop()
                try startMic()
            } else {
                player.stop()  // drops what was scheduled, so forget those slices
                meter.withLock { $0.slices.removeAll(); $0.playEnd = 0 }
                try out.start()
                player.play()
            }
            Log.call.info("audio device changed, restarted")
        } catch {
            report("Audio device change failed: \(error.localizedDescription)")
            close("audio device lost")
        }
    }

    private func teardownAudio() {
        guard audioOn else { return }
        audioOn = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        mic.inputNode.removeTap(onBus: 0)
        mic.stop()
        player.stop()
        out.stop()
    }
}
