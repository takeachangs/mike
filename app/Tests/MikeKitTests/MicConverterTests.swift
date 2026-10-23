import AVFoundation
import Testing
@testable import MikeKit

@Test func voiceProcessingFormatKeepsChannelZeroAt24kMono() throws {
    // What voice processing can hand over: 48 kHz, many channels, the cleaned mic on the first and the rest empty.
    let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Unknown | 9))
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
    let conv = try #require(LiveCall.micConverter(from: format, voice: true))
    #expect(conv.outputFormat.sampleRate == 24000 && conv.outputFormat.channelCount == 1 && conv.outputFormat.commonFormat == .pcmFormatInt16)
    let buf = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
    buf.frameLength = 4800
    for i in 0..<4800 { buf.floatChannelData![0][i] = 0.5 }
    let out = try #require(AVAudioPCMBuffer(pcmFormat: conv.outputFormat, frameCapacity: 2432))
    var fed = false, error: NSError?
    conv.convert(to: out, error: &error) { _, status in
        if fed { status.pointee = .noDataNow; return nil }
        fed = true; status.pointee = .haveData; return buf
    }
    #expect(error == nil && out.frameLength > 2000)
    #expect(out.int16ChannelData![0][Int(out.frameLength) / 2] > 14000)  // 0.5 * 32767 = 16383, not 1/9 of it
}
