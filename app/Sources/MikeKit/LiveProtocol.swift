import Foundation

/// GPT-Live over a primary WebSocket, as the openai Python SDK speaks it (openai/resources/live/live.py and
/// openai/types/live/*): open `endpoint` with `Authorization: Bearer <key>`, send session.start, wait for
/// session.started, then stream. Audio is base64 PCM16 mono 24 kHz both ways; every message is one JSON text frame.
public enum LiveProtocol {
    public static let endpoint = "wss://api.openai.com/v1/live/sessions"
    public static let rate = 24000

    /// The server events a solo call reads. Anything else, or anything unreadable, is `.other` (type "" if it had none).
    public enum ServerEvent: Equatable, Sendable {
        case started, audio(Data), inputTranscript(String), outputTranscript(String), usage(Double), error(String)
        case closed(seconds: Double?, reason: String?), other(type: String)
    }

    public static func sessionStart(model: String, instructions: String) -> String {
        json(["type": "session.start", "session": ["model": model, "instructions": instructions,
                                                    "audio": ["format": ["type": "audio/pcm", "rate": rate]]]])
    }

    public static func appendAudio(_ pcm: Data) -> String {
        json(["type": "session.input_audio.append", "audio": pcm.base64EncodedString()])
    }

    public static func mute(_ muted: Bool) -> String {
        json(["type": muted ? "session.input_audio.mute" : "session.input_audio.unmute"])
    }

    public static let close = json(["type": "session.close"])

    public static func decode(_ data: Data) -> ServerEvent {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let type = o["type"] as? String else {
            return .other(type: "")
        }
        let delta = o["delta"] as? String
        let seconds = (o["usage"] as? [String: Any])?["seconds"] as? Double  // cumulative: replace, never sum
        switch type {
        case "session.started": return .started
        case "session.output_audio.delta": if let pcm = delta.flatMap({ Data(base64Encoded: $0) }) { return .audio(pcm) }
        case "session.input_transcript.delta": if let delta { return .inputTranscript(delta) }
        case "session.output_transcript.delta": if let delta { return .outputTranscript(delta) }
        case "session.usage.updated": if let seconds { return .usage(seconds) }
        case "error":
            let e = o["error"] as? [String: Any]
            let text = [e?["code"], e?["message"]].compactMap { $0 as? String }.joined(separator: ": ")
            return .error(text.isEmpty ? "unknown error" : text)
        case "session.closed": return .closed(seconds: seconds, reason: o["reason"] as? String)
        default: break
        }
        return .other(type: type)
    }

    /// RMS of PCM16, scaled like bridge.py's rms() so normal speech lands around 0.5-0.8; clamped to 1.
    public static func rms(_ pcm: Data) -> Double {
        let n = pcm.count / 2
        guard n > 0 else { return 0 }
        let sum = pcm.withUnsafeBytes { raw in
            (0..<n).reduce(0.0) { acc, i in let s = Double(raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)); return acc + s * s }
        }
        return min(1, (sum / Double(n)).squareRoot() / 6000)
    }

    static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
