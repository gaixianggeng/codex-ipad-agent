import Foundation
import os

enum PairingLinkError: LocalizedError, Equatable {
    case unsupportedURL
    case missingEndpoint
    case missingToken
    case expired

    var errorDescription: String? {
        switch self {
        case .unsupportedURL:
            return L10n.text("ui.invalid_connection_link")
        case .missingEndpoint:
            return L10n.text("ui.the_link_is_missing_an_address")
        case .missingToken:
            return L10n.text("ui.the_connection_link_is_missing_the_access_code")
        case .expired:
            return L10n.text("ui.the_pairing_qr_code_has_expired")
        }
    }
}

struct PairingCredentials: Equatable {
    let endpoint: String
    let token: String
    let tailscaleDNSName: String?
    let tailscaleDeviceName: String?

    init(
        endpoint: String,
        token: String,
        tailscaleDNSName: String? = nil,
        tailscaleDeviceName: String? = nil
    ) {
        self.endpoint = endpoint
        self.token = token
        self.tailscaleDNSName = ConnectionProfile.isTailscaleIPEndpoint(endpoint)
            ? ConnectionProfile.normalizedTailscaleDNSName(tailscaleDNSName)
            : nil
        self.tailscaleDeviceName = ConnectionProfile.isTailscaleIPEndpoint(endpoint)
            ? ConnectionProfile.normalizedTailscaleDeviceName(
                tailscaleDeviceName,
                dnsName: self.tailscaleDNSName
            )
            : nil
    }
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
                return L10n.text("ui.basic_connectivity")
            case .version:
                return L10n.text("ui.authentication_version")
            case .appServerConfig:
                return L10n.text("ui.gateway_configuration")
            case .appServerGateway:
                return L10n.text("ui.app_server_handshake")
            }
        }

        var detail: String {
            switch self {
            case .health:
                return L10n.text("ui.ipad_to_agentd_healthz")
            case .version:
                return L10n.text("ui.access_api_version_with_token")
            case .appServerConfig:
                return L10n.text("ui.read_mac_side_gateway_configuration")
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
    let tailscaleNetworkPath: TailscaleNetworkPathResponse?
    let gatewayDiagnostics: ConnectionTestGatewayDiagnostics?
    let gatewayDiagnosticsError: String?

    init(
        startedAt: Date,
        totalMillis: Int,
        stages: [ConnectionTestStageTiming],
        tailscaleNetworkPath: TailscaleNetworkPathResponse? = nil,
        gatewayDiagnostics: ConnectionTestGatewayDiagnostics? = nil,
        gatewayDiagnosticsError: String? = nil
    ) {
        self.startedAt = startedAt
        self.totalMillis = totalMillis
        self.stages = stages
        self.tailscaleNetworkPath = tailscaleNetworkPath
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

/// 单次连接操作中实际尝试过的候选类型。这里只描述已经验证过的地址事实，
/// 不承担候选选择；候选顺序仍完全由 ConnectionProfile.connectionCandidates 决定。
enum ConnectionRouteKind: Hashable {
    case loopback
    case localNetwork
    case tailscaleMagicDNS
    case tailscaleIP
    case secureRemote
    case other

    static func classify(endpoint: String) -> Self {
        let host = URLComponents(string: endpoint)?.host?
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        if HostConnectionEndpointPolicy.isLoopbackEndpoint(endpoint) {
            return .loopback
        }
        if host?.hasSuffix(".ts.net") == true {
            return .tailscaleMagicDNS
        }
        if ConnectionProfile.isTailscaleIPEndpoint(endpoint) {
            return .tailscaleIP
        }
        switch EndpointTransportPolicy.assess(endpoint).status {
        case .allowedPrivateHTTP:
            return .localNetwork
        case .allowedHTTPS:
            return .secureRemote
        case .empty, .invalid, .blockedPublicHTTP:
            return .other
        }
    }

    var diagnosticTitle: String {
        switch self {
        case .loopback:
            return L10n.text("ui.connection_route_this_computer")
        case .localNetwork:
            return L10n.text("ui.connection_route_local_network")
        case .tailscaleMagicDNS:
            return "MagicDNS"
        case .tailscaleIP:
            return L10n.text("ui.connection_route_tailscale_address")
        case .secureRemote:
            return "HTTPS"
        case .other:
            return L10n.text("ui.connection_route_saved_address")
        }
    }
}

/// 失败分类只基于底层错误明确表达的事实。DNS/超时只能归类为解析或可达性失败，
/// 不能据此断言用户是否安装、登录或启用了 Tailscale。
enum ConnectionFailureFact: Equatable {
    case dnsResolutionFailed
    case unreachable
    case identityRequired
    case identityMismatch
    case credentialsRejected
    case protocolOrServer
    case other

    static func classify(_ error: Error) -> Self {
        if isCredentialInvalidatingError(error) {
            return .credentialsRejected
        }
        if let profileError = error as? ConnectionProfileError {
            switch profileError {
            case .installationIdentityRequired:
                return .identityRequired
            case .installationIdentityMismatch:
                return .identityMismatch
            default:
                return .other
            }
        }
        if let connectionError = error as? CodexAppServerConnectionError {
            switch connectionError {
            case .disconnected, .timeout:
                return .unreachable
            case .transport(let underlying):
                return classify(underlying)
            case .notInitialized, .duplicateRequestID, .appServer, .decoding:
                return .protocolOrServer
            }
        }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            if error is AgentAPIError {
                return .protocolOrServer
            }
            return .other
        }
        let code = URLError.Code(rawValue: nsError.code)
        switch code {
        case .cannotFindHost, .dnsLookupFailed:
            return .dnsResolutionFailed
        case .timedOut,
             .cannotConnectToHost,
             .networkConnectionLost,
             .notConnectedToInternet,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .resourceUnavailable,
             .cannotLoadFromNetwork:
            return .unreachable
        default:
            return .other
        }
    }

    var diagnosticTitle: String {
        switch self {
        case .dnsResolutionFailed:
            return L10n.text("ui.connection_failure_dns")
        case .unreachable:
            return L10n.text("ui.connection_failure_unreachable")
        case .identityRequired:
            return L10n.text("ui.connection_failure_identity_required")
        case .identityMismatch:
            return L10n.text("ui.connection_failure_identity_mismatch")
        case .credentialsRejected:
            return L10n.text("ui.connection_failure_credentials")
        case .protocolOrServer:
            return L10n.text("ui.connection_failure_protocol")
        case .other:
            return L10n.text("ui.connection_failure_other")
        }
    }
}

struct ConnectionRouteAttempt: Equatable {
    enum Result: Equatable {
        case succeeded
        case failed(ConnectionFailureFact)

        var diagnosticTitle: String {
            switch self {
            case .succeeded:
                return L10n.text("ui.connection_attempt_succeeded")
            case .failed(let fact):
                return fact.diagnosticTitle
            }
        }
    }

    let endpoint: String
    let routeKind: ConnectionRouteKind
    let result: Result

    init(endpoint: String, result: Result) {
        self.endpoint = AgentAPIClient.normalizedEndpoint(endpoint)
        routeKind = ConnectionRouteKind.classify(endpoint: endpoint)
        self.result = result
    }
}

/// 仅保留当前进程内最近一次候选连接操作的终态，用于轻量提示和可展开诊断。
/// AppStore 在下一次操作开始时会先清空；该值不会写入 Profile 或 UserDefaults。
struct ConnectionAttemptSummary: Equatable {
    enum Outcome: Equatable {
        case connected(activeEndpoint: String)
        case failed
    }

    let attempts: [ConnectionRouteAttempt]
    let outcome: Outcome

    var fallbackMessage: String? {
        guard case .connected(let activeEndpoint) = outcome,
              let preferred = attempts.first?.endpoint,
              AgentAPIClient.normalizedEndpoint(activeEndpoint) != preferred else {
            return nil
        }
        return L10n.text("ui.connection_automatically_used_saved_address")
    }

    var failureGuidance: String? {
        guard outcome == .failed else { return nil }
        let failures = attempts.compactMap { attempt -> ConnectionFailureFact? in
            guard case .failed(let fact) = attempt.result else { return nil }
            return fact
        }
        if failures.contains(.identityMismatch) {
            return L10n.text("ui.connection_identity_mismatch_guidance")
        }
        // 凭据、版本和协议错误已有更精确的底层文案；这里只替换纯可达性失败。
        guard !failures.isEmpty,
              failures.allSatisfy({ $0 == .dnsResolutionFailed || $0 == .unreachable }) else {
            return nil
        }
        let routeKinds = Set(attempts.map(\.routeKind))
        let onlyLocal = routeKinds.allSatisfy { $0 == .loopback || $0 == .localNetwork }
        if onlyLocal {
            return L10n.text("ui.connection_local_network_guidance")
        }
        return L10n.text("ui.connection_conditional_tailscale_guidance")
    }
}

typealias ConnectionRouteProbe = (_ endpoint: String, _ token: String, _ timeout: TimeInterval) async throws -> Void
typealias ConnectionRouteVersionProbe = (_ endpoint: String, _ token: String, _ timeout: TimeInterval) async throws -> VersionResponse
typealias LocalAgentProbe = (_ endpoint: String, _ timeout: TimeInterval) async throws -> Void
typealias LocalAgentPairingClaim = (_ endpoint: String, _ timeout: TimeInterval) async throws -> String
typealias PairingTicketClaim = (_ ticket: PairingTicket) async throws -> PairingCredentials

extension AppStore {
    static func defaultPairingTicketClaim(_ ticket: PairingTicket) async throws -> PairingCredentials {
        let response = try await AgentAPIClient(endpoint: ticket.endpoint, token: "")
            .claimPairing(ticket.claimRequest)
        return PairingCredentials(
            endpoint: try validatedEndpoint(response.endpoint.isEmpty ? ticket.endpoint : response.endpoint),
            token: response.token,
            tailscaleDNSName: response.tailscaleDNSName,
            tailscaleDeviceName: response.tailscaleDeviceName
        )
    }

    func prepareConnectionSettings(
        endpoint: String,
        token: String,
        profileTarget: PreparedConnectionProfileTarget = .currentOrNew(displayName: nil),
        tailscaleDNSName: String? = nil,
        tailscaleDeviceName: String? = nil,
        attemptGeneration: UInt64? = nil
    ) async throws -> PreparedConnectionSettings {
        // Profile 切换与 ticket 配对会在任何 await 前先清旧终态；这里复用同一代，
        // 避免真正进入候选探测时再次 begin，破坏迟到结果 fencing。
        let activeAttemptGeneration = attemptGeneration ?? beginConnectionAttempt()
        let normalizedEndpoint = try Self.validatedEndpoint(endpoint)
        let normalizedDNSName = ConnectionProfile.normalizedTailscaleDNSName(tailscaleDNSName)
        let normalizedDeviceName = ConnectionProfile.normalizedTailscaleDeviceName(
            tailscaleDeviceName,
            dnsName: normalizedDNSName
        )
        let candidates = ConnectionProfile.connectionCandidates(
            endpoint: normalizedEndpoint,
            tailscaleDNSName: normalizedDNSName
        )
        var finalError: Error?
        var attempts: [ConnectionRouteAttempt] = []
        for candidate in candidates {
            do {
                if usesDefaultRouteProbe {
                    let prepared = try await prepareFastHostContext(
                        activeEndpoint: candidate,
                        fallbackEndpoint: normalizedEndpoint,
                        token: token,
                        profileTarget: profileTarget,
                        tailscaleDNSName: normalizedDNSName,
                        tailscaleDeviceName: normalizedDeviceName
                    )
                    attempts.append(ConnectionRouteAttempt(endpoint: candidate, result: .succeeded))
                    // 路由验证成功不代表 Keychain/Profile 已提交；成功摘要由 commit 发布。
                    return prepared.recordingConnectionAttempt(
                        generation: activeAttemptGeneration,
                        attempts: attempts
                    )
                }

                // 测试注入继续复用既有 seam；这里只记录结果，不改变 MIM-39 候选顺序。
                try await routeProbe(candidate, token, routeProbeTimeout)
                attempts.append(ConnectionRouteAttempt(endpoint: candidate, result: .succeeded))
                return PreparedConnectionSettings(
                    endpoint: normalizedEndpoint,
                    activeEndpoint: candidate,
                    token: token,
                    profileTarget: profileTarget,
                    tailscaleDNSName: normalizedDNSName,
                    tailscaleDeviceName: normalizedDeviceName,
                    connectionAttemptGeneration: activeAttemptGeneration,
                    connectionAttempts: attempts
                )
            } catch {
                if Task.isCancelled || error is CancellationError {
                    cancelConnectionAttempt(generation: activeAttemptGeneration)
                    throw error
                }
                attempts.append(ConnectionRouteAttempt(
                    endpoint: candidate,
                    result: .failed(ConnectionFailureFact.classify(error))
                ))
                finalError = error
            }
        }
        finishConnectionAttempt(
            generation: activeAttemptGeneration,
            attempts: attempts,
            outcome: .failed
        )
        throw finalError ?? URLError(.cannotConnectToHost)
    }

    static func defaultConnectionRouteVersionProbe(
        endpoint: String,
        token: String,
        timeout: TimeInterval
    ) async throws -> VersionResponse {
        try await AgentAPIClient(endpoint: endpoint, token: token).version(timeout: min(timeout, 2))
    }

    func validateConnectionCandidateIdentityAndRefreshHostMetadata(
        from routeEndpoint: String,
        profileID: String,
        expectedRevision: UInt64,
        expectedInstallationID: String?,
        profileName: String,
        token: String,
        timeout: TimeInterval,
        versionProbe: ConnectionRouteVersionProbe?
    ) async throws {
        let expectedID = expectedInstallationID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let expectedID, !expectedID.isEmpty, let versionProbe else { return }
        let version = try await versionProbe(routeEndpoint, token, timeout)
        let actualID = version.installationID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let actualID, !actualID.isEmpty else {
            throw ConnectionProfileError.installationIdentityRequired
        }
        guard actualID == expectedID else {
            throw ConnectionProfileError.installationIdentityMismatch(profileName: profileName)
        }
        _ = refreshConnectionProfileHostMetadata(
            profileID: profileID,
            expectedRevision: expectedRevision,
            version: version
        )
    }
}

enum ActiveConnectionRoute: Equatable {
    case configured
    case local

    var statusTitle: String {
        switch self {
        case .configured:
            return "Tailscale"
        case .local:
            return L10n.text("ui.direct_connection_to_this_machine")
        }
    }
}

struct PreparedHostLease: Equatable {
    let endpoint: String
    let installationID: String
    let profileTarget: PreparedConnectionProfileTarget
    let profileRevision: UInt64?
    let tokenFingerprint: String
}

enum HostCredentialWriteReceipt: Sendable {
    case unchanged
    case inserted
    case replaced(previousToken: String)
}

enum HostConnectionEndpointPolicy {
    static var prefersLocalConnectionByDefault: Bool {
#if targetEnvironment(macCatalyst)
        true
#else
        false
#endif
    }

    /// Catalyst 未签名开发包维持既有 loopback 降级；Simulator 仅在 Debug 构建启用，
    /// 确保 TestFlight / App Store 包始终要求可用的系统 Keychain。
    static var allowsDevelopmentEphemeralCredentialFallback: Bool {
#if targetEnvironment(macCatalyst)
        true
#elseif DEBUG && targetEnvironment(simulator)
        true
#else
        false
#endif
    }

    static func isEligibleEphemeralCredentialEndpoint(_ endpoint: String) -> Bool {
        if isLoopbackEndpoint(endpoint) {
            return true
        }
#if DEBUG && targetEnvironment(simulator)
        // Simulator 无法直接访问宿主机 loopback；只放行传输策略已经确认的私网 HTTP，
        // 公网 HTTPS 即使 Keychain 缺 entitlement 也必须失败，避免扩大凭据驻留范围。
        return EndpointTransportPolicy.assess(endpoint).status == .allowedPrivateHTTP
#else
        return false
#endif
    }

    static func isLoopbackEndpoint(_ endpoint: String) -> Bool {
        guard let host = URLComponents(string: endpoint)?.host?.lowercased() else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

/// Keychain 访问串行化到独立 actor。主线程只提交/接收短字符串，不直接参与非当前主机探活的读取。
actor HostCredentialVault {
    private let tokenStore: TokenStore
    private var memoryTokens: [String: String] = [:]

    init(tokenStore: TokenStore) {
        self.tokenStore = tokenStore
    }

    func token(for profileID: String) throws -> String {
        if let cached = memoryTokens[profileID] {
            return cached
        }
        let token = try tokenStore.load(profileID: profileID)
        memoryTokens[profileID] = token
        return token
    }

    /// Keychain 写入与内存缓存必须由同一个 actor 串行提交，避免切换成功后
    /// 一个迟到的 remember/remove Task 把另一台 Mac 的凭据缓存覆盖掉。
    func save(
        _ token: String,
        for profileID: String,
        forcePersistence: Bool = false
    ) throws -> HostCredentialWriteReceipt {
        if !forcePersistence, memoryTokens[profileID] == token {
            // 快速切换读取过目标 Profile 的 Token；未变化时无需再次触发 Keychain I/O。
            return .unchanged
        }
        let previousToken: String
        if !forcePersistence, let cached = memoryTokens[profileID] {
            previousToken = cached
        } else {
            // 临时开发档案转为持久连接时必须重新读取 Keychain，
            // 不能把仅存在于内存的 Token 误判为已经持久化。
            previousToken = try tokenStore.load(profileID: profileID)
        }
        if previousToken == token {
            memoryTokens[profileID] = token
            return .unchanged
        }
        try tokenStore.save(token, profileID: profileID)
        memoryTokens[profileID] = token
        return previousToken.isEmpty ? .inserted : .replaced(previousToken: previousToken)
    }

    /// 未签入 provisioning profile 的 Catalyst / Simulator Debug 包可能无法访问 Keychain。
    /// 受限本地验收连接只保留进程内凭据，重启后必须重新向 agentd 领取。
    func rememberInMemory(_ token: String, for profileID: String) -> HostCredentialWriteReceipt {
        guard let previousToken = memoryTokens.updateValue(token, forKey: profileID) else {
            return .inserted
        }
        return previousToken == token ? .unchanged : .replaced(previousToken: previousToken)
    }

    func rollbackMemory(_ receipt: HostCredentialWriteReceipt, profileID: String) {
        switch receipt {
        case .unchanged:
            return
        case .inserted:
            memoryTokens.removeValue(forKey: profileID)
        case .replaced(let previousToken):
            memoryTokens[profileID] = previousToken
        }
    }

    func forgetMemory(profileID: String) {
        memoryTokens.removeValue(forKey: profileID)
    }

    func rollback(_ receipt: HostCredentialWriteReceipt, profileID: String) throws {
        switch receipt {
        case .unchanged:
            return
        case .inserted:
            try tokenStore.delete(profileID: profileID, allowMissing: true)
            memoryTokens.removeValue(forKey: profileID)
        case .replaced(let previousToken):
            try tokenStore.save(previousToken, profileID: profileID)
            memoryTokens[profileID] = previousToken
        }
    }

    func delete(profileID: String, allowMissing: Bool = true) throws {
        try tokenStore.delete(profileID: profileID, allowMissing: allowMissing)
        memoryTokens.removeValue(forKey: profileID)
    }

    func deleteLegacy(allowMissing: Bool = true) throws {
        try tokenStore.delete(allowMissing: allowMissing)
    }

    func clearMemory() {
        memoryTokens.removeAll(keepingCapacity: false)
    }
}

@MainActor
final class PreparedHostContext {
    let lease: PreparedHostLease
    let expiresAt: Date

    private var runtimeBundle: AppServerRuntimeBundle?
    private var expirationTask: Task<Void, Never>?

    init(
        lease: PreparedHostLease,
        runtimeBundle: AppServerRuntimeBundle,
        expiresAt: Date
    ) {
        self.lease = lease
        self.runtimeBundle = runtimeBundle
        self.expiresAt = expiresAt
        // Task 强持有 context 到 deadline；即使调用方直接丢弃 PreparedConnectionSettings，
        // 候选 Runtime 也会在 8 秒内显式 shutdown，而不是只依赖 deinit。
        expirationTask = Task { [self] in
            let delay = max(0, expiresAt.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await discard()
        }
    }

    deinit {
        expirationTask?.cancel()
    }

    var isConsumed: Bool {
        runtimeBundle == nil
    }

    func validatedRuntimeBundle(
        matching expectedLease: PreparedHostLease,
        now: Date = Date()
    ) throws -> AppServerRuntimeBundle {
        guard now <= expiresAt else {
            throw ConnectionProfileError.preparedContextExpired
        }
        guard lease == expectedLease else {
            throw ConnectionProfileError.preparedContextMismatch
        }
        guard let runtimeBundle else {
            throw ConnectionProfileError.preparedContextConsumed
        }
        return runtimeBundle
    }

    func markConsumed() {
        expirationTask?.cancel()
        expirationTask = nil
        runtimeBundle = nil
    }

    func discard() async {
        guard let runtimeBundle else {
            return
        }
        expirationTask?.cancel()
        expirationTask = nil
        self.runtimeBundle = nil
        await runtimeBundle.shutdownForHostSwitch()
    }
}

struct HostProbeDescriptor {
    let profileID: String
    let profileRevision: UInt64
    let endpoints: [String]
    let token: String
    let expectedInstallationID: String?

    var endpoint: String {
        endpoints.first ?? ""
    }
}

enum HostSwitchSignpost {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.gaixianggeng.mimi",
        category: "HostSwitch"
    )

    static func event(_ name: StaticString) {
        os_signpost(.event, log: log, name: name)
    }

    static func begin(_ name: StaticString) {
        os_signpost(.begin, log: log, name: name)
    }

    static func end(_ name: StaticString) {
        os_signpost(.end, log: log, name: name)
    }
}
