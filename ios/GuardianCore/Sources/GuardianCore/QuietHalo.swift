import Foundation

/// Presentation only. This never advances an incident, starts capture, or queues a call.
public enum QuietHalo {
    public enum Tone: Equatable, Sendable { case amber, mint, neutral, warning }
    public enum Kind: Equatable, Sendable { case checkIn, activity, attention, confirmation }
    public struct State: Equatable, Sendable {
        public let title: String, detail: String, symbol: String
        public let tone: Tone, kind: Kind
        public init(_ title: String, _ detail: String, _ symbol: String, _ tone: Tone, _ kind: Kind) {
            self.title = title; self.detail = detail; self.symbol = symbol; self.tone = tone; self.kind = kind
        }
    }
    public static func state(incidentState: String?, transport: String? = nil, capturing: Bool = false, processing: Bool = false) -> State? {
        // An active incident always takes precedence over capture/inference feedback.
        switch incidentState {
        case "check_in": return State("Are you okay?", "Check-in", "questionmark", .amber, .checkIn)
        case "awaiting_foreground_confirmation": return State("Confirm demo alert", "Companion confirmation", "bell", .amber, .attention)
        case "needs_demo_call_consent": return State("Demo alert paused", "Consent needed", "pause", .amber, .attention)
        case "demo_call_limited": return State("Demo limit reached", "Alert paused", "pause", .amber, .attention)
        case "call_queued": return State("Preparing demo alert", "Not yet connected", "paperplane", .amber, .activity)
        case "call_ringing": return State("Test phone ringing", "Demo call", "phone", .amber, .activity)
        case "call_in_progress": return State("Demo call connected", "Test destination", "phone.fill", .amber, .activity)
        case "demo_call_active":
            return transport == "playback" ? State("Demo playback active", "In-app audio", "speaker.wave.2", .amber, .activity) : State("Demo alert active", "Demo transport", "bell", .amber, .activity)
        case "call_completed": return State("Demo call ended", "Awaiting acknowledgment", "phone.down", .neutral, .attention)
        case "call_failed": return State("Demo call failed", "Check companion", "exclamationmark", .warning, .attention)
        case "call_unknown": return State("Check demo status", "Outcome unconfirmed", "questionmark", .warning, .attention)
        case "cancelled": return State("Demo cancelled", "Confirmed", "checkmark", .mint, .confirmation)
        case "acknowledged": return State("Demo acknowledged", "Confirmed", "checkmark", .mint, .confirmation)
        case "closed", nil: break
        default: return State("Check demo status", "Status unavailable", "questionmark", .warning, .attention)
        }
        if capturing { return State("Checking on you", "Brief capture", "camera", .neutral, .activity) }
        if processing { return State("Assessing scene", "Please wait", "sparkle.magnifyingglass", .neutral, .activity) }
        return nil // No idle badge, timer, or repeating animation.
    }

    public struct Countdown: Equatable, Sendable {
        public struct Reading: Equatable, Sendable {
            public let seconds: Int
            public let fraction: Double
        }
        public let startedAt: Double, deadline: Double
        /// Timestamps are server epoch milliseconds. Do not invent a new local deadline.
        public init?(startedAt: Double, deadline: Double) {
            guard startedAt.isFinite, deadline.isFinite, deadline > startedAt, deadline-startedAt <= 86_400_000 else { return nil }
            self.startedAt = startedAt; self.deadline = deadline
        }
        public func reading(at now: Double) -> Reading? {
            guard now.isFinite else { return nil }
            let duration = deadline-startedAt, remaining = min(duration,max(0,deadline-now))
            return Reading(seconds:Int(ceil(remaining/1000)),fraction:remaining/duration)
        }
    }
}
