import Foundation
import Testing
@testable import MikeKit

@Suite struct SessionTests {
    let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appending(path: "mike-sessions-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    func write(_ name: String, _ text: String) -> URL {
        let u = dir.appending(path: name)
        try! text.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    @Test func olderBareListCall() throws {
        let s = try #require(Session.parse(write("transcript-20261009T1244.json", #"[["user", " Hello"], ["assistant", " Hey!"]]"#)))
        #expect(s.kind == .call && s.title == "Hello" && s.minutes == nil && s.body == "You: Hello\n\nVoice: Hey!")
    }

    @Test func callWithSeconds() throws {
        let s = try #require(Session.parse(write("transcript-20261017T1628.json", #"{"seconds": 277.0, "transcript": [["user", " Hi"]]}"#)))
        #expect(s.minutes == 5 && s.title == "Hi")
    }

    @Test func callWithNoUserTurnIsTitledCall() throws {
        let s = try #require(Session.parse(write("transcript-20261017T1629.json", #"{"seconds": null, "transcript": []}"#)))
        #expect(s.title == "Call" && s.minutes == nil)
    }

    @Test func recordingWithNotes() throws {
        _ = write("listen-20261019T1108.md", "# CRE349 lecture\n\n## Summary\nx")
        let s = try #require(Session.parse(write("listen-20261019T1108.txt", "11:08 Saw all this\n\n12:52 bye")))
        #expect(s.kind == .recording && s.title == "CRE349 lecture" && s.minutes == 105 && s.notes != nil)
    }

    @Test func recordingAcrossMidnight() {
        #expect(Session.minutesSpanned("23:58 a\n\n00:02 b") == 5)
        #expect(Session.minutesSpanned("no stamps here") == nil)
    }

    @Test func ignoresOtherFiles() {
        #expect(Session.parse(write("state.json", "{}")) == nil)
        #expect(Session.parse(write("listen-bad.txt", "x")) == nil)
        #expect(Session.parse(write("inbox.jsonl", "")) == nil)
    }

    @Test func newFileNamesNeverCollide() throws {
        let noon = try #require(Paths.stamp.date(from: "20261022T1200"))
        let first = Paths.newRecording(at: noon, in: dir)
        #expect(first.lastPathComponent == "listen-20261022T1200.txt")
        try "".write(to: first, atomically: true, encoding: .utf8)
        #expect(Paths.newRecording(at: noon, in: dir).lastPathComponent == "listen-20261022T1201.txt")
        #expect(Paths.newCallTranscript(at: noon, in: dir).lastPathComponent == "transcript-20261022T1200.json")
    }

    @Test func loadSortsNewestFirst() {
        _ = write("transcript-20261001T1000.json", "[]")
        _ = write("listen-20261002T1000.txt", "10:00 a")
        #expect(Session.load(from: dir).map(\.kind) == [.recording, .call])
    }
}

@Test func callCostFormats() {
    #expect(callCost(seconds: 0) == "$0.00")
    #expect(callCost(seconds: 250) == "$0.21")
}
