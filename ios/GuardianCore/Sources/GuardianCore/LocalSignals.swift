import Foundation

public enum VoiceIntent: Equatable, Sendable { case sos, distress, cancel, threat }
public enum KeywordDetector {
    private static func words(in text: String) -> [String] {
        let normalized = text.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
        return normalized.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined().split(separator: " ").map(String.init)
    }

    /// The phone recognizer can emit a complete command before marking the transcript final.
    public static func isCancelCommand(_ text: String, isFinal: Bool, confidence: Float) -> Bool {
        guard confidence < 0 || confidence >= 0.55 || (!isFinal && confidence == 0) else { return false }
        let tokens = words(in: text)
        return tokens.suffix(2) == ["guardian", "cancel"]
            || tokens.suffix(4) == ["guardian", "i", "am", "okay"]
            || tokens.suffix(3) == ["guardian", "im", "okay"]
    }

    public static func intent(_ text: String, isFinal: Bool, confidence: Float, isPlayingVoice: Bool = false) -> VoiceIntent? {
        guard !isPlayingVoice else { return nil }
        let words = words(in: text)
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
    public mutating func beginCapture(now: Double, localOnly: Bool = false) -> UUID? {
        guard consent.capture, localOnly || consent.cloud, let until = armedUntil,
              now < until, captureEndsAt == nil else { return nil }
        captureEndsAt = now+8; return epoch
    }
    public func accepts(_ token: UUID, now: Double) -> Bool { token == epoch && armedUntil.map { now < $0 } == true && captureEndsAt.map { now <= $0 } == true }
    public mutating func endCapture() { captureEndsAt = nil }
}
