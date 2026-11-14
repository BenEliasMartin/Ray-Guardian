import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
public enum APIError: LocalizedError {
    case invalidConfiguration, response(Int, String), invalidResponse
    public var errorDescription: String? { switch self { case .invalidConfiguration: return "Enter an HTTPS API URL and client token (32+ characters). HTTP is allowed only for local development."; case let .response(status,message): return "API \(status): \(message)"; case .invalidResponse: return "The server returned an invalid or oversized response." } }
}
private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public final class GuardianAPI: @unchecked Sendable {
    public let baseURL: URL
    private let token: String, session: URLSession
    public init(url: String, token: String, session: URLSession? = nil) throws {
        guard let base = URL(string: url), let host = base.host, base.user == nil, base.password == nil, base.query == nil, base.fragment == nil, token.range(of:"^[A-Za-z0-9._~\\-]{32,256}$",options:.regularExpression) != nil,
              base.scheme == "https" || (base.scheme == "http" && Self.isLocal(host)) else { throw APIError.invalidConfiguration }
        self.baseURL = base; self.token = token
        let configuration = URLSessionConfiguration.ephemeral; configuration.timeoutIntervalForRequest = 85; configuration.timeoutIntervalForResource = 90; configuration.urlCache = nil; configuration.httpCookieStorage = nil
        self.session = session ?? URLSession(configuration: configuration,delegate: NoRedirects(),delegateQueue:nil)
    }
    private static func isLocal(_ host: String) -> Bool {
        if ["localhost","127.0.0.1","::1","[::1]"].contains(host) || host.hasSuffix(".local") { return true }
        let parts = host.split(separator:"."); guard parts.count == 4 else { return false }
        let octets = parts.compactMap { Int($0) }; guard octets.count == 4,octets.allSatisfy({(0...255).contains($0)}) else { return false }
        return octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 172 && (16...31).contains(octets[1]))
    }
    private func perform(_ path: String, method: String, body: Data?, maximumBytes: Int = 4*1024*1024) async throws -> Data {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url); request.httpMethod = method; request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = body
        let (data,response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.url?.host == baseURL.host, data.count <= maximumBytes else { throw APIError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { let error = try? JSONDecoder().decode(ErrorBody.self, from: data); throw APIError.response(response.statusCode, error?.message ?? "Request failed") }; return data
    }
    private struct ErrorBody: Decodable { let message: String? }
    public func get<T: Decodable>(_ path: String, as: T.Type = T.self) async throws -> T { try JSONDecoder().decode(T.self, from: await perform(path, method: "GET", body: nil)) }
    public func post<T: Decodable, B: Encodable>(_ path: String, body: B, as: T.Type = T.self) async throws -> T { try JSONDecoder().decode(T.self, from: await perform(path, method: "POST", body: JSONEncoder().encode(body))) }
    public func post<T: Decodable>(_ path: String, as: T.Type = T.self) async throws -> T { try await post(path, body: Empty(), as: T.self) }
    public func audio(_ path: String) async throws -> Data { try await perform(path, method: "GET", body: nil) }
    public func prompt(purpose: String, incidentId: String?, sessionId: String?) async throws -> Data {
        struct Body: Encodable { let purpose: String, incidentId: String?, sessionId: String? }
        return try await perform("v1/voice/prompts", method: "POST", body: JSONEncoder().encode(Body(purpose: purpose, incidentId: incidentId, sessionId: sessionId)))
    }
    public func replay(id: String, kind: String) async throws -> Data { try await perform("v1/replays/\(id)/\(kind)", method: "GET", body: nil, maximumBytes: 100*1024*1024) }
    public func delete(_ path: String) async throws { _ = try await perform(path, method: "DELETE", body: nil) }
    public func invalidate() { session.invalidateAndCancel() }
}
public struct Empty: Encodable, Sendable { public init() {} }
public struct CreateSession: Encodable, Sendable {
    public let mode = "demo", consent: Consent, source: CaptureSource
    public let automaticSceneChecks: Bool, speechMonitoring: Bool, phoneMotionTesting: Bool
    public init(consent: Consent, source: CaptureSource, automaticSceneChecks: Bool = false, speechMonitoring: Bool = false, phoneMotionTesting: Bool = false) {
        self.consent = consent
        self.source = source
        self.automaticSceneChecks = automaticSceneChecks
        self.speechMonitoring = speechMonitoring
        self.phoneMotionTesting = phoneMotionTesting
    }
}
public struct TriggerBody: Encodable, Sendable { public let signal: TriggerSignal; public init(_ signal: TriggerSignal) { self.signal = signal } }
