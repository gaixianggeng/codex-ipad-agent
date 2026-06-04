import Foundation

enum ConnectionMode: String, CaseIterable, Identifiable {
    case compat
    case direct

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compat:
            return "兼容模式"
        case .direct:
            return "直连模式"
        }
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var endpoint: String
    @Published var token: String
    @Published var connectionMode: ConnectionMode
    @Published var connectionStatus: ConnectionStatus = .idle
    @Published var lastError: String?

    private let endpointKey = "agentd.endpoint"
    private let connectionModeKey = "agentd.connectionMode"
    private let tokenStore = TokenStore()
    private var directRuntime: CodexAppServerSessionRuntime?
    private var directRuntimeIdentity: String?

    init() {
        self.endpoint = UserDefaults.standard.string(forKey: endpointKey) ?? "http://127.0.0.1:8787"
        self.token = tokenStore.load()
        self.connectionMode = UserDefaults.standard.string(forKey: connectionModeKey)
            .flatMap(ConnectionMode.init(rawValue:)) ?? .compat
    }

    var isConfigured: Bool {
        !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func client() throws -> AgentAPIClient {
        let endpoint = AgentAPIClient.normalizedEndpoint(endpoint)
        guard URL(string: endpoint) != nil else {
            throw AgentAPIError.invalidEndpoint
        }
        return AgentAPIClient(endpoint: endpoint, token: token)
    }

    func makeSessionStoreAPIClient() throws -> any SessionStoreAPIClient {
        switch connectionMode {
        case .compat:
            return try client()
        case .direct:
            let endpoint = AgentAPIClient.normalizedEndpoint(endpoint)
            guard URL(string: endpoint) != nil else {
                throw AgentAPIError.invalidEndpoint
            }
            return CodexAppServerSessionAPIClient(endpoint: endpoint, runtime: runtime(endpoint: endpoint, token: token))
        }
    }

    func makeSessionWebSocketClient() -> any SessionWebSocketClient {
        switch connectionMode {
        case .compat:
            return AgentWebSocketClient()
        case .direct:
            return CodexAppServerSessionWebSocketClient(runtime: runtime(
                endpoint: AgentAPIClient.normalizedEndpoint(endpoint),
                token: token
            ))
        }
    }

    func save(endpoint: String, token: String, connectionMode: ConnectionMode) throws {
        let normalized = AgentAPIClient.normalizedEndpoint(endpoint)
        UserDefaults.standard.set(normalized, forKey: endpointKey)
        UserDefaults.standard.set(connectionMode.rawValue, forKey: connectionModeKey)
        try tokenStore.save(token)
        // “保存并加载”必须重新读取 agentd 的 app-server config；否则 direct runtime
        // 会继续使用旧 allowlist 缓存，后端扫描根目录变化后 iPad 仍可能只看到旧项目。
        resetDirectRuntime()
        self.endpoint = normalized
        self.token = token
        self.connectionMode = connectionMode
    }

    func save(endpoint: String, token: String) throws {
        try save(endpoint: endpoint, token: token, connectionMode: connectionMode)
    }

    func testConnection(endpoint: String, token: String, connectionMode: ConnectionMode) async {
        connectionStatus = .testing
        lastError = nil
        let normalized = AgentAPIClient.normalizedEndpoint(endpoint)
        let client = AgentAPIClient(endpoint: normalized, token: token)
        do {
            _ = try await client.health()
            let version = try await client.version()
            if connectionMode == .direct {
                let runtime = CodexAppServerSessionRuntime(endpoint: normalized, token: token)
                try await runtime.validateDirectGateway()
            }
            connectionStatus = .connected(connectionMode == .direct ? "\(version.version) · direct" : version.version)
        } catch {
            connectionStatus = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    func testConnection(endpoint: String, token: String) async {
        await testConnection(endpoint: endpoint, token: token, connectionMode: connectionMode)
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
