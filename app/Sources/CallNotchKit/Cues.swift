import Foundation

/// The five short cue sounds (rendered by app/scripts/make-sounds.py), played quietly with afplay so a cue started
/// just before a process exits still finishes. bridge.py plays the same files.
public enum Cue: String, CaseIterable, Sendable {
    case start, pause, stop, wait, ready

    public var url: URL? { Cue.resources.url(forResource: rawValue, withExtension: "wav", subdirectory: "sounds") }

    /// SwiftPM's Bundle.module only looks at the .app's top level (which code signing rejects) and the build folder,
    /// so look in Contents/Resources first, then next to the executable (a plain `swift build`), then Bundle.module.
    static let resources: Bundle = {
        let name = "CallNotch_CallNotchKit.bundle"
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        return [Bundle.main.resourceURL, exe].compactMap { $0?.appending(path: name) }.lazy.compactMap { Bundle(url: $0) }.first ?? .module
    }()

    /// The level from CALL_SOUND_VOLUME (afplay -v, default 0.25); anything unreadable or negative means off.
    public static func volume(_ raw: String?) -> Double {
        guard let raw else { return 0.25 }
        return max(0, Double(raw) ?? 0)
    }

    /// Settings override the environment; 0 turns cues off.
    nonisolated(unsafe) public static var level = volume(ProcessInfo.processInfo.environment["CALL_SOUND_VOLUME"])

    public func play() {
        guard Cue.level > 0, let url else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = ["-v", String(Cue.level), url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}
