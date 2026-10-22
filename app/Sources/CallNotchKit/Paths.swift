import Foundation
import os

/// Where everything lives. `~/.claude-call/` is shared with bridge.py and the agent-side skills, so it stays put.
public enum Paths {
    public static let stateDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude-call")
    public static let stateFile = stateDir.appending(path: "state.json")
    public static let appPID = stateDir.appending(path: "app.pid")

    /// `yyyyMMdd'T'HHmm`, the stamp in transcript and recording file names.
    public static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmm"
        return f
    }()

    public static func newRecording(at date: Date = Date()) -> URL { stateDir.appending(path: "listen-\(stamp.string(from: date)).txt") }
    public static func newCallTranscript(at date: Date = Date()) -> URL { stateDir.appending(path: "transcript-\(stamp.string(from: date)).json") }

    public static func ensureStateDir() throws { try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true) }
}

public enum Log {
    public static let app = Logger(subsystem: "com.takeachangs.callnotch", category: "app")
    public static let recorder = Logger(subsystem: "com.takeachangs.callnotch", category: "recorder")
    public static let call = Logger(subsystem: "com.takeachangs.callnotch", category: "call")
}
