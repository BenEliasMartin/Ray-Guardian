import Foundation

/// One glasses IMU sample. Acceleration is in m/s² (gravity included); rotation rate is in rad/s when available.
public struct MotionPoint: Sendable, Equatable {
    public let time: Double, x: Double, y: Double, z: Double
    public let rotationX: Double?, rotationY: Double?, rotationZ: Double?
    public init(time: Double, x: Double, y: Double, z: Double, rotationX: Double? = nil, rotationY: Double? = nil, rotationZ: Double? = nil) {
        self.time = time; self.x = x; self.y = y; self.z = z
        self.rotationX = rotationX; self.rotationY = rotationY; self.rotationZ = rotationZ
    }
    public var g: Double { sqrt(x*x+y*y+z*z)/9.80665 }
    /// Rotation speed in rad/s, or nil when the device did not report a gyroscope reading.
    public var rotationRate: Double? {
        guard let rotationX, let rotationY, let rotationZ else { return nil }
        let value = sqrt(rotationX*rotationX+rotationY*rotationY+rotationZ*rotationZ)
        return value.isFinite ? value : nil
    }
    /// Core Motion includes gravity and reports g; DAT reports m/s².
    public static func phoneAcceleration(time: Double, x: Double, y: Double, z: Double,
                                         rotationX: Double? = nil, rotationY: Double? = nil, rotationZ: Double? = nil) -> MotionPoint {
        MotionPoint(time: time, x: x*9.80665, y: y*9.80665, z: z*9.80665, rotationX: rotationX, rotationY: rotationY, rotationZ: rotationZ)
    }
    public func retimed(_ time: Double) -> MotionPoint {
        MotionPoint(time: time, x: x, y: y, z: z, rotationX: rotationX, rotationY: rotationY, rotationZ: rotationZ)
    }
}

public enum FallPattern: String, Codable, Sendable {
    /// Near-weightless drop followed by an impact.
    case freeFallImpact = "free_fall_impact"
    /// Head orientation swung far from its previous direction together with an impact or a fast rotation.
    case rapidTilt = "rapid_tilt"
    /// Head orientation ended far from where it was a few seconds earlier and has since stayed still.
    case slump
}

/// Unit vector of the gravity direction, smoothed so that brief jolts do not dominate it.
struct GravityFilter: Sendable {
    private(set) var direction: (Double, Double, Double)?
    private var lastTime: Double?
    static let timeConstant = 0.2
    mutating func reset() { direction = nil; lastTime = nil }
    mutating func consume(_ p: MotionPoint) -> (Double, Double, Double)? {
        let length = sqrt(p.x*p.x+p.y*p.y+p.z*p.z)
        guard length.isFinite, length > 0.5 else { return direction }
        let unit = (p.x/length, p.y/length, p.z/length)
        guard let current = direction, let lastTime else { direction = unit; lastTime = p.time; return unit }
        let alpha = min(1, max(0, (p.time-lastTime)/Self.timeConstant))
        let mixed = (current.0+(unit.0-current.0)*alpha, current.1+(unit.1-current.1)*alpha, current.2+(unit.2-current.2)*alpha)
        let norm = sqrt(mixed.0*mixed.0+mixed.1*mixed.1+mixed.2*mixed.2)
        if norm > 0.000001 { direction = (mixed.0/norm, mixed.1/norm, mixed.2/norm) }
        self.lastTime = p.time
        return direction
    }
}

func angleDegrees(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
    let dot = max(-1, min(1, a.0*b.0+a.1*b.1+a.2*b.2))
    return acos(dot)*180/Double.pi
}

/// Candidate detector, not a medical fall classifier. It only requests a bounded visual assessment.
/// Three paths: free fall then impact; a fast large head-orientation change with an impact or a fast
/// rotation; or a large orientation change followed by stillness (slow collapse or slump).
public struct FallCandidateDetector: Sendable {
    public static let rapidTiltDegrees = 55.0, slumpTiltDegrees = 60.0
    public static let tiltImpactG = 2.0, fastRotationRadPerSec = 5.0
    public static let stillSeconds = 2.5, cooldownSeconds = 60.0
    private struct Entry: Sendable { let time: Double, gravity: (Double, Double, Double), g: Double, rotation: Double? }
    private var lowAt: Double?, lastTime: Double?, lastTrigger: Double?
    private var gravity = GravityFilter(), history: [Entry] = []
    public private(set) var lastPattern: FallPattern?
    public init() {}

    public mutating func consume(_ p: MotionPoint) -> Bool { detect(p) != nil }

    public mutating func detect(_ p: MotionPoint) -> FallPattern? {
        guard p.time.isFinite, p.g.isFinite else { return nil }
        if let lastTime, p.time <= lastTime { return nil }
        if let lastTime, p.time-lastTime > 1 { lowAt = nil; history.removeAll(); gravity.reset() }
        lastTime = p.time
        guard let direction = gravity.consume(p) else { return nil }
        history.append(Entry(time: p.time, gravity: direction, g: p.g, rotation: p.rotationRate))
        history.removeAll { p.time-$0.time > 6 }
        if let lastTrigger, p.time-lastTrigger < Self.cooldownSeconds { return nil }

        if p.g < 0.55 {
            if lowAt == nil { lowAt = p.time }
        } else if let start = lowAt {
            if p.time-start > 1.5 { lowAt = nil }
            else if p.g >= 2.4, p.time-start >= 0.04 { return fire(.freeFallImpact, at: p.time) }
        }

        // Rapid tilt: compare with the head direction about two seconds earlier.
        if let reference = sample(atLeast: 1.0, atMost: 2.5, before: p.time),
           angleDegrees(reference.gravity, direction) >= Self.rapidTiltDegrees {
            let recent = history.filter { p.time-$0.time <= 2.0 }
            let impact = recent.contains { $0.g >= Self.tiltImpactG }
            let spin = recent.contains { ($0.rotation ?? 0) >= Self.fastRotationRadPerSec }
            if impact || spin { return fire(.rapidTilt, at: p.time) }
        }

        // Slump: a large orientation change, then stillness for the last few seconds.
        if let reference = sample(atLeast: 4.5, atMost: 6.0, before: p.time),
           angleDegrees(reference.gravity, direction) >= Self.slumpTiltDegrees {
            let still = history.filter { p.time-$0.time <= Self.stillSeconds }
            let covered = (still.first.map { p.time-$0.time } ?? 0) >= Self.stillSeconds-0.2
            let calm = still.allSatisfy { abs($0.g-1) < 0.08 && ($0.rotation ?? 0) < 0.35 }
            let settled = still.first.map { angleDegrees($0.gravity, direction) < 10 } ?? false
            if covered, calm, settled { return fire(.slump, at: p.time) }
        }
        return nil
    }

    private func sample(atLeast: Double, atMost: Double, before time: Double) -> Entry? {
        history.first { time-$0.time >= atLeast && time-$0.time <= atMost }
    }
    private mutating func fire(_ pattern: FallPattern, at time: Double) -> FallPattern {
        lowAt = nil; lastTrigger = time; lastPattern = pattern
        return pattern
    }
}

/// Privacy-safe summary of the wearer's own movement around a trigger. It contains no location or raw samples.
public struct MotionSummary: Codable, Equatable, Sendable {
    public let fallPattern: FallPattern?
    public let peakImpactG: Double, minG: Double, tiltDegrees: Double
    public let peakRotationDegPerSec: Double?
    public let stillSecondsAtEnd: Double
    public let coveredFromMs: Double, coveredToMs: Double, samples: Int
}

/// Keeps the last few seconds of IMU samples in memory, timed by the phone's monotonic clock.
public struct MotionRecorder: Sendable {
    public static let retainedSeconds = 12.0
    private var points: [MotionPoint] = []
    public init() {}
    public mutating func reset() { points.removeAll() }
    public mutating func append(_ p: MotionPoint) {
        guard p.time.isFinite, p.g.isFinite else { return }
        if let last = points.last, p.time <= last.time { return }
        points.append(p)
        if let first = points.first, p.time-first.time > Self.retainedSeconds + 1 {
            points.removeAll { p.time-$0.time > Self.retainedSeconds }
        }
    }

    /// Summarizes samples from three seconds before `triggerAt` until `endAt`.
    public func summary(triggerAt: Double, endAt: Double, fallPattern: FallPattern? = nil) -> MotionSummary? {
        let window = points.filter { $0.time >= triggerAt-3 && $0.time <= endAt }
        guard window.count >= 5, let first = window.first, let last = window.last else { return nil }
        func meanDirection(_ items: [MotionPoint]) -> (Double, Double, Double)? {
            let sum = items.reduce((0.0, 0.0, 0.0)) { ($0.0+$1.x, $0.1+$1.y, $0.2+$1.z) }
            let norm = sqrt(sum.0*sum.0+sum.1*sum.1+sum.2*sum.2)
            return norm > 0.000001 ? (sum.0/norm, sum.1/norm, sum.2/norm) : nil
        }
        let before = window.filter { $0.time <= triggerAt-0.8 }
        let start = before.isEmpty ? Array(window.prefix(5)) : before
        let end = window.filter { last.time-$0.time <= 1.0 }
        var tilt = 0.0
        if let from = meanDirection(start), let to = meanDirection(end) { tilt = angleDegrees(from, to) }
        let rotations = window.compactMap(\.rotationRate)
        var stillSince = last.time
        for p in window.reversed() {
            guard abs(p.g-1) < 0.08, (p.rotationRate ?? 0) < 0.35 else { break }
            stillSince = p.time
        }
        func round1(_ value: Double) -> Double { (value*10).rounded()/10 }
        func round2(_ value: Double) -> Double { (value*100).rounded()/100 }
        return MotionSummary(
            fallPattern: fallPattern,
            peakImpactG: round2(window.map(\.g).max() ?? 1),
            minG: round2(window.map(\.g).min() ?? 1),
            tiltDegrees: round1(tilt),
            peakRotationDegPerSec: rotations.max().map { round1($0*180/Double.pi) },
            stillSecondsAtEnd: round1(last.time-stillSince),
            coveredFromMs: ((first.time-triggerAt)*1000).rounded(), coveredToMs: ((last.time-triggerAt)*1000).rounded(),
            samples: window.count)
    }
}
