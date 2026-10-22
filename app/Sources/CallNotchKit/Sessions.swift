import Foundation

/// One saved call or recording in ~/.claude-call, for the Library.
public struct Session: Identifiable, Sendable {
    public enum Kind: Sendable { case call, recording }
    public let id: URL  // the transcript file
    public let kind: Kind, date: Date, minutes: Int?, title: String, body: String, notes: String?

    /// Calls are `transcript-<stamp>.json`, either a bare `[[role, text], ...]` (older bridge) or
    /// `{"seconds", "transcript"}`; recordings are `listen-<stamp>.txt` with `HH:MM text` paragraphs and, once a
    /// skill wrote them, notes in `listen-<stamp>.md`. Anything else is nil.
    public static func parse(_ url: URL) -> Session? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let dash = name.firstIndex(of: "-"), let date = Paths.stamp.date(from: String(name[name.index(after: dash)...])),
              let data = try? Data(contentsOf: url) else { return nil }
        if name.hasPrefix("transcript-"), url.pathExtension == "json" {
            let json = try? JSONSerialization.jsonObject(with: data)
            let turns = ((json as? [String: Any])?["transcript"] ?? json) as? [[String]] ?? []
            let seconds = (json as? [String: Any])?["seconds"] as? Double
            let lines = turns.filter { $0.count == 2 }.map { ($0[0] == "user" ? "You: " : "Voice: ") + $0[1].trimmingCharacters(in: .whitespaces) }
            let first = turns.first { $0.first == "user" }?.last?.trimmingCharacters(in: .whitespaces) ?? ""
            return Session(id: url, kind: .call, date: date, minutes: seconds.map { max(1, Int(($0 / 60).rounded())) },
                           title: first.isEmpty ? "Call" : first, body: lines.joined(separator: "\n\n"), notes: nil)
        }
        if name.hasPrefix("listen-"), url.pathExtension == "txt" {
            let body = String(decoding: data, as: UTF8.self)
            let notes = try? String(contentsOf: url.deletingPathExtension().appendingPathExtension("md"), encoding: .utf8)
            let heading = notes?.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) }
            return Session(id: url, kind: .recording, date: date, minutes: minutesSpanned(body), title: heading ?? "Recording",
                           body: body, notes: notes)
        }
        return nil
    }

    /// Minutes from the first to the last paragraph stamp ("11:08 ...", "12:52 ..."), across midnight too.
    static func minutesSpanned(_ body: String) -> Int? {
        let stamps = body.split(separator: "\n").compactMap { line -> Int? in
            let p = line.prefix(5).split(separator: ":")
            guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
            return h * 60 + m
        }
        guard let first = stamps.first, let last = stamps.last else { return nil }
        return (last - first + 1440) % 1440 + 1
    }

    /// Every session in `dir`, newest first.
    public static func load(from dir: URL = Paths.stateDir) -> [Session] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap(parse).sorted { $0.date > $1.date }
    }

    /// Moves the session's files (transcript and notes) to the Trash.
    public func trash() throws {
        try FileManager.default.trashItem(at: id, resultingItemURL: nil)
        let notes = id.deletingPathExtension().appendingPathExtension("md")
        if FileManager.default.fileExists(atPath: notes.path) { try FileManager.default.trashItem(at: notes, resultingItemURL: nil) }
    }
}
