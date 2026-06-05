import Foundation

enum PairingLinkError: LocalizedError, Equatable {
    case unsupportedURL
    case missingEndpoint
    case missingToken

    var errorDescription: String? {
        switch self {
        case .unsupportedURL:
            return "配对链接无效"
        case .missingEndpoint:
            return "配对链接缺少 Endpoint"
        case .missingToken:
            return "配对链接缺少 Token"
        }
    }
}

struct PairingCredentials: Equatable {
    let endpoint: String
    let token: String
}

@MainActor
final class AppStore: ObservableObject {
    @Published var endpoint: String
    @Published var token: String
    @Published var connectionStatus: ConnectionStatus = .idle
    @Published var lastError: String?

    private let endpointKey = "agentd.endpoint"
    private let retiredConnectionModeKey = "agentd.connectionMode"
    private let defaultEndpoint = "http://127.0.0.1:8787"
    private let tokenStore = TokenStore()
    private var directRuntime: CodexAppServerSessionRuntime?
    private var directRuntimeIdentity: String?

    init() {
        self.endpoint = UserDefaults.standard.string(forKey: endpointKey) ?? defaultEndpoint
        self.token = tokenStore.load()
        // 当前 iPad 客户端只保留 Codex app-server JSON-RPC 直连链路；旧版本写入的连接模式配置直接清理掉。
        UserDefaults.standard.removeObject(forKey: retiredConnectionModeKey)
    }

    var isConfigured: Bool {
        !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func client() throws -> AgentAPIClient {
        let endpoint = try Self.validatedEndpoint(endpoint)
        return AgentAPIClient(endpoint: endpoint, token: token)
    }

    func makeSessionStoreAPIClient() throws -> any SessionStoreAPIClient {
        let endpoint = try Self.validatedEndpoint(endpoint)
        return CodexAppServerSessionAPIClient(runtime: runtime(endpoint: endpoint, token: token))
    }

    func makeSessionWebSocketClient() -> any SessionWebSocketClient {
        CodexAppServerSessionWebSocketClient(runtime: runtime(
            endpoint: AgentAPIClient.normalizedEndpoint(endpoint),
            token: token
        ))
    }

    func save(endpoint: String, token: String) throws {
        let normalized = try Self.validatedEndpoint(endpoint)
        UserDefaults.standard.set(normalized, forKey: endpointKey)
        UserDefaults.standard.removeObject(forKey: retiredConnectionModeKey)
        try tokenStore.save(token)
        // “保存并加载”必须重新读取 agentd 的 app-server config；否则 direct runtime
        // 会继续使用旧 allowlist 缓存，后端扫描根目录变化后 iPad 仍可能只看到旧项目。
        resetDirectRuntime()
        self.endpoint = normalized
        self.token = token
    }

    func validateAndSave(endpoint: String, token: String) async throws {
        let normalized = try await validateConnection(endpoint: endpoint, token: token)
        try save(endpoint: normalized, token: token)
        lastError = nil
    }

    func validateAndSavePairingURL(_ url: URL) async throws {
        let credentials = try Self.pairingCredentials(from: url)
        // 配对链接只写入 agentd 外侧访问 token；app-server upstream token 仍只保存在 Mac 本机配置里。
        try await validateAndSave(endpoint: credentials.endpoint, token: credentials.token)
    }

    func clearPairing() throws {
        UserDefaults.standard.removeObject(forKey: endpointKey)
        UserDefaults.standard.removeObject(forKey: retiredConnectionModeKey)
        try tokenStore.delete(allowMissing: true)
        resetDirectRuntime()
        endpoint = defaultEndpoint
        token = ""
        connectionStatus = .idle
        lastError = nil
    }

    @discardableResult
    func validateConnection(endpoint: String, token: String) async throws -> String {
        connectionStatus = .testing
        lastError = nil
        let normalized = try Self.validatedEndpoint(endpoint)
        let client = AgentAPIClient(endpoint: normalized, token: token)
        _ = try await client.health()
        let version = try await client.version()
        let runtime = CodexAppServerSessionRuntime(endpoint: normalized, token: token)
        try await runtime.validateDirectGateway()
        connectionStatus = .connected("\(version.version) · direct")
        return normalized
    }

    func testConnection(endpoint: String, token: String) async {
        do {
            _ = try await validateConnection(endpoint: endpoint, token: token)
        } catch {
            connectionStatus = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    static func pairingCredentials(from url: URL) throws -> PairingCredentials {
        let route = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard url.scheme?.lowercased() == "codexagentpad", route == "pair" else {
            throw PairingLinkError.unsupportedURL
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let endpoint = components?.queryItems?.first(where: { $0.name == "endpoint" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = components?.queryItems?.first(where: { $0.name == "token" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !endpoint.isEmpty else {
            throw PairingLinkError.missingEndpoint
        }
        guard !token.isEmpty else {
            throw PairingLinkError.missingToken
        }
        return PairingCredentials(endpoint: try validatedEndpoint(endpoint), token: token)
    }

    static func validatedEndpoint(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentAPIError.invalidEndpoint
        }
        let candidate: String
        if trimmed.contains("://") {
            candidate = trimmed
        } else {
            candidate = "http://" + trimmed
        }
        guard var components = URLComponents(string: candidate),
              components.scheme == "http" || components.scheme == "https",
              components.host?.isEmpty == false
        else {
            throw AgentAPIError.invalidEndpoint
        }
        if components.path == "/" {
            components.path = ""
        }
        guard components.path.isEmpty,
              components.query == nil,
              components.fragment == nil,
              components.user == nil,
              components.password == nil
        else {
            throw AgentAPIError.invalidEndpoint
        }
        guard let url = components.url else {
            throw AgentAPIError.invalidEndpoint
        }
        return url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func runtime(endpoint: String, token: String) -> CodexAppServerSessionRuntime {
        let identity = "\(endpoint)\n\(token)"
        if let directRuntime, directRuntimeIdentity == identity {
            return directRuntime
        }
        let runtime = CodexAppServerSessionRuntime(endpoint: endpoint, token: token)
        directRuntime = runtime
        directRuntimeIdentity = identity
        return runtime
    }

    private func resetDirectRuntime() {
        directRuntime = nil
        directRuntimeIdentity = nil
    }
}
