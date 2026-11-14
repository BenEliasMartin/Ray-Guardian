import Foundation

public struct Consent: Codable, Equatable, Sendable {
    public var capture = false, cloud = false, audio = false, voice = false, demoCalls = false, location = false, backgroundEscalation = false
    public init() {}
}
public enum CaptureSource: String, Codable, CaseIterable, Sendable { case meta_mock, meta_glasses, phone, file_replay }
public enum TriggerSignal: String, Codable, Sendable { case manual_sos, keyword_sos, keyword_distress, spoken_threat, motion, motion_phone, heart_rate, loud_voice, manual_check }
public struct Detection: Codable, Equatable, Sendable {
    public let label: String, confidence: String, summary: String, observations: [String], uncertainties: [String], source: String
    public let wearerInvolved: Bool?
}
public struct CallStatus: Codable, Equatable, Sendable { public let transport: String, status: String; public let providerCallId: String?; public let error: String? }
public struct Incident: Codable, Equatable, Identifiable, Sendable {
    public let id: String, sessionId: String, mode: String, state: String, trigger: String
    public let detection: Detection?, detectedBy: String?, call: CallStatus?
    public let escalationToken: String?
    public let checkInDeadline: Double?, createdAt: Double, updatedAt: Double
    public let voiceConsent: Bool, demoCallConsent: Bool
    public var terminal: Bool { ["cancelled", "acknowledged", "closed"].contains(state) }
    public var triggerDescription: String {
        switch trigger {
        case "keyword_distress": return "Speech recognized a request for help or a report of danger"
        case "spoken_threat": return "Speech matched a possible threat"
        case "motion_phone": return "Test iPhone motion matched a fall pattern; wearer fall unconfirmed"
        default: return detectedBy == "nemotron" ? "Evidence assessed by Nemotron" : "Wearer initiated SOS; awaiting optional Nemotron evidence"
        }
    }
}
public struct ObservationResult: Codable, Sendable {
    public let detection: Detection, incident: Incident?, audioTranscriptionSource: String?, framesAnalyzed: Int, audioDurationMs: Double, rawMediaRetained: Bool
}
public struct CaptureWindow: Codable, Identifiable, Sendable {
    public let id: String, startedAt: Double, captureEndsAt: Double, uploadEndsAt: Double, signal: String, state: String
    public let result: ObservationResult?
}
public struct GuardianSession: Codable, Identifiable, Sendable {
    public let id: String, mode: String, source: CaptureSource, consent: Consent, armed: Bool, armedUntil: Double?, activeWindow: CaptureWindow?, incidentId: String?
}
public struct TriggerReply: Codable, Sendable { public let accepted: Bool, reason: String, session: GuardianSession, incident: Incident?, window: CaptureWindow? }
public struct FramePayload: Codable, Sendable {
    public let offsetMs: Double, imageDataUrl: String
    public init(offsetMs: Double, jpeg: Data) { self.offsetMs = offsetMs; imageDataUrl = "data:image/jpeg;base64," + jpeg.base64EncodedString() }
}
public struct AudioPayload: Encodable, Sendable {
    public let format = "wav_pcm_s16le_16000_mono"
    public let base64: String, source: String
    public init(wav: Data, source: String) { base64 = wav.base64EncodedString(); self.source = source }
}
public struct ObservationPayload: Encodable, Sendable {
    public let windowId: String, frames: [FramePayload], audio: AudioPayload?, transcript: String?, source: CaptureSource
    public let motion: MotionSummary?
    public init(windowId: String, frames: [FramePayload], audio: AudioPayload?, transcript: String?, source: CaptureSource, motion: MotionSummary? = nil) {
        self.windowId = windowId; self.frames = frames; self.audio = audio; self.transcript = transcript; self.source = source; self.motion = motion
    }
}
public struct ReplayClip: Codable, Identifiable, Sendable {
    public let id: String, title: String, video: String, audio: String?, expected: String?, attribution: String?, motion: String?
}
public struct ReplayManifest: Codable, Sendable { public let clips: [ReplayClip] }
public struct ProviderHealth: Codable, Sendable { public let configured: Bool }
public struct Health: Codable, Sendable { public let status: String, mode: String, providers: [String: ProviderHealth], callTransport: String, ready: Bool }
