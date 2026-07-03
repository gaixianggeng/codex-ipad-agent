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

    func claimPairing(_ claim: PairingClaimRequest) async throws -> PairingClaimResponse {
        let body = try JSONEncoder().encode(claim)
        return try await request(path: "/api/pair/claim", method: "POST", requiresAuth: false, body: body)
    }

    func version() async throws -> VersionResponse {
        try await request(path: "/api/version", method: "GET", body: Optional<Data>.none)
    }

    func appServerConfig() async throws -> CodexAppServerConfigResponse {
        try await request(path: "/api/app-server/config", method: "GET", body: Optional<Data>.none)
    }

    func relayDiagnostics() async throws -> RelayDiagnosticsResponse {
        try await request(path: "/api/diagnostics/relay", method: "GET", body: Optional<Data>.none)
    }

    func capabilities(path: String?) async throws -> CapabilityListResponse {
        let body = try JSONEncoder().encode(CapabilityListRequest(path: path))
        return try await request(path: "/api/capabilities/list", method: "POST", body: body)
    }

    func projects() async throws -> [AgentProject] {
        let response: ProjectsResponse = try await request(path: "/api/projects", method: "GET", body: Optional<Data>.none)
        return response.projects
    }

    func resolveWorkspace(path: String) async throws -> AgentWorkspace {
        let body = try JSONEncoder().encode(WorkspaceResolveRequest(path: path))
        let response: WorkspaceResolveResponse = try await request(path: "/api/workspaces/resolve", method: "POST", body: body)
        return response.workspace
    }

    func createWorktree(path: String, name: String?, base: String?, branch: String?) async throws -> WorktreeCreateResponse {
        let body = try JSONEncoder().encode(WorktreeCreateRequest(path: path, name: name, base: base, branch: branch))
        return try await request(path: "/api/worktrees/create", method: "POST", body: body)
    }

    func worktreeBranches(path: String) async throws -> WorktreeBranchListResponse {
        let body = try JSONEncoder().encode(WorktreeBranchListRequest(path: path))
        return try await request(path: "/api/worktrees/branches", method: "POST", body: body)
    }

    func listWorktrees() async throws -> [WorktreeListItem] {
        let response: WorktreeListResponse = try await request(path: "/api/worktrees/list", method: "GET", body: Optional<Data>.none)
        return response.worktrees
    }

    func deleteWorktree(path: String, force: Bool = false) async throws -> WorktreeDeleteResponse {
        let body = try JSONEncoder().encode(WorktreeDeleteRequest(path: path, force: force))
        return try await request(path: "/api/worktrees/delete", method: "POST", body: body)
    }

    func pruneMissingWorktrees() async throws -> WorktreePruneResponse {
        try await request(path: "/api/worktrees/prune", method: "POST", body: Optional<Data>.none)
    }

    func listDirectories(path: String) async throws -> DirectoryListResponse {
        let body = try JSONEncoder().encode(DirectoryListRequest(path: path))
        return try await request(path: "/api/directories/list", method: "POST", body: body)
    }

    func readFile(path: String) async throws -> FileReadResponse {
        let body = try JSONEncoder().encode(FileReadRequest(path: path))
        return try await request(path: "/api/files/read", method: "POST", body: body)
    }

    func commandActions(path: String) async throws -> [AgentCommandAction] {
        let body = try JSONEncoder().encode(CommandActionListRequest(path: path))
        let response: CommandActionListResponse = try await request(path: "/api/actions/list", method: "POST", body: body)
        return response.actions
    }

    func runCommandAction(path: String, id: String, confirmed: Bool) async throws -> CommandActionRunResponse {
        let body = try JSONEncoder().encode(CommandActionRunRequest(path: path, id: id, confirmed: confirmed))
        return try await request(path: "/api/actions/run", method: "POST", body: body)
    }

    func gitStatus(path: String) async throws -> GitStatusResponse {
        let body = try JSONEncoder().encode(GitStatusRequest(path: path))
        return try await request(path: "/api/git/status", method: "POST", body: body)
    }

    func gitAction(path: String, action: GitActionKind, files: [String]) async throws -> GitStatusResponse {
        let body = try JSONEncoder().encode(GitActionRequest(path: path, action: action, files: files))
        return try await request(path: "/api/git/action", method: "POST", body: body)
    }

    func gitPatchAction(path: String, action: GitActionKind, patch: String) async throws -> GitStatusResponse {
        let body = try JSONEncoder().encode(GitActionRequest(path: path, action: action, patch: patch))
        return try await request(path: "/api/git/action", method: "POST", body: body)
    }

    func gitCommit(path: String, message: String) async throws -> GitStatusResponse {
        let body = try JSONEncoder().encode(GitCommitRequest(path: path, message: message))
        return try await request(path: "/api/git/commit", method: "POST", body: body)
    }

    func gitPush(path: String, remote: String?) async throws -> GitPushResponse {
        let body = try JSONEncoder().encode(GitPushRequest(path: path, remote: remote))
        return try await request(path: "/api/git/push", method: "POST", body: body)
    }

    func gitCreatePullRequest(path: String, title: String, body prBody: String, draft: Bool) async throws -> GitPullRequestResponse {
        let body = try JSONEncoder().encode(GitPullRequestRequest(path: path, title: title, body: prBody, draft: draft))
        return try await request(path: "/api/git/pull-request", method: "POST", body: body)
    }

    func gitPullRequestStatus(path: String) async throws -> GitPullRequestStatusResponse {
        let body = try JSONEncoder().encode(GitPullRequestStatusRequest(path: path))
        return try await request(path: "/api/git/pull-request/status", method: "POST", body: body)
    }

    func transcribeVoice(
        filename: String,
        contentType: String,
        audioData: Data,
        language: String?,
        prompt: String?
    ) async throws -> VoiceTranscriptionResponse {
        let body = try JSONEncoder().encode(VoiceTranscriptionRequest(
            filename: filename,
            contentType: contentType,
            audioBase64: audioData.base64EncodedString(),
            language: language,
            prompt: prompt
        ))
        return try await request(path: "/api/voice/transcribe", method: "POST", body: body, timeout: 60)
    }

    private func request<T: Decodable>(
        path: String,
        method: String,
        requiresAuth: Bool = true,
        body: Data?,
        timeout: TimeInterval = 20
    ) async throws -> T {
        guard let baseURL else {
            throw AgentAPIError.invalidEndpoint
        }
        guard let url = makeURL(baseURL: baseURL, path: path) else {
            throw AgentAPIError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
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
