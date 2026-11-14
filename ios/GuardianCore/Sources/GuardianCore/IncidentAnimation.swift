import Foundation

/// Presentation only: a candidate cue never asserts a diagnosis, crime or dispatch.
public enum IncidentAnimation {
    public static let duration: TimeInterval = 6
    public enum Kind: String, Equatable, Sendable { case patrol, pulse }
    public struct Presentation: Equatable, Sendable {
        public let incidentID: String, kind: Kind, startedAt: TimeInterval
        public init(incidentID: String, kind: Kind, startedAt: TimeInterval) {
            self.incidentID = incidentID; self.kind = kind; self.startedAt = startedAt
        }
        public func elapsed(at now: TimeInterval) -> TimeInterval {
            guard now.isFinite, startedAt.isFinite else { return IncidentAnimation.duration }
            return min(IncidentAnimation.duration,max(0,now-startedAt))
        }
    }
    public static func kind(trigger: String, detectionLabel: String?) -> Kind? {
        // A later floor-view assessment must not erase an explicit threat cue.
        if trigger == "spoken_threat" { return .patrol }
        switch detectionLabel {
        case "possible_assault": return .patrol
        case "possible_fall": return .pulse
        default: break
        }
        switch trigger {
        case "motion", "motion_phone", "heart_rate": return .pulse
        default: return nil // Generic distress/SOS/fire remain a neutral check-in.
        }
    }
    public static func update(previous: Presentation?, incident: Incident?, now: TimeInterval) -> Presentation? {
        guard now.isFinite,let incident,!incident.terminal,
              let kind = kind(trigger:incident.trigger,detectionLabel:incident.detection?.label) else { return nil }
        if let previous,previous.incidentID == incident.id,previous.kind == kind { return previous }
        return Presentation(incidentID:incident.id,kind:kind,startedAt:now)
    }
}
