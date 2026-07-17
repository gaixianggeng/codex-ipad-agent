import Foundation

protocol CredentialInvalidatingError {
    var invalidatesCredentials: Bool { get }
}

func isCredentialInvalidatingError(_ error: Error) -> Bool {
    (error as? any CredentialInvalidatingError)?.invalidatesCredentials == true
}

enum AgentAPIError: LocalizedError, CredentialInvalidatingError {
    case invalidEndpoint
    case insecurePublicHTTPEndpoint(host: String)
    case invalidResponse
    case credentialsInvalid(status: Int)
    case server(status: Int, message: String)
    case decoding(Error)

    var invalidatesCredentials: Bool {
        switch self {
        case .credentialsInvalid:
            return true
        case .server(let status, let message):
            return Self.isCredentialRejection(status: status, message: message, authenticationChallenge: nil)
        case .invalidEndpoint, .insecurePublicHTTPEndpoint, .invalidResponse, .decoding:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "连接地址无效。请输入 Mac 助手地址，例如 http://100.64.0.1:8787；地址中不要包含路径、账号或查询参数。"
        case .insecurePublicHTTPEndpoint(let host):
            return "已阻止公网 HTTP 地址 \(host)。为避免访问码和 Codex 内容被明文传输，请改用 HTTPS，或在 Mac 运行 agentd pair 后扫描 Tailscale 二维码。"
        case .invalidResponse:
            return "agentd 返回了无效响应"
        case .credentialsInvalid:
            return ConnectionTerminationStatus.credentialsInvalid.message
        case .server(let status, let message):
            return "HTTP \(status)：\(message)"
        case .decoding(let error):
            return "解析响应失败：\(error.localizedDescription)"
        }
    }

    static func isCredentialRejection(
        status: Int,
        message: String,
        authenticationChallenge: String?
    ) -> Bool {
        if status == 401 {
            return true
        }
        guard status == 403 else {
            return false
        }
        if authenticationChallenge?.lowercased().contains("bearer") == true {
            return true
        }
        // agentd 自身的目录、操作审批也会返回 403，不能把这些业务拒绝误报为访问码失效。
        // 这里只接受反向代理和鉴权层常见的通用认证文本。
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "forbidden"
            || normalized == "unauthorized"
            || normalized.contains("invalid token")
            || normalized.contains("invalid bearer")
            || normalized.contains("authentication required")
            || normalized.contains("credential")
            || normalized.contains("访问码失效")
            || normalized.contains("认证失败")
            || normalized.contains("鉴权失败")
    }
}

struct EndpointTransportAssessment: Equatable {
    enum Status: Equatable {
        case empty
        case invalid
        case allowedPrivateHTTP
        case allowedHTTPS
        case blockedPublicHTTP
    }

    let status: Status
    let host: String?
    let normalizedEndpoint: String?

    var isAllowed: Bool {
        status == .allowedPrivateHTTP || status == .allowedHTTPS
    }

    var title: String {
        switch status {
        case .empty:
            return "等待输入连接地址"
        case .invalid:
            return "连接地址格式无效"
        case .allowedPrivateHTTP:
            return "私网 HTTP 地址可连接"
        case .allowedHTTPS:
            return "HTTPS 地址可连接"
        case .blockedPublicHTTP:
            return "已阻止公网 HTTP"
        }
    }

    var guidance: String {
        switch status {
        case .empty:
            return "推荐扫描 Mac 上 agentd pair 生成的 Tailscale 二维码。"
        case .invalid:
            return "请输入主机和端口，例如 http://100.64.0.1:8787；不要附加路径、账号或查询参数。"
        case .allowedPrivateHTTP:
            return "HTTP 仅允许 loopback、Tailscale、局域网私有地址和 .local 主机；不要把 agentd 端口映射到公网。"
        case .allowedHTTPS:
            return "公网域名只允许通过 HTTPS 连接。"
        case .blockedPublicHTTP:
            let displayHost = host.map { "（\($0)）" } ?? ""
            return "公网 HTTP\(displayHost) 会明文传输访问码和 Codex 内容。请改用 HTTPS，或在 Mac 运行 agentd pair 后扫描 Tailscale 二维码。"
        }
    }
}

enum EndpointTransportPolicy {
    static func assess(_ raw: String) -> EndpointTransportAssessment {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return EndpointTransportAssessment(status: .empty, host: nil, normalizedEndpoint: nil)
        }

        let candidate = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard var components = URLComponents(string: candidate),
              let rawScheme = components.scheme,
              let rawHost = components.host,
              !rawHost.isEmpty
        else {
            return EndpointTransportAssessment(status: .invalid, host: nil, normalizedEndpoint: nil)
        }

        let scheme = rawScheme.lowercased()
        guard scheme == "http" || scheme == "https" else {
            return EndpointTransportAssessment(status: .invalid, host: rawHost, normalizedEndpoint: nil)
        }
        components.scheme = scheme
        if components.path == "/" {
            components.path = ""
        }
        guard components.path.isEmpty,
              components.query == nil,
              components.fragment == nil,
              components.user == nil,
              components.password == nil
        else {
            return EndpointTransportAssessment(status: .invalid, host: rawHost, normalizedEndpoint: nil)
        }

        if scheme == "https" {
            guard let url = components.url else {
                return EndpointTransportAssessment(status: .invalid, host: rawHost, normalizedEndpoint: nil)
            }
            return EndpointTransportAssessment(
                status: .allowedHTTPS,
                host: normalizedHost(rawHost),
                normalizedEndpoint: url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            )
        }
        guard isAllowedInsecureHost(rawHost) else {
            return EndpointTransportAssessment(
                status: .blockedPublicHTTP,
                host: normalizedHost(rawHost),
                normalizedEndpoint: nil
            )
        }
        // agentd 的约定端口是 8787。私网 HTTP 未显式填写端口时自动补齐，
        // 避免在 Mac 上输入 127.0.0.1 后被 URLSession 静默发送到 80 端口。
        if components.port == nil {
            components.port = 8787
        }
        guard let url = components.url else {
            return EndpointTransportAssessment(status: .invalid, host: rawHost, normalizedEndpoint: nil)
        }
        return EndpointTransportAssessment(
            status: .allowedPrivateHTTP,
            host: normalizedHost(rawHost),
            normalizedEndpoint: url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        )
    }

    static func validatedEndpoint(_ raw: String) throws -> String {
        let assessment = assess(raw)
        switch assessment.status {
        case .allowedPrivateHTTP, .allowedHTTPS:
            guard let endpoint = assessment.normalizedEndpoint else {
                throw AgentAPIError.invalidEndpoint
            }
            return endpoint
        case .blockedPublicHTTP:
            throw AgentAPIError.insecurePublicHTTPEndpoint(host: assessment.host ?? "未知主机")
        case .empty, .invalid:
            throw AgentAPIError.invalidEndpoint
        }
    }

    static func validatedURL(_ raw: String) throws -> URL {
        let endpoint = try validatedEndpoint(raw)
        guard let url = URL(string: endpoint) else {
            throw AgentAPIError.invalidEndpoint
        }
        return url
    }

    private static func isAllowedInsecureHost(_ host: String) -> Bool {
        let value = normalizedHost(host)
        guard !value.isEmpty else {
            return false
        }
        if value == "localhost" || value == "::1" || value.hasSuffix(".local") || value.hasSuffix(".ts.net") {
            return true
        }
        if value.contains(":") && (value.hasPrefix("fe80:") || value.hasPrefix("fc") || value.hasPrefix("fd")) {
            return true
        }
        let parts = value.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ 0...255 ~= $0 }) else {
            return false
        }
        switch parts[0] {
        case 10, 127:
            return true
        case 100:
            return 64...127 ~= parts[1]
        case 169:
            return parts[1] == 254
        case 172:
            return 16...31 ~= parts[1]
        case 192:
            return parts[1] == 168
        default:
            return false
        }
    }

    private static func normalizedHost(_ host: String) -> String {
        host.trimmingCharacters(in: CharacterSet(charactersIn: "[]").union(.whitespacesAndNewlines)).lowercased()
    }
}

struct AgentAPIClient {
    let endpoint: String
    let token: String
    private let session: URLSession

    init(endpoint: String, token: String, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.token = token
        self.session = session
    }

    func health(timeout: TimeInterval = 20) async throws -> HealthResponse {
        try await request(
            path: "/healthz",
            method: "GET",
            requiresAuth: false,
            body: Optional<Data>.none,
            timeout: timeout
        )
    }

    func claimPairing(_ claim: PairingClaimRequest) async throws -> PairingClaimResponse {
        let body = try JSONEncoder().encode(claim)
        return try await request(path: "/api/pair/claim", method: "POST", requiresAuth: false, body: body)
    }

    func claimLocalPairing(timeout: TimeInterval = 2) async throws -> PairingClaimResponse {
        try await request(
            path: "/api/pair/local",
            method: "POST",
            requiresAuth: false,
            headers: ["X-Mimi-Local-Pairing": "1"],
            body: Optional<Data>.none,
            timeout: timeout
        )
    }

    func version() async throws -> VersionResponse {
        try await request(path: "/api/version", method: "GET", body: Optional<Data>.none)
    }

    func appServerConfig(timeout: TimeInterval = 20) async throws -> CodexAppServerConfigResponse {
        try await request(
            path: "/api/app-server/config",
            method: "GET",
            body: Optional<Data>.none,
            timeout: timeout
        )
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

    func previewWorktreeCleanup() async throws -> WorktreeCleanupResponse {
        let body = try JSONEncoder().encode(WorktreeCleanupRequest.preview)
        return try await request(path: "/api/worktrees/cleanup", method: "POST", body: body)
    }

    func executeWorktreeCleanup(paths: [String], planID: String) async throws -> WorktreeCleanupResponse {
        // 执行请求固定带 dry_run=false + confirm=true，不提供 force 或绕过 blocker 的参数。
        let body = try JSONEncoder().encode(WorktreeCleanupRequest.confirmed(paths: paths, planID: planID))
        return try await request(path: "/api/worktrees/cleanup", method: "POST", body: body)
    }

    func listDirectories(path: String) async throws -> DirectoryListResponse {
        let body = try JSONEncoder().encode(DirectoryListRequest(path: path))
        return try await request(path: "/api/directories/list", method: "POST", body: body)
    }

    func readFile(path: String) async throws -> FileReadResponse {
        let body = try JSONEncoder().encode(FileReadRequest(path: path))
        return try await request(path: "/api/files/read", method: "POST", body: body)
    }

    func readHistoryMedia(id: String) async throws -> FileReadResponse {
        let encodedID = Self.percentEncodedPathComponent(id)
        return try await request(path: "/api/app-server/history-media/\(encodedID)", method: "GET", body: Optional<Data>.none)
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

    func gitQuickPublish(path: String, message: String, remote: String?, confirmed: Bool) async throws -> GitQuickPublishResponse {
        let body = try JSONEncoder().encode(GitQuickPublishRequest(
            path: path,
            message: message,
            remote: remote,
            confirmed: confirmed
        ))
        return try await request(path: "/api/git/quick-publish", method: "POST", body: body, timeout: 90)
    }

    func gitTestFlightStatus(path: String) async throws -> GitTestFlightStatusResponse {
        let body = try JSONEncoder().encode(GitTestFlightStatusRequest(path: path))
        return try await request(path: "/api/git/testflight/status", method: "POST", body: body, timeout: 20)
    }

    func gitTestFlightRun(path: String, whatToTest: String, confirmed: Bool) async throws -> GitTestFlightStatusResponse {
        let body = try JSONEncoder().encode(GitTestFlightRunRequest(
            path: path,
            whatToTest: whatToTest,
            confirmed: confirmed
        ))
        return try await request(path: "/api/git/testflight/run", method: "POST", body: body, timeout: 20)
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
        language: String?
    ) async throws -> VoiceTranscriptionResponse {
        let body = try JSONEncoder().encode(VoiceTranscriptionRequest(
            filename: filename,
            contentType: contentType,
            audioBase64: audioData.base64EncodedString(),
            language: language
        ))
        return try await request(path: "/api/voice/transcribe", method: "POST", body: body, timeout: 60)
    }

    private func request<T: Decodable>(
        path: String,
        method: String,
        requiresAuth: Bool = true,
        headers: [String: String] = [:],
        body: Data?,
        timeout: TimeInterval = 20
    ) async throws -> T {
        // ATS 为兼容 Tailscale 裸 IP 需要允许 HTTP；每次真正发请求前仍由应用层策略重新校验，避免未来调用点绕过设置页。
        let baseURL = try EndpointTransportPolicy.validatedURL(endpoint)
        guard let url = makeURL(baseURL: baseURL, path: path) else {
            throw AgentAPIError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if requiresAuth {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = decodeError(data)
            if AgentAPIError.isCredentialRejection(
                status: http.statusCode,
                message: message,
                authenticationChallenge: http.value(forHTTPHeaderField: "WWW-Authenticate")
            ) {
                throw AgentAPIError.credentialsInvalid(status: http.statusCode)
            }
            throw AgentAPIError.server(status: http.statusCode, message: message)
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

    private static func percentEncodedPathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
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
