import Foundation
import Testing
@testable import CallNotchKit

@Suite struct LiveProtocolTests {
    func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    func decode(_ text: String) -> LiveProtocol.ServerEvent { LiveProtocol.decode(Data(text.utf8)) }

    @Test func encodesSessionStart() throws {
        let o = try #require(object(LiveProtocol.sessionStart(model: "gpt-live-1", instructions: "be \"brief\"/kind")))
        #expect(o["type"] as? String == "session.start")
        let session = try #require(o["session"] as? [String: Any])
        #expect(session["model"] as? String == "gpt-live-1")
        #expect(session["instructions"] as? String == "be \"brief\"/kind")
        #expect(session["delegation"] == nil)  // solo: no delegation key at all
        let format = (session["audio"] as? [String: Any])?["format"] as? [String: Any]
        #expect(format?["type"] as? String == "audio/pcm" && format?["rate"] as? Int == 24000)
    }

    @Test func encodesAudioMuteAndClose() throws {
        let pcm = Data([0x01, 0x00, 0xFF, 0x7F, 0xFB, 0xFF])
        let append = try #require(object(LiveProtocol.appendAudio(pcm)))
        #expect(append.count == 2 && append["type"] as? String == "session.input_audio.append")
        #expect((append["audio"] as? String).flatMap { Data(base64Encoded: $0) } == pcm)
        #expect(LiveProtocol.mute(true) == #"{"type":"session.input_audio.mute"}"#)
        #expect(LiveProtocol.mute(false) == #"{"type":"session.input_audio.unmute"}"#)
        #expect(LiveProtocol.close == #"{"type":"session.close"}"#)
    }

    @Test func decodesServerEvents() {
        #expect(decode(#"{"type":"session.started","event_id":"e1","session":{"id":"s1","model":"gpt-live-1"}}"#) == .started)
        let pcm = Data([0x10, 0x20, 0x30, 0x40])
        #expect(decode(#"{"type":"session.output_audio.delta","delta":"\#(pcm.base64EncodedString())"}"#) == .audio(pcm))
        #expect(decode(#"{"type":"session.input_transcript.delta","delta":"hel","start_ms":0,"end_ms":200,"event_id":"e2"}"#) == .inputTranscript("hel"))
        #expect(decode(#"{"type":"session.output_transcript.delta","delta":"Hi.","start_ms":0,"end_ms":200,"event_id":"e3"}"#) == .outputTranscript("Hi."))
        #expect(decode(#"{"type":"session.usage.updated","event_id":"e4","usage":{"seconds":12.5},"context_window":{"usage_ratio":0.1}}"#) == .usage(12.5))
        #expect(decode(#"{"type":"session.usage.updated","event_id":"e4","usage":{"seconds":3}}"#) == .usage(3))
        #expect(decode(#"{"type":"error","event_id":"e5","error":{"code":"unknown_parameter","message":"Unknown parameter: 'x'.","type":"invalid_request_error"}}"#)
            == .error("unknown_parameter: Unknown parameter: 'x'."))
        #expect(decode(#"{"type":"error","event_id":"e5","error":{}}"#) == .error("unknown error"))
        #expect(decode(#"{"type":"session.closed","event_id":"e6","reason":"close_requested","session":{},"usage":{"seconds":4.2}}"#)
            == .closed(seconds: 4.2, reason: "close_requested"))
        #expect(decode(#"{"type":"session.closed"}"#) == .closed(seconds: nil, reason: nil))
    }

    @Test func unknownAndMalformedAreOther() {
        #expect(decode(#"{"type":"session.input_audio.muted","event_id":"e7"}"#) == .other(type: "session.input_audio.muted"))
        #expect(decode(#"{"type":"session.output_audio.delta","delta":"%%% not base64"}"#) == .other(type: "session.output_audio.delta"))
        #expect(decode(#"{"type":"session.output_transcript.delta"}"#) == .other(type: "session.output_transcript.delta"))
        #expect(decode("not json") == .other(type: ""))
        #expect(decode(#"["session.started"]"#) == .other(type: ""))
        #expect(decode(#"{"delta":"x"}"#) == .other(type: ""))
    }

    @Test func rmsMatchesBridge() {
        func pcm(_ s: [Int16]) -> Data { s.withUnsafeBytes { Data($0) } }
        #expect(LiveProtocol.rms(Data()) == 0)
        #expect(LiveProtocol.rms(pcm([3000, -3000])) == 0.5)
        #expect(LiveProtocol.rms(pcm([32767])) == 1)
    }

    @Test func soloPromptCanHangUp() {
        #expect(LiveCall.soloInstructions.contains(LiveCall.signOff))
        #expect(LiveCall.soloInstructions.hasSuffix("end with exactly: Hanging up now."))
    }

    @Test func silenceGuardWarnsOnceThenHangsUp() {
        #expect(LiveCall.silence(quiet: 5, limit: 30, warned: false) == (false, false))
        #expect(LiveCall.silence(quiet: 20, limit: 30, warned: false) == (true, false))   // 10 s before: warn
        #expect(LiveCall.silence(quiet: 25, limit: 30, warned: true) == (false, false))   // only once
        #expect(LiveCall.silence(quiet: 30, limit: 30, warned: true) == (false, true))    // then hang up
        #expect(LiveCall.silence(quiet: 9_999, limit: 0, warned: false) == (false, false))  // Never
        #expect(LiveCall.silence(quiet: 6, limit: 15, warned: false) == (true, false))    // short limits warn early
    }
}
