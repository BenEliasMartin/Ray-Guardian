import Foundation
public enum HeartRateMeasurement {
    public static func decode(_ bytes: Data) -> Int? {
        let b = [UInt8](bytes); guard b.count >= 2 else { return nil }
        let value: Int
        if b[0]&1 == 1 { guard b.count >= 3 else { return nil }; value = Int(b[1]) | Int(b[2])<<8 } else { value = Int(b[1]) }
        // Contact-supported bit set with no detected contact means the measurement is unusable.
        if b[0]&4 != 0 && b[0]&2 == 0 { return nil }
        return (25...240).contains(value) ? value : nil
    }
}
public struct SustainedHeartRate: Sendable {
    private var firstHigh: Double?, count = 0, last: Double?, lastTrigger: Double?
    public init() {}
    public mutating func consume(bpm: Int, threshold: Int, time: Double) -> Bool {
        guard (25...240).contains(bpm), (120...220).contains(threshold),time.isFinite else { return false }
        if let last, time <= last { return false }
        if let last,time-last > 5 { firstHigh = nil; count = 0 }; last = time
        guard bpm >= threshold else { firstHigh = nil; count = 0; return false }
        if firstHigh == nil { firstHigh = time }; count += 1
        guard count >= 3,time-(firstHigh ?? time) >= 8,lastTrigger.map({time-$0 >= 60}) ?? true else { return false }
        lastTrigger = time; firstHigh = nil; count = 0; return true
    }
}
