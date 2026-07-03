import Foundation

enum PairingLinkError: LocalizedError, Equatable {
    case unsupportedURL
    case missingEndpoint
    case missingToken
    case expired

    var errorDescription: String? {
        switch self {
        case .unsupportedURL:
            return "连接链接无效"
        case .missingEndpoint:
            return "连接链接缺少地址"
        case .missingToken:
            return "连接链接缺少访问码"
        case .expired:
            return "配对二维码已过期"
        }
    }
}

struct PairingCredentials: Equatable {
    let endpoint: String
    let token: String
}

struct PairingTicket: Equatable {
    let endpoint: String
    let issuedAt: String
    let expiresAt: String
    let pairSignature: String

    var claimRequest: PairingClaimRequest {
        PairingClaimRequest(
            endpoint: endpoint,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            pairSignature: pairSignature
        )
    }
}

struct ConnectionTestStageTiming: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case health
        case version
        case appServerConfig
        case appServerGateway

        var title: String {
            switch self {
            case .health:
                return "基础连通"
            case .version:
                return "鉴权版本"
            case .appServerConfig:
                return "Gateway 配置"
            case .appServerGateway:
                return "app-server 握手"
            }
        }

        var detail: String {
            switch self {
            case .health:
                return "iPad 到 agentd 的 /healthz"
            case .version:
                return "带 Token 访问 /api/version"
            case .appServerConfig:
                return "读取 Mac 端 gateway 配置"
            case .appServerGateway:
                return "WebSocket + JSON-RPC initialize"
            }
        }
    }

    enum Status: Equatable {
        case succeeded
        case failed(String)

        var isFailed: Bool {
            if case .failed = self {
                return true
            }
            return false
        }
    }

    let kind: Kind
    let durationMillis: Int
    let status: Status

    var id: String {
        kind.rawValue
    }
}

struct ConnectionTestReport: Equatable {
    let startedAt: Date
    let totalMillis: Int
    let stages: [ConnectionTestStageTiming]
    let gatewayDiagnostics: ConnectionTestGatewayDiagnostics?
    let gatewayDiagnosticsError: String?

    init(
        startedAt: Date,
        totalMillis: Int,
        stages: [ConnectionTestStageTiming],
        gatewayDiagnostics: ConnectionTestGatewayDiagnostics? = nil,
        gatewayDiagnosticsError: String? = nil
    ) {
        self.startedAt = startedAt
        self.totalMillis = totalMillis
        self.stages = stages
        self.gatewayDiagnostics = gatewayDiagnostics
        self.gatewayDiagnosticsError = gatewayDiagnosticsError
    }

    var slowestStage: ConnectionTestStageTiming? {
        stages.max { lhs, rhs in
            lhs.durationMillis < rhs.durationMillis
        }
    }

    var failedStage: ConnectionTestStageTiming? {
        stages.first { $0.status.isFailed }
    }
}

struct ConnectionTestGatewayDiagnostics: Equatable {
    let capturedAt: Date
    let totalConnectionsDelta: Int
    let failedUpstreamDialsDelta: Int
    let activeConnections: Int
    let upstreamDialMillisMax: Int
    let writeBackMillisMax: Int
    let writeToUpstreamMillisMax: Int
    let rpcLatencyMillisMax: Int
    let rpcOutstandingRequests: Int
    let rpcOutstandingMillisMax: Int
    let relatedConnection: RelayGatewayConnectionStats?
    let latestRPC: RelayGatewayRPCSample?
    let hints: [String]

    static func make(
        baseline: RelayDiagnosticsResponse?,
        snapshot: RelayDiagnosticsResponse,
        gatewayStartedAt: Date
    ) -> ConnectionTestGatewayDiagnostics {
        let gateway = snapshot.appServerGateway
        let relatedConnection = Self.relatedGatewayConnection(
            in: gateway,
            gatewayStartedAt: gatewayStartedAt
        )
        return ConnectionTestGatewayDiagnostics(
            capturedAt: snapshot.generatedAt,
            totalConnectionsDelta: max(0, gateway.totalConnections - (baseline?.appServerGateway.totalConnections ?? gateway.totalConnections)),
            failedUpstreamDialsDelta: max(0, gateway.failedUpstreamDials - (baseline?.appServerGateway.failedUpstreamDials ?? gateway.failedUpstreamDials)),
            activeConnections: gateway.activeConnections,
            upstreamDialMillisMax: gateway.upstreamDialMillisMax,
            writeBackMillisMax: gateway.upstreamToClient.writeMillisMax,
            writeToUpstreamMillisMax: gateway.clientToUpstream.writeMillisMax,
            rpcLatencyMillisMax: gateway.rpc.latencyMillisMax,
            rpcOutstandingRequests: gateway.rpc.outstandingRequests,
            rpcOutstandingMillisMax: gateway.rpc.outstandingMillisMax,
            relatedConnection: relatedConnection,
            latestRPC: relatedConnection?.recentRPC.last ?? gateway.recentRPC.last,
            hints: snapshot.hints
        )
    }

    private static func relatedGatewayConnection(
        in gateway: RelayGatewayStats,
        gatewayStartedAt: Date
    ) -> RelayGatewayConnectionStats? {
        // iPad 和 Mac 时钟正常同步时，优先选本次测试窗口内创建的 gateway 连接；若两端时钟偏差，
        // 退回最近 active/recent 连接，保证现场仍能看到 Mac 侧的最新证据。
        let threshold = gatewayStartedAt.addingTimeInterval(-2)
        let candidates = gateway.activeConnectionDetail + gateway.recentConnections
        if let current = candidates
            .filter({ $0.startedAt >= threshold })
            .max(by: { $0.startedAt < $1.startedAt }) {
            return current
        }
        return gateway.activeConnectionDetail.max(by: { $0.startedAt < $1.startedAt })
            ?? gateway.recentConnections.max(by: { $0.startedAt < $1.startedAt })
    }
}

struct ConnectionTestStageStability: Identifiable, Equatable {
    let kind: ConnectionTestStageTiming.Kind
    let sampleCount: Int
    let failureCount: Int
    let minMillis: Int
    let maxMillis: Int
    let averageMillis: Int

    var id: String {
        kind.rawValue
    }

    var spreadMillis: Int {
        max(0, maxMillis - minMillis)
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var endpoint: String
    @Published var token: String
    @Published var connectionStatus: ConnectionStatus = .idle
    @Published var lastError: String?
    @Published var lastConnectionTestDurationMillis: Int?
    @Published var lastConnectionTestReport: ConnectionTestReport?
    @Published var recentConnectionTestReports: [ConnectionTestReport] = []

    private let endpointKey = "agentd.endpoint"
    private let retiredConnectionModeKey = "agentd.connectionMode"
    private let defaultEndpoint = "http://127.0.0.1:8787"
    private let maxConnectionTestReportHistory = 20
    private let tokenStore = TokenStore()
    private var directRuntime: CodexAppServerSessionRuntime?
    private var directRuntimeIdentity: String?

    init() {
        self.endpoint = UserDefaults.standard.string(forKey: endpointKey) ?? defaultEndpoint
        self.token = tokenStore.load()
        // 当前移动客户端只保留 Codex app-server JSON-RPC 直连链路；旧版本写入的连接模式配置直接清理掉。
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
        // 会继续使用旧 allowlist 缓存，后端扫描根目录变化后移动端仍可能只看到旧项目。
        resetDirectRuntime()
        self.endpoint = normalized
        self.token = token
    }

    @discardableResult
    func validateAndSave(endpoint: String, token: String) async throws -> Bool {
        let normalized = try await validateConnection(endpoint: endpoint, token: token)
        let didChange = normalized != self.endpoint || token != self.token
        guard didChange else {
            // 同一凭据重新验证成功，也要丢弃 direct runtime 的 app-server config 缓存；
            // 用户常用“保存/重新扫码”来拉取 Mac 端最新项目根目录或 allowlist。
            resetDirectRuntime()
            lastError = nil
            return false
        }
        try save(endpoint: normalized, token: token)
        lastError = nil
        return true
    }

    @discardableResult
    func validateAndSavePairingURL(_ url: URL) async throws -> Bool {
        if let ticket = try Self.pairingTicket(from: url) {
            let credentials = try await claimPairing(ticket)
            return try await validateAndSave(endpoint: credentials.endpoint, token: credentials.token)
        }
        let credentials = try Self.pairingCredentials(from: url)
        // 兼容旧版 connect 链接；新版 pair 二维码只携带短期签名票据。
        return try await validateAndSave(endpoint: credentials.endpoint, token: credentials.token)
    }

    func validatePairingURL(_ url: URL) async throws -> PairingCredentials {
        if let ticket = try Self.pairingTicket(from: url) {
            let credentials = try await claimPairing(ticket)
            let normalized = try await validateConnection(endpoint: credentials.endpoint, token: credentials.token)
            return PairingCredentials(endpoint: normalized, token: credentials.token)
        }
        let credentials = try Self.pairingCredentials(from: url)
        // 手动调用时只测试外侧 agentd 连接；首次扫码路径会直接保存，减少一次确认。
        let normalized = try await validateConnection(endpoint: credentials.endpoint, token: credentials.token)
        return PairingCredentials(endpoint: normalized, token: credentials.token)
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
        lastConnectionTestDurationMillis = nil
        lastConnectionTestReport = nil
        recentConnectionTestReports = []
    }

    @discardableResult
    func validateConnection(endpoint: String, token: String) async throws -> String {
        let startedAt = Date()
        var stages: [ConnectionTestStageTiming] = []
        var gatewayDiagnosticsBaseline: RelayDiagnosticsResponse?
        var gatewayDiagnostics: ConnectionTestGatewayDiagnostics?
        var gatewayDiagnosticsError: String?
        connectionStatus = .testing
        lastError = nil
        lastConnectionTestDurationMillis = nil
        lastConnectionTestReport = nil

        func appendStage(_ kind: ConnectionTestStageTiming.Kind, since stageStartedAt: Date, status: ConnectionTestStageTiming.Status) {
            stages.append(ConnectionTestStageTiming(
                kind: kind,
                durationMillis: Self.elapsedMilliseconds(since: stageStartedAt),
                status: status
            ))
        }

        func publishReport() {
            // 诊断快照是为了定位瓶颈，不属于真实业务链路；总耗时只汇总上面几个测试阶段。
            let totalMillis = stages.reduce(0) { $0 + $1.durationMillis }
            let report = ConnectionTestReport(
                startedAt: startedAt,
                totalMillis: totalMillis,
                stages: stages,
                gatewayDiagnostics: gatewayDiagnostics,
                gatewayDiagnosticsError: gatewayDiagnosticsError
            )
            lastConnectionTestDurationMillis = totalMillis
            lastConnectionTestReport = report
            rememberConnectionTestReport(report)
        }

        func captureGatewayDiagnostics(client: AgentAPIClient, gatewayStartedAt: Date) async {
            do {
                let snapshot = try await client.relayDiagnostics()
                gatewayDiagnostics = ConnectionTestGatewayDiagnostics.make(
                    baseline: gatewayDiagnosticsBaseline,
                    snapshot: snapshot,
                    gatewayStartedAt: gatewayStartedAt
                )
                gatewayDiagnosticsError = nil
            } catch {
                gatewayDiagnostics = nil
                gatewayDiagnosticsError = error.localizedDescription
            }
        }

        let normalized = try Self.validatedEndpoint(endpoint)
        let client = AgentAPIClient(endpoint: normalized, token: token)

        let healthStartedAt = Date()
        do {
            _ = try await client.health()
            appendStage(.health, since: healthStartedAt, status: .succeeded)
        } catch {
            appendStage(.health, since: healthStartedAt, status: .failed(error.localizedDescription))
            publishReport()
            throw error
        }

        let versionStartedAt = Date()
        let version: VersionResponse
        do {
            version = try await client.version()
            appendStage(.version, since: versionStartedAt, status: .succeeded)
        } catch {
            appendStage(.version, since: versionStartedAt, status: .failed(error.localizedDescription))
            publishReport()
            throw error
        }

        let configStartedAt = Date()
        let config: CodexAppServerConfigResponse
        do {
            config = try await client.appServerConfig()
            appendStage(.appServerConfig, since: configStartedAt, status: .succeeded)
        } catch {
            appendStage(.appServerConfig, since: configStartedAt, status: .failed(error.localizedDescription))
            publishReport()
            throw error
        }

        gatewayDiagnosticsBaseline = try? await client.relayDiagnostics()

        let gatewayStartedAt = Date()
        do {
            let runtime = CodexAppServerSessionRuntime(endpoint: normalized, token: token, configProvider: { config })
            try await runtime.validateDirectGateway()
            appendStage(.appServerGateway, since: gatewayStartedAt, status: .succeeded)
        } catch {
            appendStage(.appServerGateway, since: gatewayStartedAt, status: .failed(error.localizedDescription))
            await captureGatewayDiagnostics(client: client, gatewayStartedAt: gatewayStartedAt)
            publishReport()
            throw error
        }

        await captureGatewayDiagnostics(client: client, gatewayStartedAt: gatewayStartedAt)
        publishReport()
        connectionStatus = .connected("\(version.version) · direct")
        return normalized
    }

    var connectionTestStageStabilities: [ConnectionTestStageStability] {
        Self.connectionTestStageStabilities(reports: recentConnectionTestReports)
    }

    var mostUnstableConnectionTestStage: ConnectionTestStageStability? {
        connectionTestStageStabilities.max { lhs, rhs in
            if lhs.failureCount != rhs.failureCount {
                return lhs.failureCount < rhs.failureCount
            }
            if lhs.spreadMillis != rhs.spreadMillis {
                return lhs.spreadMillis < rhs.spreadMillis
            }
            return lhs.maxMillis < rhs.maxMillis
        }
    }

    private func rememberConnectionTestReport(_ report: ConnectionTestReport) {
        recentConnectionTestReports.append(report)
        let overflow = recentConnectionTestReports.count - maxConnectionTestReportHistory
        if overflow > 0 {
            recentConnectionTestReports.removeFirst(overflow)
        }
    }

    func testConnection(endpoint: String, token: String) async {
        do {
            _ = try await validateConnection(endpoint: endpoint, token: token)
        } catch {
            connectionStatus = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    static func connectionTestStageStabilities(reports: [ConnectionTestReport]) -> [ConnectionTestStageStability] {
        ConnectionTestStageTiming.Kind.allCases.compactMap { kind in
            let stages = reports.compactMap { report in
                report.stages.first { $0.kind == kind }
            }
            guard !stages.isEmpty else {
                return nil
            }
            let durations = stages.map(\.durationMillis)
            let total = durations.reduce(0, +)
            let failures = stages.filter { stage in
                stage.status.isFailed
            }.count
            return ConnectionTestStageStability(
                kind: kind,
                sampleCount: stages.count,
                failureCount: failures,
                minMillis: durations.min() ?? 0,
                maxMillis: durations.max() ?? 0,
                averageMillis: Int((Double(total) / Double(stages.count)).rounded())
            )
        }
    }

    static func connectionTestDurationText(milliseconds: Int) -> String {
        let milliseconds = max(0, milliseconds)
        if milliseconds < 1_000 {
            return "\(milliseconds) ms"
        }
        if milliseconds < 10_000 {
            return String(format: "%.1f 秒", Double(milliseconds) / 1_000)
        }
        return "\(Int((Double(milliseconds) / 1_000).rounded())) 秒"
    }

    private static func elapsedMilliseconds(since startDate: Date) -> Int {
        let elapsed = Date().timeIntervalSince(startDate)
        return max(0, Int((elapsed * 1_000).rounded()))
    }

    private func claimPairing(_ ticket: PairingTicket) async throws -> PairingCredentials {
        let response = try await AgentAPIClient(endpoint: ticket.endpoint, token: "").claimPairing(ticket.claimRequest)
        return PairingCredentials(
            endpoint: try Self.validatedEndpoint(response.endpoint.isEmpty ? ticket.endpoint : response.endpoint),
            token: response.token
        )
    }

    static func pairingCredentials(from url: URL) throws -> PairingCredentials {
        if try pairingTicket(from: url) != nil {
            throw PairingLinkError.missingToken
        }
        let route = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let allowedSchemes = ["mimiremote", "mimi"]
        // 兼容早期 agentd 二进制输出的 mimi:// 短链接；新版仍以 mimiremote:// 为主。
        guard allowedSchemes.contains(url.scheme?.lowercased() ?? ""),
              route == "pair" || route == "connect"
        else {
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
        let expiresAt = components?.queryItems?.first(where: { $0.name == "expires_at" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !expiresAt.isEmpty {
            guard let expiryDate = pairingDate(from: expiresAt) else {
                throw PairingLinkError.unsupportedURL
            }
            if expiryDate <= Date() {
                throw PairingLinkError.expired
            }
        }
        return PairingCredentials(endpoint: try validatedEndpoint(endpoint), token: token)
    }

    static func pairingTicket(from url: URL) throws -> PairingTicket? {
        let route = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let allowedSchemes = ["mimiremote", "mimi"]
        guard allowedSchemes.contains(url.scheme?.lowercased() ?? ""),
              route == "pair" || route == "connect"
        else {
            throw PairingLinkError.unsupportedURL
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let pairSignature = components?.queryItems?.first(where: { $0.name == "pair_sig" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !pairSignature.isEmpty else {
            return nil
        }
        let endpoint = components?.queryItems?.first(where: { $0.name == "endpoint" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let issuedAt = components?.queryItems?.first(where: { $0.name == "issued_at" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let expiresAt = components?.queryItems?.first(where: { $0.name == "expires_at" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !endpoint.isEmpty else {
            throw PairingLinkError.missingEndpoint
        }
        guard !issuedAt.isEmpty, !expiresAt.isEmpty else {
            throw PairingLinkError.unsupportedURL
        }
        guard let expiryDate = pairingDate(from: expiresAt) else {
            throw PairingLinkError.unsupportedURL
        }
        if expiryDate <= Date() {
            throw PairingLinkError.expired
        }
        return PairingTicket(
            endpoint: try validatedEndpoint(endpoint),
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            pairSignature: pairSignature
        )
    }

    private static func pairingDate(from raw: String) -> Date? {
        if let seconds = TimeInterval(raw) {
            return Date(timeIntervalSince1970: seconds)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
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
        if components.scheme == "http",
           let host = components.host,
           !isAllowedInsecureEndpointHost(host) {
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

    private static func isAllowedInsecureEndpointHost(_ host: String) -> Bool {
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
            // 允许手动填写自建 VPS / 公网 IPv4 中转地址。
            // 仍然拒绝 http://example.com 这类公网域名，建议域名走 HTTPS。
            return 1...223 ~= parts[0]
        }
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
