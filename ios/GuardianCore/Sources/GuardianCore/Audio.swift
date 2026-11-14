import Foundation
public enum AudioError: Error { case invalidWAV }

/// Groups mono 16 kHz PCM around sound, rather than arbitrary clock boundaries.
/// This is an energy gate; ElevenLabs decides whether the clip contains speech.
public struct SpeechClipBuffer {
    private static let frameSize = 320  // 20 ms
    private static let leadFrames = 20  // 400 ms
    private static let pauseFrames = 35 // 700 ms
    private static let maxSamples = 128_000
    private var frame: [Int16] = []
    private var lead: [Int16] = []
    private var clip: [Int16] = []
    private var quiet = 0
    private var active = 0
    public init() {}

    public mutating func consume(_ samples: [Int16]) -> [[Int16]] {
        var completed: [[Int16]] = []
        var offset = 0
        while offset < samples.count {
            let end = min(samples.count, offset + Self.frameSize - frame.count)
            frame.append(contentsOf: samples[offset..<end])
            offset = end
            guard frame.count == Self.frameSize else { continue }
            let energy = frame.reduce(Int64(0)) { $0 + Int64($1) * Int64($1) }
            let sound = energy >= Int64(Self.frameSize * 200 * 200)
            if clip.isEmpty && !sound {
                keepLead(frame)
            } else {
                if clip.isEmpty { clip = lead; lead = [] }
                clip.append(contentsOf: frame)
                if sound { quiet = 0; active += 1 } else { quiet += 1 }
                let paused = quiet >= Self.pauseFrames
                if paused || clip.count >= Self.maxSamples {
                    // Ignore brief transients. Keep context for a new clip, overlapping
                    // longer runs by a second when they reach the provider's length limit.
                    if active >= 4 { completed.append(clip) }
                    if paused {
                        lead = Array(clip.suffix(Self.leadFrames * Self.frameSize))
                        clip = []; quiet = 0
                    } else {
                        clip = Array(clip.suffix(50 * Self.frameSize))
                    }
                    active = 0
                }
            }
            frame.removeAll(keepingCapacity: true)
        }
        return completed
    }

    private mutating func keepLead(_ samples: [Int16]) {
        lead.append(contentsOf: samples)
        let overflow = lead.count - Self.leadFrames * Self.frameSize
        if overflow > 0 { lead.removeFirst(overflow) }
    }
}

public enum PCM16WAV {
    public static func encode(_ samples: [Int16], maximumSamples: Int = 128_000) -> Data {
        let bounded = samples.prefix(max(0, maximumSamples))
        var data = Data()
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); u32(UInt32(36+bounded.count*2)); data.append(contentsOf: "WAVEfmt ".utf8); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16); data.append(contentsOf: "data".utf8); u32(UInt32(bounded.count*2))
        for sample in bounded { u16(UInt16(bitPattern: sample)) }; return data
    }
    public static func decode(_ data: Data) throws -> [Int16] {
        let b = [UInt8](data)
        func u16(_ p: Int) -> Int { Int(b[p]) | Int(b[p+1]) << 8 }
        func u32(_ p: Int) -> Int { u16(p) | u16(p+2) << 16 }
        func text(_ p: Int, _ n: Int) -> String { String(decoding: b[p..<p+n], as: UTF8.self) }
        guard b.count >= 44, text(0,4) == "RIFF", text(8,4) == "WAVE", u32(4)+8 == b.count else { throw AudioError.invalidWAV }
        var position = 12, format = false, samples: [Int16]?
        while position+8 <= b.count {
            let size = u32(position+4), start = position+8
            guard size <= b.count-start else { throw AudioError.invalidWAV }
            if text(position,4) == "fmt " {
                guard size >= 16, !format, u16(start) == 1, u16(start+2) == 1, u32(start+4) == 16000, u32(start+8) == 32000, u16(start+12) == 2, u16(start+14) == 16 else { throw AudioError.invalidWAV }; format = true
            }
            if text(position,4) == "data" { guard samples == nil, size % 2 == 0, size <= 256000 else { throw AudioError.invalidWAV }; samples = stride(from: start, to: start+size, by: 2).map { Int16(bitPattern: UInt16(u16($0))) } }
            position = start+size+(size%2)
        }
        guard format, let samples, samples.count >= 1600 else { throw AudioError.invalidWAV }; return samples
    }
}
