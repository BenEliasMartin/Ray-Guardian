import Foundation

public enum VoiceIntent: Equatable, Sendable { case sos, distress, cancel, threat }
public enum KeywordDetector {
    public static func intent(_ text: String, isFinal: Bool, confidence: Float, isPlayingVoice: Bool = false) -> VoiceIntent? {
        guard !isPlayingVoice else { return nil }
        let normalized = text.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
        let words = normalized.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined().split(separator: " ").map(String.init)
        let value = " " + words.joined(separator: " ") + " "
        if isFinal, confidence < 0 || confidence >= 0.55 {
            if value.contains(" guardian cancel ") || value.contains(" guardian i am okay ") { return .cancel }
            if value.contains(" guardian sos ") || value.contains(" guardian call for help ") { return .sos }
        }
        if (confidence == 0 && !isFinal) || confidence < 0 || confidence >= 0.55 {
            let threats = ["im going to kill you", "i am going to kill you", "im gonna kill you", "i will kill you", "ill kill you",
                           "im going to shoot you", "im gonna shoot you", "i will shoot you", "ill shoot you",
                           "im going to stab you", "im gonna stab you", "i will stab you", "ill stab you"]
            if threats.contains(where: { value.contains(" " + $0 + " ") }) { return .threat }
            let cries = ["help me", "somebody help", "someone help", "i need help", "please help"]
            // Direct first-person danger reports need no wake word or separate plea.
            // Anchor these to the speaker, so negations, hypotheticals and reported
            // speech such as "she said I'm in danger" do not become new triggers.
            let direct = words.joined(separator: " ")
            let firstPerson = "(?:i am|im|i m)"
            let reports = [
                "\(firstPerson) (?:in (?:immediate )?danger(?! of\\b)|not safe|unsafe|being (?:attacked|followed|threatened)|trapped|hurt|injured|bleeding|choking)",
                "i (?:cant|cannot|can not) (?:breathe|get up|move)",
                "(?:ive|i have) fallen|i fell",
                "(?:call (?:an ambulance|the police)|send help)"
            ]
            let directDistress = reports.contains {
                direct.range(of: "^(?:guardian )?(?:please )?(?:\($0))(?: |$)",options: .regularExpression) != nil
            }
            if (directDistress || words == ["help"] || cries.contains(where: { value.contains(" " + $0 + " ") })),
               isFinal || !value.contains(" guardian ") { return .distress }
        }
        return nil
    }
}
public struct MotionPoint: Sendable {
    public let time: Double, x: Double, y: Double, z: Double
    public init(time: Double, x: Double, y: Double, z: Double) { self.time = time; self.x = x; self.y = y; self.z = z }
    public var g: Double { sqrt(x*x+y*y+z*z)/9.80665 }
    /// Core Motion includes gravity and reports g; DAT reports m/s².
    public static func phoneAcceleration(time: Double, x: Double, y: Double, z: Double) -> MotionPoint {
        MotionPoint(time:time,x:x*9.80665,y:y*9.80665,z:z*9.80665)
    }
}
/// Candidate detector, not a medical fall classifier. Requires free-fall followed by impact.
public struct FallCandidateDetector: Sendable {
    private var lowAt: Double?, lastTime: Double?, lastTrigger: Double?
    public init() {}
    public mutating func consume(_ p: MotionPoint) -> Bool {
        guard p.time.isFinite, p.g.isFinite else { return false }
        if let lastTime, p.time <= lastTime { return false }
        if let lastTime, p.time-lastTime > 1 { lowAt = nil }
        lastTime = p.time
        if let lastTrigger, p.time-lastTrigger < 60 { return false }
        if p.g < 0.55 { if lowAt == nil { lowAt = p.time }; return false }
        guard let start = lowAt else { return false }
        if p.time-start > 1.5 { lowAt = nil; return false }
        if p.g >= 2.4, p.time-start >= 0.04 { lowAt = nil; lastTrigger = p.time; return true }
        return false
    }
}
public struct LoudnessDetector: Sendable {
    private var loudSince: Double?
    public init() {}
    public mutating func consume(_ samples: [Int16], time: Double) -> Bool {
        guard !samples.isEmpty else { return false }
        let rms = sqrt(samples.reduce(0.0) { $0 + pow(Double($1)/32768, 2) } / Double(samples.count))
        let db = 20*log10(max(rms, 0.000001))
        guard db > -12 else { loudSince = nil; return false }
        if loudSince == nil { loudSince = time }
        return time-(loudSince ?? time) >= 0.6
    }
}
/// Monotonic local gate. No camera or upload may outlive its epoch or eight-second deadline.
public struct PrivacyGate: Sendable {
    public private(set) var epoch = UUID(), armedUntil: Double?, captureEndsAt: Double?
    public private(set) var consent = Consent()
    public init() {}
    public static let maximumArmedDuration: TimeInterval = 30 * 60
    public mutating func arm(consent: Consent, now: Double, duration: TimeInterval = maximumArmedDuration) {
        invalidate()
        self.consent = consent
        armedUntil = now + min(max(0, duration), Self.maximumArmedDuration)
    }
    public mutating func invalidate() { epoch = UUID(); armedUntil = nil; captureEndsAt = nil }
    public mutating func beginCapture(now: Double) -> UUID? {
        guard consent.capture, consent.cloud, let until = armedUntil, now < until, captureEndsAt == nil else { return nil }
        captureEndsAt = now+8; return epoch
    }
    public func accepts(_ token: UUID, now: Double) -> Bool { token == epoch && armedUntil.map { now < $0 } == true && captureEndsAt.map { now <= $0 } == true }
    public mutating func endCapture() { captureEndsAt = nil }
}
