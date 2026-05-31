import Foundation

@MainActor
final class AppStore: ObservableObject {
    @Published var endpoint: String
    @Published var token: String
    @Published var connectionStatus: ConnectionStatus = .idle
    @Published var lastError: String?

    private let endpointKey = "agentd.endpoint"
    private let tokenStore = TokenStore()

    init() {
        self.endpoint = UserDefaults.standard.string(forKey: endpointKey) ?? "http://127.0.0.1:8787"
        self.token = tokenStore.load()
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

    func save(endpoint: String, token: String) throws {
        let normalized = AgentAPIClient.normalizedEndpoint(endpoint)
        UserDefaults.standard.set(normalized, forKey: endpointKey)
        try tokenStore.save(token)
        self.endpoint = normalized
        self.token = token
    }

    func testConnection(endpoint: String, token: String) async {
        connectionStatus = .testing
        lastError = nil
        let client = AgentAPIClient(endpoint: endpoint, token: token)
        do {
            _ = try await client.health()
            let version = try await client.version()
            connectionStatus = .connected(version.version)
        } catch {
            connectionStatus = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }
}
