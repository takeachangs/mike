import Foundation
import Testing
@testable import CallNotchKit

@Suite struct StateFileTests {
    let url = FileManager.default.temporaryDirectory.appending(path: "callnotch-state-\(UUID().uuidString).json")

    @Test func roundTripsAndRoundsLevel() {
        StateFile.write(SessionState(state: "listening", level: 0.12345, muted: true, pid: 42, mode: .listen), to: url)
        #expect(StateFile.read(from: url) == SessionState(state: "listening", level: 0.123, muted: true, pid: 42, mode: .listen))
    }

    @Test func clampsBadLevels() {
        StateFile.write(SessionState(state: "speaking", level: .nan), to: url)
        #expect(StateFile.read(from: url)?.level == 0)
        StateFile.write(SessionState(state: "speaking", level: 7), to: url)
        #expect(StateFile.read(from: url)?.level == 1)
    }

    @Test func readsBridgeFilesWithoutPidOrMode() throws {
        try #"{"state": "thinking", "level": 0.0, "muted": false}"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(StateFile.read(from: url) == SessionState(state: "thinking", level: 0))
    }

    @Test func staleFileReadsAsMissing() {
        StateFile.write(SessionState(state: "listening", level: 0), to: url)
        #expect(StateFile.read(from: url, now: Date().addingTimeInterval(4)) == nil)
    }

    @Test func cueVolumeParsing() {
        #expect(Cue.volume(nil) == 0.25)
        #expect(Cue.volume("0.5") == 0.5)
        #expect(Cue.volume("off") == 0 && Cue.volume("") == 0 && Cue.volume("-1") == 0)
        #expect(Cue.allCases.allSatisfy { $0.url != nil })
    }
}
