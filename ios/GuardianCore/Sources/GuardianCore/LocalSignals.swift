import Foundation

/// Fixed audio instructions never require a display on the glasses.
public enum HandsFreePrompt {
    public static func text(state: String, voiceCommands: Bool) -> String? {
        switch state {
        case "check_in": return voiceCommands
            ? "Are you okay? Say Guardian cancel, or Guardian SOS. This is a demo."
            : "Are you okay? Open Ray Guardian on your phone to cancel or request demo help."
        case "cancelled": return "Demo cancelled. No emergency services have been contacted."
        case "acknowledged": return "The demo operator acknowledged your report. No real responders have been dispatched."
        case "call_queued": return "Preparing the demo alert."
        case "call_ringing": return "The demo phone call is ringing."
        case "call_in_progress": return "The demo phone call is connected."
        case "call_completed": return "The demo phone call has finished."
        case "call_failed": return "The demo call failed. No help is confirmed. Check your phone."
        case "call_unknown": return "The demo call status is unknown. Check your phone."
        case "needs_demo_call_consent": return "Demo escalation is paused. Check consent in Ray Guardian on your phone."
        case "demo_call_limited": return "The demo call limit was reached. No new call has been placed."
        default: return nil
        }
    }
}

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
                "\(firstPerson) (?:in (?:immediate )?danger(?! of\\b)|not safe|unsafe|under attack|being (?:attacked|followed|threatened)|trapped|hurt|injured|bleeding|choking)",
                "i (?:cant|cannot|can not) (?:breathe|get up|move)",
                "i (?:dont|do not) feel safe|i fear for my life|my life is in danger",
                "i need (?:an ambulance|the police|medical help)",
                "(?:someone|somebody) is (?:attacking|following|threatening|hurting|choking) me",
                "(?:ive|i have) been attacked",
                "(?:ive|i have) fallen(?: down)?(?: and i (?:cant|cannot|can not) get up)?$|i fell(?: down| over)?$",
                "(?:call (?:an ambulance|the police)|send help)"
            ]
            let directDistress = reports.contains {
                direct.range(of: "^(?:guardian )?(?:please )?(?:\($0))(?: |$)",options: .regularExpression) != nil
            }
            // Refusal pleas can be uttered by anyone nearby and need no wake word.
            // Match whole pleas so ordinary "please don't forget ..." is excluded.
            let refusal = "^(?:guardian )?(?:(?:no )+(?:please )?(?:dont|do not)(?: do that)?|please (?:dont|do not)(?: do that)?|(?:no )*(?:please )?(?:dont|do not) (?:hurt|touch|hit|kill|shoot|stab|grab|follow) me|(?:no )*(?:please )?(?:let me go|leave me alone|get off me|get away from me)|no (?:please )?stop|please stop(?: it)?|stop please)(?: (?:no|please|stop))*$"
            let refusalPlea = direct.range(of:refusal,options:.regularExpression) != nil
            let negatedHelp = direct.range(of: "\\b(?:dont|do not|no need to) (?:please )?help\\b",options: .regularExpression) != nil
            let routineHelp = direct.range(of: "\\b(?:help me|need help|please help) with\\b",options: .regularExpression) != nil
            let helpRequest = !negatedHelp && !routineHelp && (words == ["help"] || cries.contains(where: { value.contains(" " + $0 + " ") }))
            if (directDistress || refusalPlea || helpRequest),
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
