import Foundation

struct Backend {
    struct Assessment: Decodable {
        let summary: String
        let checkInRecommended: Bool
    }

    struct Receipt: Decodable {
        let status: String
        let callId: String
        let location: String
    }

    private struct Frames: Encodable {
        let consent = true
        let assessCollapse = true
        let description = "Ordered first-person video frames sampled from Meta glasses."
        let imageDataUrls: [String]
    }

    private struct Incident: Encodable {
        let id: String
        let trigger: String
        let context: String?
    }

    private let endpoint = Bundle.main.object(forInfoDictionaryKey: "RayGuardianBackendURL") as? String
    private let token = Bundle.main.object(forInfoDictionaryKey: "RayGuardianBackendToken") as? String

    var configured: Bool { baseURL != nil && !(token ?? "").isEmpty }

    func assess(_ frames: [String]) async throws -> Assessment {
        try await post("v1/analyze", body: Frames(imageDataUrls: frames), timeout: 45)
    }

    func dispatch(id: UUID, trigger: String, context: String?) async throws -> Receipt {
        let receipt: Receipt = try await post("v1/simulated-dispatch", body: Incident(
            id: id.uuidString.lowercased(), trigger: trigger, context: context.map { String($0.prefix(1000)) }
        ), timeout: 8)
        guard receipt.status == "simulated-accepted" else { throw BackendError.invalidResponse }
        return receipt
    }

    private var baseURL: URL? {
        guard let endpoint, let url = URL(string: endpoint), url.host != nil else { return nil }
        #if DEBUG
        if url.scheme == "http" { return url }
        #endif
        return url.scheme == "https" ? url : nil
    }

    private func post<Response: Decodable, Body: Encodable>(_ path: String, body: Body, timeout: TimeInterval) async throws -> Response {
        guard let baseURL, let token, !token.isEmpty else { throw BackendError.unconfigured }
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request, delegate: NoRedirect())
        guard let response = response as? HTTPURLResponse else { throw BackendError.invalidResponse }
        guard response.statusCode == 200 else { throw BackendError.http(response.statusCode) }
        guard data.count <= 64 * 1024 else { throw BackendError.invalidResponse }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private enum BackendError: LocalizedError {
        case unconfigured, invalidResponse, http(Int)
        var errorDescription: String? {
            switch self {
            case .unconfigured: "Set the backend URL and development token in Local.xcconfig."
            case .invalidResponse: "The Ray Guardian backend returned an unexpected response."
            case .http(let status): "The Ray Guardian backend returned HTTP \(status)."
            }
        }
    }
}
