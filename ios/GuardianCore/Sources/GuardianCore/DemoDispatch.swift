import Foundation

public struct IncidentCoordinates: Codable, Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let accuracyMeters: Double

    public init(latitude: Double, longitude: Double, accuracyMeters: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyMeters = accuracyMeters
    }

    public var displayText: String {
        "\(Self.degrees(latitude))°, \(Self.degrees(longitude))°"
    }

    fileprivate var spokenText: String {
        let northSouth = latitude < 0 ? "south" : "north"
        let eastWest = longitude < 0 ? "west" : "east"
        return "Latitude \(Self.spokenDegrees(latitude)) degrees \(northSouth), longitude \(Self.spokenDegrees(longitude)) degrees \(eastWest)."
    }

    private static func degrees(_ value: Double) -> String {
        String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func spokenDegrees(_ value: Double) -> String {
        let parts = degrees(abs(value)).split(separator: ".")
        guard parts.count == 2 else { return degrees(abs(value)) }
        return "\(parts[0]) point \(parts[1].map(String.init).joined(separator: " "))"
    }
}

public struct DemoDispatch: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case calling, connected, briefing, complete
    }

    public enum Service: String, CaseIterable, Sendable {
        case police = "Police"
        case ambulance = "Ambulance"

        public var animation: IncidentAnimation.Kind { self == .police ? .patrol : .pulse }
    }

    public let incidentID: String
    public let service: Service
    public let context: String
    public var phase: Phase = .calling
    public var coordinates: IncidentCoordinates?

    public init(incident: Incident, requestedService: Service? = nil) {
        incidentID = incident.id
        coordinates = incident.location
        let fell = incident.detection?.label == "possible_fall"
        let motionOnly = incident.trigger == "motion" && incident.detection == nil
        if let requestedService {
            service = requestedService
            context = "The wearer requested emergency assistance."
        } else if fell || motionOnly || incident.trigger == "motion_phone" {
            service = .ambulance
            context = incident.trigger == "motion_phone" ? "Phone motion matched a fall pattern. A wearer fall is unconfirmed." : "Guardian detected a possible fall."
        } else {
            service = .police
            switch incident.trigger {
            case "spoken_threat": context = "Guardian heard a possible threat."
            case "manual_sos", "keyword_sos": context = "The wearer requested emergency assistance."
            case "gesture_distress": context = "The wearer signaled for help."
            case "keyword_distress": context = "Guardian heard a request for help."
            default: context = "Guardian detected a possible immediate threat."
            }
        }
    }

    public var destination: String { "\(service.rawValue) dispatch" }

    public var title: String {
        switch phase {
        case .calling: return "Calling \(service.rawValue.lowercased())…"
        case .connected: return "Call connected"
        case .briefing: return "Sharing incident details"
        case .complete: return "Briefing complete"
        }
    }

    public var spokenBriefing: String {
        "\(destination), this is Ray Guardian. \(context) " +
        (coordinates.map { $0.spokenText } ?? "Current location is unavailable.")
    }
}
