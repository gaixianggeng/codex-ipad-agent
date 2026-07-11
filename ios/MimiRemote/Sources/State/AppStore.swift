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

struct PreparedConnectionSettings: Equatable {
    let endpoint: String
    let fallbackEndpoint: String
    let activeEndpoint: String
    let token: String
}

enum ConnectionRouteSelectionError: LocalizedError {
    case unavailable(lastError: Error?)

    var errorDescription: String? {
        switch self {
        case .unavailable(let lastError):
            if let lastError {
                return "首选和备用连接都不可用：\(lastError.localizedDescription)"
            }
            return "首选和备用连接都不可用"
        }
    }
}

typealias ConnectionRouteProbe = (_ endpoint: String, _ token: String, _ timeout: TimeInterval) async throws -> Void

@MainActor
final class AppStore: ObservableObject {
    @Published var endpoint: String
    @Published var fallbackEndpoint: String
    @Published private(set) var activeEndpoint: String
    @Published private(set) var connectionGeneration = 0
    @Published var token: String
    @Published var connectionStatus: ConnectionStatus = .idle
    @Published var lastError: String?
    @Published var lastConnectionTestDurationMillis: Int?
    @Published var lastConnectionTestReport: ConnectionTestReport?
    @Published var recentConnectionTestReports: [ConnectionTestReport] = []

    private let endpointKey = "agentd.endpoint"
    private let fallbackEndpointKey = "agentd.fallbackEndpoint"
    private let retiredConnectionModeKey = "agentd.connectionMode"
    private let defaultEndpoint = "http://127.0.0.1:8787"
    private let maxConnectionTestReportHistory = 20
    private let defaults: UserDefaults
    private let tokenStore = TokenStore()
    private let routeProbeTimeout: TimeInterval
    private let routeProbe: ConnectionRouteProbe
    private var isConnectionPreflightRunning = false
    private var activeRuntimeBundle: AppServerRuntimeBundle?
    private var activeRuntimeIdentity: String?
#if DEBUG
    @Published private var debugWorkbenchBypassEnabled = false
    private let debugLaunchConfiguration = DebugLaunchConfiguration.current()
#endif

    init(
        defaults: UserDefaults = .standard,
        routeProbeTimeout: TimeInterval = 5,
        routeProbe: ConnectionRouteProbe? = nil
    ) {
        self.defaults = defaults
        self.routeProbeTimeout = routeProbeTimeout
        self.routeProbe = routeProbe ?? Self.defaultConnectionRouteProbe

        var initialEndpoint = defaults.string(forKey: endpointKey) ?? defaultEndpoint
        var initialFallbackEndpoint = defaults.string(forKey: fallbackEndpointKey) ?? ""
        var initialToken = tokenStore.load()
#if DEBUG
        // Debug 启动参数只影响本次内存态，避免把本地调试 token 写进 Keychain 或带进 Release 流程。
        if let debugEndpoint = debugLaunchConfiguration.endpoint,
           let normalizedEndpoint = try? Self.validatedEndpoint(debugEndpoint) {
            initialEndpoint = normalizedEndpoint
            initialFallbackEndpoint = ""
        }
        if let debugToken = debugLaunchConfiguration.token {
            initialToken = debugToken
        }
#endif
        initialEndpoint = (try? Self.validatedEndpoint(initialEndpoint)) ?? defaultEndpoint
        if let normalizedFallback = try? Self.validatedOptionalEndpoint(initialFallbackEndpoint),
           normalizedFallback != initialEndpoint {
            initialFallbackEndpoint = normalizedFallback
        } else {
            initialFallbackEndpoint = ""
        }
        self.endpoint = initialEndpoint
        self.fallbackEndpoint = initialFallbackEndpoint
        self.activeEndpoint = initialEndpoint
        self.token = initialToken
#if DEBUG
        debugWorkbenchBypassEnabled = debugLaunchConfiguration.opensWorkbenchWithoutPairing
#endif
        // 当前移动客户端只保留 Codex app-server JSON-RPC 直连链路；旧版本写入的连接模式配置直接清理掉。
        defaults.removeObject(forKey: retiredConnectionModeKey)
    }

    var isConfigured: Bool {
        !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isUsingFallbackEndpoint: Bool {
        !fallbackEndpoint.isEmpty && activeEndpoint == fallbackEndpoint
    }

    var activeConnectionRouteTitle: String {
        isUsingFallbackEndpoint ? "公网备用" : "首选链路"
    }

    var canEnterWorkbench: Bool {
        if isConfigured {
            return true
        }
#if DEBUG
        return debugWorkbenchBypassEnabled
#else
        return false
#endif
    }

#if DEBUG
    func enterDebugWorkbenchWithoutPairing() {
        debugWorkbenchBypassEnabled = true
    }

    var shouldSeedDebugWorkbenchUI: Bool {
        debugLaunchConfiguration.seedsWorkbenchUI
    }
#endif

    func client() throws -> AgentAPIClient {
        let endpoint = try Self.validatedEndpoint(activeEndpoint)
        return AgentAPIClient(endpoint: endpoint, token: token)
    }

    func makeSessionStoreAPIClient() throws -> any SessionStoreAPIClient {
        let endpoint = try Self.validatedEndpoint(activeEndpoint)
        return CodexAppServerRuntimeRoutingSessionAPIClient(bundle: runtimeBundle(endpoint: endpoint, token: token))
    }

    func makeSessionWebSocketClient() -> any SessionWebSocketClient {
        MultiRuntimeSessionWebSocketClient(bundle: runtimeBundle(
            endpoint: AgentAPIClient.normalizedEndpoint(activeEndpoint),
            token: token
        ))
    }

    func makeSessionWebSocketClient(for session: AgentSession) -> any SessionWebSocketClient {
        let bundle = runtimeBundle(
            endpoint: AgentAPIClient.normalizedEndpoint(activeEndpoint),
            token: token
        )
        bundle.routes.remember(session)
        return MultiRuntimeSessionWebSocketClient(bundle: bundle)
    }

    func prepareConnectionSettings(
        endpoint: String,
        fallbackEndpoint: String,
        token: String
    ) async throws -> PreparedConnectionSettings {
        let normalizedEndpoint = try Self.validatedEndpoint(endpoint)
        let normalizedFallback = try Self.validatedOptionalEndpoint(fallbackEndpoint)
        let candidates = try Self.connectionCandidates(
            endpoint: normalizedEndpoint,
            fallbackEndpoint: normalizedFallback,
            activeEndpoint: normalizedEndpoint,
            preferPrimary: true
        )

        var lastError: Error?
        for candidate in candidates {
            do {
                // 先用短超时验证真实 REST + WebSocket 链路，避免首选地址断网时等待默认 20 秒
                // 才开始测试公网备用入口；通过后再跑完整诊断并生成用户可见报告。
                try await routeProbe(candidate, token, routeProbeTimeout)
                let selected = try await validateConnection(endpoint: candidate, token: token)
                lastError = nil
                return PreparedConnectionSettings(
                    endpoint: normalizedEndpoint,
                    fallbackEndpoint: normalizedFallback == normalizedEndpoint ? "" : normalizedFallback,
                    activeEndpoint: selected,
                    token: token
                )
            } catch {
                lastError = error
            }
        }
        throw ConnectionRouteSelectionError.unavailable(lastError: lastError)
    }

    func preparePairingURL(_ url: URL) async throws -> PreparedConnectionSettings {
        if let ticket = try Self.pairingTicket(from: url) {
            let credentials = try await claimPairing(ticket)
            return try await prepareConnectionSettings(
                endpoint: credentials.endpoint,
                fallbackEndpoint: "",
                token: credentials.token
            )
        }
        let credentials = try Self.pairingCredentials(from: url)
        // 配对链接只签名首选地址，不能沿用上一台 Mac 的备用地址，否则可能把新 Token 发给旧服务器。
        return try await prepareConnectionSettings(
            endpoint: credentials.endpoint,
            fallbackEndpoint: "",
            token: credentials.token
        )
    }

    @discardableResult
    func commitConnectionSettings(_ prepared: PreparedConnectionSettings) throws -> Bool {
        let normalizedEndpoint = try Self.validatedEndpoint(prepared.endpoint)
        let normalizedFallback = try Self.validatedOptionalEndpoint(prepared.fallbackEndpoint)
        let normalizedActive = try Self.validatedEndpoint(prepared.activeEndpoint)
        let candidates = try Self.connectionCandidates(
            endpoint: normalizedEndpoint,
            fallbackEndpoint: normalizedFallback,
            activeEndpoint: normalizedActive,
            preferPrimary: true
        )
        guard candidates.contains(normalizedActive) else {
            throw AgentAPIError.invalidEndpoint
        }

        let storedFallback = normalizedFallback == normalizedEndpoint ? "" : normalizedFallback
        let didChange = normalizedEndpoint != endpoint ||
            storedFallback != fallbackEndpoint ||
            prepared.token != token

        try tokenStore.save(prepared.token)
        defaults.set(normalizedEndpoint, forKey: endpointKey)
        if storedFallback.isEmpty {
            defaults.removeObject(forKey: fallbackEndpointKey)
        } else {
            defaults.set(storedFallback, forKey: fallbackEndpointKey)
        }
        defaults.removeObject(forKey: retiredConnectionModeKey)

        endpoint = normalizedEndpoint
        fallbackEndpoint = storedFallback
        token = prepared.token
        activeEndpoint = normalizedActive
        // 每次提交都开启新的连接代次。即使地址没变，也要清掉旧 config/allowlist 缓存。
        connectionGeneration += 1
        resetDirectRuntime()
        lastError = nil
        return didChange
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
        defaults.removeObject(forKey: endpointKey)
        defaults.removeObject(forKey: fallbackEndpointKey)
        defaults.removeObject(forKey: retiredConnectionModeKey)
        try tokenStore.delete(allowMissing: true)
        resetDirectRuntime()
        endpoint = defaultEndpoint
        fallbackEndpoint = ""
        activeEndpoint = defaultEndpoint
        connectionGeneration += 1
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

    func testConnection(endpoint: String, fallbackEndpoint: String, token: String) async {
        do {
            _ = try await prepareConnectionSettings(
                endpoint: endpoint,
                fallbackEndpoint: fallbackEndpoint,
                token: token
            )
        } catch {
            connectionStatus = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    /// 用已保存的连接信息做轻量真实链路探测，让设置页不必等用户手动点“测试连接”才显示状态。
    @discardableResult
    func preflightConnection(force: Bool = false) async -> Bool {
        guard isConfigured else {
            connectionStatus = .idle
            return false
        }
        if !force, case .connected = connectionStatus {
            return true
        }
        // RootView 和设置页可能同时触发；只保留一次探测，避免重复建立 WebSocket。
        guard !isConnectionPreflightRunning else {
            return false
        }
        isConnectionPreflightRunning = true
        defer { isConnectionPreflightRunning = false }

        connectionStatus = .testing
        lastError = nil

        do {
            let candidates = try Self.connectionCandidates(
                endpoint: endpoint,
                fallbackEndpoint: fallbackEndpoint,
                activeEndpoint: activeEndpoint,
                preferPrimary: true
            )
            var latestError: Error?
            for candidate in candidates {
                do {
                    try await routeProbe(candidate, token, routeProbeTimeout)
                    _ = try activateConnectionRoute(candidate)
                    connectionStatus = .connected(activeConnectionRouteTitle)
                    lastError = nil
                    return true
                } catch {
                    latestError = error
                }
            }
            throw ConnectionRouteSelectionError.unavailable(lastError: latestError)
        } catch {
            if Task.isCancelled || error is CancellationError {
                connectionStatus = .idle
                return false
            }
            connectionStatus = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            return false
        }
    }

    func prepareReachableRoute(preferPrimary: Bool) async throws -> String {
        let candidates = try Self.connectionCandidates(
            endpoint: endpoint,
            fallbackEndpoint: fallbackEndpoint,
            activeEndpoint: activeEndpoint,
            preferPrimary: preferPrimary
        )
        // 单地址模式维持原行为，不在每次回前台时额外做一次 WebSocket 探测。
        guard candidates.count > 1 else {
            return candidates[0]
        }

        var lastError: Error?
        for candidate in candidates {
            do {
                try await routeProbe(candidate, token, routeProbeTimeout)
                return candidate
            } catch {
                lastError = error
            }
        }
        throw ConnectionRouteSelectionError.unavailable(lastError: lastError)
    }

    @discardableResult
    func activateConnectionRoute(_ selectedEndpoint: String) throws -> Bool {
        let normalized = try Self.validatedEndpoint(selectedEndpoint)
        let candidates = try Self.connectionCandidates(
            endpoint: endpoint,
            fallbackEndpoint: fallbackEndpoint,
            activeEndpoint: activeEndpoint,
            preferPrimary: true
        )
        guard candidates.contains(normalized) else {
            throw AgentAPIError.invalidEndpoint
        }
        guard normalized != activeEndpoint else {
            return false
        }

        activeEndpoint = normalized
        connectionGeneration += 1
        resetDirectRuntime()
        lastError = nil
        return true
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

    static func connectionCandidates(
        endpoint: String,
        fallbackEndpoint: String,
        activeEndpoint: String,
        preferPrimary: Bool
    ) throws -> [String] {
        let primary = try validatedEndpoint(endpoint)
        let fallback = try validatedOptionalEndpoint(fallbackEndpoint)
        var configured = [primary]
        if !fallback.isEmpty && fallback != primary {
            configured.append(fallback)
        }

        guard !preferPrimary,
              let active = try? validatedEndpoint(activeEndpoint),
              configured.contains(active) else {
            return configured
        }
        return [active] + configured.filter { $0 != active }
    }

    static func validatedOptionalEndpoint(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        return try validatedEndpoint(trimmed)
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

    private static func defaultConnectionRouteProbe(
        endpoint: String,
        token: String,
        timeout: TimeInterval
    ) async throws {
        let client = AgentAPIClient(endpoint: endpoint, token: token)
        let config = try await client.appServerConfig(timeout: timeout)
        let runtime = CodexAppServerSessionRuntime(
            endpoint: endpoint,
            token: token,
            requestTimeout: timeout,
            configProvider: { config }
        )
        // 同时验证控制面和 WebSocket，避免 /healthz 可用但真实 Codex 通道不可用时误选该地址。
        try await runtime.validateDirectGateway()
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

    private func runtimeBundle(endpoint: String, token: String) -> AppServerRuntimeBundle {
        let identity = "\(endpoint)\n\(token)"
        if activeRuntimeIdentity == identity, let bundle = activeRuntimeBundle {
            return bundle
        }
        let bundle = AppServerRuntimeBundle(endpoint: endpoint, token: token)
        activeRuntimeIdentity = identity
        activeRuntimeBundle = bundle
        return bundle
    }

    private func resetDirectRuntime() {
        activeRuntimeIdentity = nil
        activeRuntimeBundle = nil
    }
}

#if DEBUG
private struct DebugLaunchConfiguration {
    let opensWorkbenchWithoutPairing: Bool
    let seedsWorkbenchUI: Bool
    let endpoint: String?
    let token: String?

    static func current(processInfo: ProcessInfo = .processInfo) -> DebugLaunchConfiguration {
        let arguments = processInfo.arguments
        let environment = processInfo.environment
        return DebugLaunchConfiguration(
            opensWorkbenchWithoutPairing: arguments.contains("--debug-skip-pairing")
                || boolValue(environment["MIMI_DEBUG_SKIP_PAIRING"]),
            seedsWorkbenchUI: arguments.contains("--debug-seed-ui")
                || boolValue(environment["MIMI_DEBUG_SEED_UI"]),
            endpoint: argumentValue(named: "--debug-endpoint", in: arguments)
                ?? environment["MIMI_DEBUG_ENDPOINT"],
            token: argumentValue(named: "--debug-token", in: arguments)
                ?? environment["MIMI_DEBUG_TOKEN"]
        )
    }

    private static func argumentValue(named name: String, in arguments: [String]) -> String? {
        let inlinePrefix = "\(name)="
        if let inlineValue = arguments.first(where: { $0.hasPrefix(inlinePrefix) }) {
            let value = String(inlineValue.dropFirst(inlinePrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        guard let index = arguments.firstIndex(of: name) else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex),
              !arguments[valueIndex].hasPrefix("--") else {
            return nil
        }
        let value = arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func boolValue(_ rawValue: String?) -> Bool {
        switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y", "on":
            return true
        default:
            return false
        }
    }
}
#endif
