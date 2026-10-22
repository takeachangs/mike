import Foundation

/// `~/.claude-call/state.json`: what the notch draws. Written atomically every 50 ms by whoever runs the session
/// (bridge.py, the Listen CLI, or the app's own call and recorder); a file older than 3 s means that writer died.
public struct SessionState: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case call, listen }
    public var state: String  // "listening" | "thinking" | "speaking" | "off"
    public var level: Double  // 0...1
    public var muted: Bool
    public var pid: Int32?
    public var mode: Mode?

    public init(state: String, level: Double, muted: Bool = false, pid: Int32? = nil, mode: Mode? = nil) {
        self.state = state; self.level = level; self.muted = muted; self.pid = pid; self.mode = mode
    }

    public var isLive: Bool { state != "off" }
}

public enum StateFile {
    public static let staleAfter: TimeInterval = 3

    /// Atomic replace, so a reader never sees half a file. Level is rounded to 3 places like bridge.py.
    public static func write(_ s: SessionState, to url: URL = Paths.stateFile) {
        var s = s
        s.level = (min(max(s.level.isFinite ? s.level : 0, 0), 1) * 1000).rounded() / 1000
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// The current state, or nil when the file is missing, unreadable, or not rewritten for `staleAfter` seconds.
    public static func read(from url: URL = Paths.stateFile, now: Date = Date()) -> SessionState? {
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              now.timeIntervalSince(mtime) < staleAfter, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }
}

/// Rewrites the state file every 50 ms from a background queue until stopped; the last write is always `off`.
public final class StateTicker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "callnotch.state")
    private var timer: DispatchSourceTimer?
    private let current: () -> SessionState

    public init(_ current: @escaping () -> SessionState) { self.current = current }

    public func start() {
        try? Paths.ensureStateDir()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 0.05)
        t.setEventHandler { [current] in StateFile.write(current()) }
        t.resume()
        timer = t
    }

    /// Cancels the ticker, then writes `off` on the same queue, so nothing can overwrite it afterwards.
    public func stop(mode: SessionState.Mode) {
        timer?.cancel()
        timer = nil
        queue.sync { StateFile.write(SessionState(state: "off", level: 0, pid: getpid(), mode: mode)) }
    }
}
