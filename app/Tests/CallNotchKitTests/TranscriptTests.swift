import Foundation
import Testing
@testable import CallNotchKit

@Suite struct TranscriptTests {
    let utc = TimeZone(identifier: "UTC")!
    let start = Date(timeIntervalSince1970: 14 * 3600 + 5 * 60 + 30)  // 14:05:30 UTC

    @Test func paragraphsPerClockMinute() {
        var b = TranscriptBuilder(start: start, timeZone: utc)
        #expect(b.add(full: "Good morning everyone.", startTime: 1) == "14:05")
        #expect(b.add(full: "Good morning everyone. Today, respiration.", startTime: 12) == nil)  // 14:05:42, same minute
        #expect(b.add(full: "Good morning everyone. Today, respiration. Stage one.", startTime: 31) == "14:06")
        #expect(b.render("Good morning everyone. Today, respiration. Stage one.") ==
                "14:05 Good morning everyone. Today, respiration.\n\n14:06 Stage one.")
    }

    @Test func firstBlockStartsAtZeroEvenIfEarlyWindowsHadNoTimings() {
        var b = TranscriptBuilder(start: start, timeZone: utc)
        #expect(b.add(full: "Hello", startTime: nil) == nil)
        #expect(b.add(full: "Hello there", startTime: 2) == "14:05")
        #expect(b.render("Hello there") == "14:05 Hello there")
    }

    @Test func offsetsNeverGoBackwardsWhenTheTextShrinks() {
        var b = TranscriptBuilder(start: start, timeZone: utc)
        _ = b.add(full: "one two three four", startTime: 0)
        _ = b.add(full: "one two three", startTime: 40)   // a seam word was retired: the text got shorter
        _ = b.add(full: "one two three five", startTime: 100)
        let offsets = b.blocks.map(\.offset)
        #expect(offsets == offsets.sorted())
        #expect(b.render("one two three five").components(separatedBy: "three").count == 2)  // no duplicated text
    }
}
