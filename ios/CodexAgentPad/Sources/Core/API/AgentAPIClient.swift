import Foundation

enum AgentAPIError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case server(status: Int, message: String)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Endpoint 无效"
        case .invalidResponse:
            return "agentd 返回了无效响应"
        case .server(let status, let message):
            return "HTTP \(status)：\(message)"
        case .decoding(let error):
            return "解析响应失败：\(error.localizedDescription)"
        }
    }
}

struct AgentAPIClient {
    let endpoint: String
    let token: String

    private var baseURL: URL? {
        URL(string: Self.normalizedEndpoint(endpoint))
    }

    func health() async throws -> HealthResponse {
        try await request(path: "/healthz", method: "GET", requiresAuth: false, body: Optional<Data>.none)
    }

    func version() async throws -> VersionResponse {
        try await request(path: "/api/version", method: "GET", body: Optional<Data>.none)
    }

    func projects() async throws -> [AgentProject] {
        let response: ProjectsResponse = try await request(path: "/api/projects", method: "GET", body: Optional<Data>.none)
        return response.projects
    }

    func sessions(projectID: String? = nil, cursor: String? = nil, limit: Int? = nil) async throws -> [AgentSession] {
        let response: SessionsResponse = try await request(
            path: makePath("/api/sessions", query: [
                "project_id": projectID,
                "cursor": cursor,
                "limit": limit.map(String.init)
            ]),
            method: "GET",
            body: Optional<Data>.none
        )
        return response.sessions
    }

    func session(id: String) async throws -> SessionResponse {
        try await request(path: "/api/sessions/\(id)", method: "GET", body: Optional<Data>.none)
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        let body = try JSONEncoder().encode(payload)
        return try await request(path: "/api/sessions", method: "POST", body: body)
    }

    func stopSession(id: String) async throws {
        let _: EmptyResponse = try await request(path: "/api/sessions/\(id)", method: "DELETE", body: Optional<Data>.none)
    }

    func messages(sessionID: String, before: String? = nil, limit: Int? = nil) async throws -> [CodexHistoryMessage] {
        let response: MessagesResponse = try await request(
            path: makePath("/api/sessions/\(sessionID)/messages", query: [
                "before": before,
                "limit": limit.map(String.init)
            ]),
            method: "GET",
            body: Optional<Data>.none
        )
        return response.messages
    }

    func websocketURL(sessionID: String) throws -> URL {
        guard var components = URLComponents(string: Self.normalizedEndpoint(endpoint)) else {
            throw AgentAPIError.invalidEndpoint
        }
        switch components.scheme {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            throw AgentAPIError.invalidEndpoint
        }
        components.path = "/api/sessions/\(sessionID)/ws"
        guard let url = components.url else {
            throw AgentAPIError.invalidEndpoint
        }
        return url
    }

    private func request<T: Decodable>(path: String, method: String, requiresAuth: Bool = true, body: Data?) async throws -> T {
        guard let baseURL else {
            throw AgentAPIError.invalidEndpoint
        }
        guard let url = makeURL(baseURL: baseURL, path: path) else {
            throw AgentAPIError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        if requiresAuth {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentAPIError.server(status: http.statusCode, message: decodeError(data))
        }
        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw AgentAPIError.decoding(error)
        }
    }

    private func decodeError(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? String {
            return error
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知错误"
    }

    private func makePath(_ path: String, query: [String: String?]) -> String {
        var components = URLComponents()
        components.path = path
        components.queryItems = query.compactMap { key, value in
            guard let value, !value.isEmpty else {
                return nil
            }
            return URLQueryItem(name: key, value: value)
        }
        return components.string ?? path
    }

    private func makeURL(baseURL: URL, path: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        guard let pathComponents = URLComponents(string: normalizedPath) else {
            return nil
        }
        components.path = pathComponents.path
        components.queryItems = pathComponents.queryItems
        return components.url
    }

    static func normalizedEndpoint(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return "http://" + trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = DateParsers.iso8601Fractional.date(from: raw) {
                return date
            }
            if let date = DateParsers.iso8601.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "日期格式无效：\(raw)")
        }
        return decoder
    }()
}

private struct EmptyResponse: Decodable {}

private enum DateParsers {
    static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
