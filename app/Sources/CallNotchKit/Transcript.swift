import Foundation

/// Turns the recognizer's running text into a TwinMind-style transcript: one paragraph per clock minute ("14:05 ...").
/// The recognizer owns the text (and fixes words at window seams); this only remembers where each minute starts in it.
public struct TranscriptBuilder {
    public let start: Date  // wall-clock time of the first audio sample; token timings are seconds of audio since then
    public private(set) var blocks: [(minute: String, offset: Int)] = []
    private var lastCount = 0
    private let clock: DateFormatter

    public init(start: Date, timeZone: TimeZone = .current) {
        self.start = start
        clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        clock.timeZone = timeZone
    }

    /// Record one decoded window. `full` is the whole running text after it, `startTime` its first word's time in
    /// seconds of audio. Returns the minute label when this window opens a new paragraph.
    // ponytail: a window's text goes under the minute its first word was spoken, so a paragraph can run ~11 s past it
    public mutating func add(full: String, startTime: TimeInterval?) -> String? {
        defer { lastCount = full.count }
        guard let startTime else { return nil }
        let minute = clock.string(from: start.addingTimeInterval(startTime))
        guard blocks.last?.minute != minute else { return nil }
        // the first block takes everything from the start; later ones never point before the previous one
        blocks.append((minute, blocks.last.map { max($0.offset, min(lastCount, full.count)) } ?? 0))
        return minute
    }

    public func render(_ full: String) -> String {
        blocks.indices.map { i in
            let end = i + 1 < blocks.count ? blocks[i + 1].offset : full.count
            let text = full.dropFirst(blocks[i].offset).prefix(max(0, end - blocks[i].offset))
            return blocks[i].minute + " " + text.trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n\n")
    }
}
