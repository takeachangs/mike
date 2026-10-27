import Accelerate
import AVFoundation
import FluidAudio
import Foundation

/// The right ⌘ key alone as a dictation key, like Spokenly. Pure: the app feeds it the key's presses and releases
/// (with the time) and every other key-down, and does what it returns. Capture starts on the press so holding loses
/// nothing; the release decides.
///
///     idle         right ⌘ down -> held, start
///     held         right ⌘ up within tapLimit -> latched (click mode, keeps dictating); later -> idle, finish
///                  any key -> idle, cancel (it was a shortcut such as ⌘C, not dictation)
///     latched      right ⌘ down -> again; Esc -> idle, cancel; other keys pass through
///     again        right ⌘ up -> idle, finish; Esc -> idle, cancel; any other key -> latched (a shortcut, keep dictating)
public struct DictationKey: Sendable {
    public enum Action: Equatable, Sendable { case start, finish, cancel }
    enum Phase: Equatable { case idle, held(since: TimeInterval), latched, again }

    /// A press shorter than this is a tap, which latches dictation on until the next tap.
    public static let tapLimit: TimeInterval = 0.3

    var phase = Phase.idle
    public init() {}

    /// Click mode: Esc now cancels, and is kept from the front app.
    public var latched: Bool { phase == .latched || phase == .again }

    public mutating func rightCommand(down: Bool, at t: TimeInterval) -> Action? {
        switch (phase, down) {
        case (.idle, true): phase = .held(since: t); return .start
        case (.held(let since), false):
            if t - since < Self.tapLimit { phase = .latched; return nil }
            phase = .idle; return .finish
        case (.latched, true): phase = .again; return nil
        case (.again, false): phase = .idle; return .finish
        default: return nil
        }
    }

    /// Any other key going down.
    public mutating func key(escape: Bool) -> Action? {
        switch phase {
        case .idle: return nil
        case .held: phase = .idle; return .cancel
        case .latched, .again:
            if escape { phase = .idle; return .cancel }
            phase = .latched
            return nil
        }
    }
}

/// One dictation: the microphone into memory from `start()` to `finish()`, then Parakeet Ultra over the whole clip in
/// one pass. Nothing streams and audio never touches disk. The model stays loaded between dictations.
// ponytail: `level` and `samples` are shared with the audio thread unsynchronised; samples are read only once the
// engine has stopped, and a torn level only misdraws the aura. A new input device mid-dictation ends the capture there.
public final class Dictation: @unchecked Sendable {
    @MainActor private static var asr: AsrManager?

    /// Loads Parakeet Ultra once (downloading it the first time, shared with recordings) and keeps it loaded.
    @MainActor @discardableResult public static func warm() async throws -> AsrManager {
        if let asr { return asr }
        let m = AsrManager()
        try await m.loadModels(Recorder.models())
        if let asr { return asr }  // another warm finished first
        asr = m
        return m
    }

    /// The mic's loudness, 0...1, on the recorder's scale.
    public private(set) var level = 0.0
    private var samples: [Float] = [], rate = 0.0
    private let engine = AVAudioEngine()

    public init() {}

    public func start() throws {
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noMicrophone }  // installTap would raise
        rate = format.sampleRate
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in self?.take(buf) }
        try engine.start()
    }

    /// Stops the microphone; the audio is dropped.
    public func cancel() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Stops the microphone and returns what was said, trimmed; empty when nothing was.
    @MainActor public func finish() async throws -> String {
        cancel()
        guard !samples.isEmpty else { return "" }
        var audio = try AudioConverter().resample(samples, from: rate)
        if audio.count < 16_000 { audio += [Float](repeating: 0, count: 16_000 - audio.count) }  // the model wants at least 0.3 s
        let asr = try await Self.warm()
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        return try await asr.transcribe(audio, decoderState: &state).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func take(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData else { return }
        var r: Float = 0
        vDSP_rmsqv(ch[0], 1, &r, vDSP_Length(buf.frameLength))
        level = min(1, Double(r) * 32768 / 6000)
        samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
    }
}
