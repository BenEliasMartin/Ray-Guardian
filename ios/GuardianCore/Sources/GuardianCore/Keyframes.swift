import Foundation

public enum FrameSharpness {
    /// Variance of a 4-neighbour Laplacian over an 8-bit grayscale image. Motion blur and darkness score low.
    public static func laplacianVariance(_ gray: [UInt8], width: Int, height: Int) -> Double {
        guard width >= 3, height >= 3, gray.count >= width*height else { return 0 }
        var sum = 0.0, sumSquares = 0.0, count = 0.0
        for y in 1..<(height-1) {
            for x in 1..<(width-1) {
                let i = y*width+x
                let value = Double(gray[i-1]) + Double(gray[i+1]) + Double(gray[i-width]) + Double(gray[i+width]) - 4*Double(gray[i])
                sum += value; sumSquares += value*value; count += 1
            }
        }
        guard count > 0 else { return 0 }
        let mean = sum/count
        return max(0, sumSquares/count - mean*mean)
    }
}

/// Picks up to six frames that cover before, during and after a trigger, preferring the sharpest frame
/// in each period. Offsets are seconds relative to the trigger.
public enum KeyframeSelector {
    public static let maximumFrames = 6
    /// Two periods before the trigger, a dense one right after it, then progression and recovery.
    public static let periods: [Range<Double>] = [-3.01 ..< -1.2, -1.2 ..< 0, 0 ..< 1.5, 1.5 ..< 3.5, 3.5 ..< 5.5, 5.5 ..< 8.01]

    public static func select(offsets: [Double], sharpness: [Double], limit: Int = maximumFrames) -> [Int] {
        guard offsets.count == sharpness.count, limit > 0 else { return [] }
        let valid = offsets.indices.filter { offsets[$0].isFinite && offsets[$0] >= -3.01 && offsets[$0] <= 8.01 }
        var chosen: [Int] = []
        for period in periods {
            let candidates = valid.filter { period.contains(offsets[$0]) && !chosen.contains($0) }
            if let best = candidates.max(by: { sharpness[$0] < sharpness[$1] }) { chosen.append(best) }
        }
        // Fill unused periods with the sharpest remaining frames, keeping them at least 0.3 s apart.
        let remaining = valid.filter { !chosen.contains($0) }.sorted { sharpness[$0] > sharpness[$1] }
        for index in remaining where chosen.count < limit {
            if chosen.allSatisfy({ abs(offsets[$0]-offsets[index]) >= 0.3 }) { chosen.append(index) }
        }
        return Array(chosen.sorted { offsets[$0] < offsets[$1] }.prefix(limit))
    }
}
