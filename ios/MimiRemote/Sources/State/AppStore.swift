import Foundation
import CryptoKit

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

typealias ConnectionRouteProbe = (_ endpoint: String, _ token: String, _ timeout: TimeInterval) async throws -> Void
typealias LocalAgentProbe = (_ endpoint: String, _ timeout: TimeInterval) async throws -> Void
typealias LocalAgentPairingClaim = (_ endpoint: String, _ timeout: TimeInterval) async throws -> String

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

@MainActor
final class AppStore: ObservableObject {
    static let connectionProfileDisplayNameLimit = 48

    private enum AutomaticSettingsConnectionTestState {
        case pending
        case running
        case completed
    }

    @Published var endpoint: String
    @Published private(set) var connectionProfiles: [ConnectionProfile]
    @Published private(set) var activeConnectionProfileID: String?
    @Published private(set) var connectionGeneration = 0
    @Published private(set) var activeHostState: ActiveHostState
    @Published var token: String
    @Published var connectionStatus: ConnectionStatus = .idle
    @Published private(set) var connectionTermination: ConnectionTerminationStatus?
    @Published var lastError: String?
    @Published var lastConnectionTestDurationMillis: Int?
    @Published var lastConnectionTestReport: ConnectionTestReport?
    @Published var recentConnectionTestReports: [ConnectionTestReport] = []
    @Published private(set) var localAgentDetected = false
    @Published private(set) var activeConnectionRoute: ActiveConnectionRoute = .configured

    private let endpointKey = "agentd.endpoint"
    private static let profilesKey = "agentd.connectionProfiles.v2"
    private static let legacyProfilesKey = "agentd.connectionProfiles.v1"
    private static let activeProfileIDKey = "agentd.activeConnectionProfileID.v1"
    private let retiredFallbackEndpointKey = "agentd.fallbackEndpoint"
    private let retiredConnectionModeKey = "agentd.connectionMode"
    private let defaultEndpoint = "http://127.0.0.1:8787"
    private let localAgentEndpoint = "http://127.0.0.1:8787"
    private let maxConnectionTestReportHistory = 20
    private let defaults: UserDefaults
    private let tokenStore: TokenStore
    private let credentialVault: HostCredentialVault
    private let routeProbeTimeout: TimeInterval
    private let prefersLocalConnection: Bool
    private let localAgentProbe: LocalAgentProbe
    private let localAgentPairingClaim: LocalAgentPairingClaim
    private let routeProbe: ConnectionRouteProbe
    private let usesDefaultRouteProbe: Bool
    private var isConnectionPreflightRunning = false
    private var automaticSettingsConnectionTestState: AutomaticSettingsConnectionTestState = .pending
    private var localAgentProbeTask: Task<Bool, Never>?
    private var activeRouteEndpoint: String?
    private var activeRuntimeBundle: AppServerRuntimeBundle?
    private var activeRuntimeIdentity: String?
    private var credentialSuspensionTask: Task<Void, Never>?
    private var credentialLifecycleGeneration: UInt64 = 0
#if DEBUG
    @Published private var debugWorkbenchBypassEnabled = false
    private let debugLaunchConfiguration = DebugLaunchConfiguration.current()
#endif

    init(
        defaults: UserDefaults = .standard,
        tokenStore: TokenStore = TokenStore(),
        routeProbeTimeout: TimeInterval = 5,
        prefersLocalConnection: Bool? = nil,
        localAgentProbe: LocalAgentProbe? = nil,
        localAgentPairingClaim: LocalAgentPairingClaim? = nil,
        routeProbe: ConnectionRouteProbe? = nil
    ) {
        self.defaults = defaults
        self.tokenStore = tokenStore
        credentialVault = HostCredentialVault(tokenStore: tokenStore)
        self.routeProbeTimeout = routeProbeTimeout
        self.prefersLocalConnection = prefersLocalConnection ?? Self.isRunningOnMacCatalyst
        self.localAgentProbe = localAgentProbe ?? Self.defaultLocalAgentProbe
        self.localAgentPairingClaim = localAgentPairingClaim ?? Self.defaultLocalAgentPairingClaim
        self.routeProbe = routeProbe ?? Self.defaultConnectionRouteProbe
        usesDefaultRouteProbe = routeProbe == nil

        var initialProfiles = Self.loadConnectionProfiles(from: defaults)
        if defaults.data(forKey: Self.profilesKey) == nil,
           !initialProfiles.isEmpty,
           let migratedProfiles = try? JSONEncoder().encode(initialProfiles) {
            defaults.set(migratedProfiles, forKey: Self.profilesKey)
        }
        var initialActiveProfileID = defaults.string(forKey: Self.activeProfileIDKey)
        var initialEndpoint = defaults.string(forKey: endpointKey) ?? defaultEndpoint
        var initialToken = ""

        if let activeProfileID = initialActiveProfileID,
           let activeProfile = initialProfiles.first(where: { $0.id == activeProfileID }),
           let profileToken = try? tokenStore.load(profileID: activeProfileID),
           !profileToken.isEmpty {
            initialEndpoint = activeProfile.endpoint
            initialToken = profileToken
        } else if initialProfiles.isEmpty {
            // 稳定 V2 冷启动只读 active profile account；只有确实没有 Profile 时才读一次 legacy，
            // 避免保存 5 台 Mac 后把 Keychain 读取次数带进首屏关键路径。
            initialToken = tokenStore.load()
            if initialToken.isEmpty {
                initialActiveProfileID = nil
            } else {
                // 旧版本只有一个 endpoint + `agentd-token`。先把 Token 写入新的独立 account，
                // 成功后才发布档案元数据；任一步失败都继续使用旧内存态和旧 Keychain 项。
                let normalizedEndpoint = (try? Self.validatedEndpoint(initialEndpoint)) ?? defaultEndpoint
                let migratedProfile = ConnectionProfile(
                    id: UUID().uuidString,
                    displayName: Self.defaultProfileDisplayName(endpoint: normalizedEndpoint),
                    endpoint: normalizedEndpoint,
                    lastSuccessfulAt: nil
                )
                do {
                    let encodedProfiles = try JSONEncoder().encode([migratedProfile])
                    try tokenStore.save(initialToken, profileID: migratedProfile.id)
                    defaults.set(encodedProfiles, forKey: Self.profilesKey)
                    defaults.set(encodedProfiles, forKey: Self.legacyProfilesKey)
                    defaults.set(migratedProfile.id, forKey: Self.activeProfileIDKey)
                    initialProfiles = [migratedProfile]
                    initialActiveProfileID = migratedProfile.id
                    // 新档案已完整可恢复后再清理 legacy；删除失败只会留下冗余 Keychain 项，
                    // 不会让当前连接或新档案失效。
                    try? tokenStore.delete(allowMissing: true)
                } catch {
                    initialProfiles = []
                    initialActiveProfileID = nil
                }
            }
        } else {
            // 已存在档案时，即使 legacy item 因旧迁移清理失败而残留，也绝不能重新迁移并覆盖档案列表。
            // 当前档案 Token 不可读时先退出 active 状态，让用户显式重试或重新配对。
            initialActiveProfileID = nil
        }
#if DEBUG
        // Debug 启动参数只影响本次内存态，避免把本地调试 token 写进 Keychain 或带进 Release 流程。
        if let debugEndpoint = debugLaunchConfiguration.endpoint,
           let normalizedEndpoint = try? Self.validatedEndpoint(debugEndpoint) {
            initialEndpoint = normalizedEndpoint
        }
        if let debugToken = debugLaunchConfiguration.token {
            initialToken = debugToken
        }
        if debugLaunchConfiguration.endpoint != nil || debugLaunchConfiguration.token != nil {
            initialActiveProfileID = nil
        }
#endif
        initialEndpoint = (try? Self.validatedEndpoint(initialEndpoint)) ?? defaultEndpoint
        self.endpoint = initialEndpoint
        self.token = initialToken
        connectionProfiles = initialProfiles
        activeConnectionProfileID = initialActiveProfileID
        let initialProfile = initialProfiles.first { $0.id == initialActiveProfileID }
        let initialProfileID = initialProfile?.id ?? initialActiveProfileID ?? "legacy"
        activeHostState = ActiveHostState(
            scope: HostScope(
                profileID: initialProfileID,
                installationID: initialProfile?.installationID ?? Self.unboundInstallationID(profileID: initialProfileID),
                generation: 0
            ),
            endpoint: initialEndpoint,
            displayName: initialProfile?.displayName ?? Self.defaultProfileDisplayName(endpoint: initialEndpoint),
            committedAt: Date()
        )
#if DEBUG
        debugWorkbenchBypassEnabled = debugLaunchConfiguration.opensWorkbenchWithoutPairing
#endif
        // 当前客户端只保留一个 Tailscale 地址；网络直连、Peer Relay 与 DERP 切换统一交给 Tailscale。
        // 启动即清理旧公网备用地址，避免升级后继续保留已下线入口或敏感公网配置。
        defaults.removeObject(forKey: retiredFallbackEndpointKey)
        defaults.removeObject(forKey: retiredConnectionModeKey)
    }

    var isConfigured: Bool {
        let hasCredentials = !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasCredentials else { return false }
#if DEBUG
        if debugLaunchConfiguration.endpoint != nil || debugLaunchConfiguration.token != nil {
            return true
        }
#endif
        // 迁移失败且尚无档案时继续允许旧单连接工作；一旦已经有档案，只有成功读取
        // 当前档案专属 Token 才能进入工作台，不能把残留 legacy Token 当成 active 凭据。
        return connectionProfiles.isEmpty || activeConnectionProfile != nil
    }

    var activeConnectionProfile: ConnectionProfile? {
        guard let activeConnectionProfileID else { return nil }
        return connectionProfiles.first { $0.id == activeConnectionProfileID }
    }

    /// `endpoint` 始终保留档案里的规范地址，用于通知、缓存和跨设备身份；真实网络请求在
    /// Catalyst 检测到同机 agentd 后临时走 loopback，避免把同一台 Mac 拆成两套本地数据。
    var connectionEndpoint: String {
        activeRouteEndpoint ?? endpoint
    }

    var isUsingLocalConnection: Bool {
        activeConnectionRoute == .local
    }

    /// 通知路由优先使用持久化 profile ID；legacy/debug 单连接才退回规范 endpoint 的 SHA-256。
    /// 哈希仅用于同机比对，避免把 endpoint 明文写进系统通知数据库。
    var notificationRoutingProfileID: String {
        if let activeConnectionProfileID,
           !activeConnectionProfileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return activeConnectionProfileID
        }
        let normalizedEndpoint = AgentAPIClient.normalizedEndpoint(endpoint)
        let digest = SHA256.hash(data: Data(normalizedEndpoint.utf8))
        return "endpoint-sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    var connectionProfileSettingsModel: ConnectionProfileSettingsModel {
        ConnectionProfileSettingsModel(
            profiles: connectionProfiles,
            activeProfileID: activeConnectionProfileID
        )
    }

    var activeHostScope: HostScope {
        activeHostState.scope
    }

    /// 只为主机选择器生成探活描述；Token 读取在独立 actor 中执行。
    /// await 返回后再次核对 revision，避免设置页编辑期间把旧凭据发向新地址。
    func hostProbeDescriptor(profileID: String) async throws -> HostProbeDescriptor {
        guard let profile = connectionProfiles.first(where: { $0.id == profileID }) else {
            throw ConnectionProfileError.notFound
        }
        let capturedRevision = profile.revision
        let token = try await credentialVault.token(for: profileID)
        guard let current = connectionProfiles.first(where: { $0.id == profileID }),
              current.revision == capturedRevision,
              current.endpoint == profile.endpoint else {
            throw CancellationError()
        }
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConnectionProfileError.missingToken
        }
        return HostProbeDescriptor(
            profileID: profile.id,
            profileRevision: profile.revision,
            endpoint: profile.endpoint,
            token: token,
            expectedInstallationID: profile.installationID
        )
    }

    /// 进入后台时同时清空 Vault、公开内存 Token 与复用 Runtime。
    /// Profile 元数据仍在，回前台只恢复当前 Profile，不会触碰其它 Mac。
    func suspendCredentialsForBackground() {
        credentialLifecycleGeneration &+= 1
        let runtimeBundle = activeRuntimeBundle
        activeRuntimeBundle = nil
        activeRuntimeIdentity = nil
        token = ""
        let vault = credentialVault
        credentialSuspensionTask = Task {
            await vault.clearMemory()
            await runtimeBundle?.shutdownForHostSwitch()
        }
    }

    /// SessionStore 恢复任何 REST/WS 之前先取回当前 Profile Token，避免后台清理后
    /// 使用空凭据触发一次无意义的 401 或创建半初始化 Runtime。
    func restoreCredentialsForForeground() async throws {
        let lifecycleGeneration = credentialLifecycleGeneration
        let suspensionTask = credentialSuspensionTask
        await suspensionTask?.value
        if credentialLifecycleGeneration == lifecycleGeneration {
            credentialSuspensionTask = nil
        }
        guard let profileID = activeConnectionProfileID,
              connectionProfiles.contains(where: { $0.id == profileID }) else {
            return
        }
        let restoredToken = try await credentialVault.token(for: profileID)
        guard !restoredToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConnectionProfileError.missingToken
        }
        // await 期间若发生连接提交，旧 Profile 的 Token 不得覆盖新主机。
        guard activeConnectionProfileID == profileID else {
            throw CancellationError()
        }
        token = restoredToken
    }

    var requiresRePairing: Bool {
        connectionTermination == .credentialsInvalid
    }

    func markCredentialsInvalid() {
        let termination = ConnectionTerminationStatus.credentialsInvalid
        connectionTermination = termination
        connectionStatus = .failed(termination.message)
        lastError = termination.message
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

    var shouldSeedDebugQueuedTurnsUI: Bool {
        debugLaunchConfiguration.seedsQueuedTurnsUI
    }
#endif

    func client() throws -> AgentAPIClient {
        let endpoint = try Self.validatedEndpoint(connectionEndpoint)
        return AgentAPIClient(endpoint: endpoint, token: token)
    }

    func makeSessionStoreAPIClient() throws -> any SessionStoreAPIClient {
        let endpoint = try Self.validatedEndpoint(connectionEndpoint)
        return CodexAppServerRuntimeRoutingSessionAPIClient(bundle: runtimeBundle(endpoint: endpoint, token: token))
    }

    func makeSessionWebSocketClient() -> any SessionWebSocketClient {
        MultiRuntimeSessionWebSocketClient(bundle: runtimeBundle(
            endpoint: AgentAPIClient.normalizedEndpoint(connectionEndpoint),
            token: token
        ))
    }

    func makeSessionWebSocketClient(for session: AgentSession) -> any SessionWebSocketClient {
        let bundle = runtimeBundle(
            endpoint: AgentAPIClient.normalizedEndpoint(connectionEndpoint),
            token: token
        )
        bundle.routes.remember(session)
        return MultiRuntimeSessionWebSocketClient(bundle: bundle)
    }

    func prepareConnectionSettings(
        endpoint: String,
        token: String,
        profileTarget: PreparedConnectionProfileTarget = .currentOrNew(displayName: nil)
    ) async throws -> PreparedConnectionSettings {
        let normalizedEndpoint = try Self.validatedEndpoint(endpoint)
        if usesDefaultRouteProbe {
            return try await prepareFastHostContext(
                endpoint: normalizedEndpoint,
                token: token,
                profileTarget: profileTarget
            )
        }

        // 测试和兼容注入仍保留原 routeProbe seam，但不再在快速入口后重复执行完整 diagnostics。
        // 设置页“连接测速”继续显式调用 validateConnection。
        try await routeProbe(normalizedEndpoint, token, routeProbeTimeout)
        return PreparedConnectionSettings(endpoint: normalizedEndpoint, token: token, profileTarget: profileTarget)
    }

    func prepareNewConnectionProfile(
        endpoint: String,
        token: String,
        displayName: String
    ) async throws -> PreparedConnectionSettings {
        try await prepareConnectionSettings(
            endpoint: endpoint,
            token: token,
            profileTarget: .newProfile(
                id: UUID().uuidString,
                displayName: Self.normalizedProfileDisplayName(displayName, endpoint: endpoint)
            )
        )
    }

    func prepareConnectionProfileSwitch(id: String) async throws -> PreparedConnectionSettings {
        guard let profile = connectionProfiles.first(where: { $0.id == id }) else {
            throw ConnectionProfileError.notFound
        }
        let profileToken = try await credentialVault.token(for: id)
        guard !profileToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConnectionProfileError.missingToken
        }
        return try await prepareConnectionSettings(
            endpoint: profile.endpoint,
            token: profileToken,
            profileTarget: .existingProfile(id: id)
        )
    }

    func preparePairingURL(_ url: URL) async throws -> PreparedConnectionSettings {
        if let ticket = try Self.pairingTicket(from: url) {
            let credentials = try await claimPairing(ticket)
            return try await prepareConnectionSettings(
                endpoint: credentials.endpoint,
                token: credentials.token
            )
        }
        let credentials = try Self.pairingCredentials(from: url)
        return try await prepareConnectionSettings(
            endpoint: credentials.endpoint,
            token: credentials.token
        )
    }

    func prepareNewPairingURL(_ url: URL, displayName: String) async throws -> PreparedConnectionSettings {
        let prepared = try await preparePairingURL(url)
        return PreparedConnectionSettings(
            endpoint: prepared.endpoint,
            token: prepared.token,
            profileTarget: .newProfile(
                id: UUID().uuidString,
                displayName: Self.normalizedProfileDisplayName(displayName, endpoint: prepared.endpoint)
            ),
            validatedAt: prepared.validatedAt,
            installationID: prepared.installationID,
            hostContext: prepared.hostContext
        )
    }

    @discardableResult
    func commitConnectionSettings(_ prepared: PreparedConnectionSettings) async throws -> Bool {
        let normalizedEndpoint = try Self.validatedEndpoint(prepared.endpoint)
        let installationID = Self.normalizedInstallationID(prepared.installationID)
        let preparedLease = installationID.map {
            PreparedHostLease(
                endpoint: normalizedEndpoint,
                installationID: $0,
                profileTarget: prepared.profileTarget,
                profileRevision: profileRevision(for: prepared.profileTarget),
                tokenFingerprint: Self.tokenFingerprint(prepared.token)
            )
        }
        let candidateRuntime: AppServerRuntimeBundle?
        if let hostContext = prepared.hostContext {
            guard let preparedLease else {
                throw ConnectionProfileError.preparedContextMismatch
            }
            candidateRuntime = try hostContext.validatedRuntimeBundle(matching: preparedLease)
        } else {
            candidateRuntime = nil
        }
        let targetProfile: ConnectionProfile
        switch prepared.profileTarget {
        case .currentOrNew(let displayName):
            if let activeConnectionProfileID,
               let current = connectionProfiles.first(where: { $0.id == activeConnectionProfileID }) {
                try Self.validateInstallationIdentity(
                    actual: installationID,
                    expected: current.installationID,
                    profileName: current.displayName
                )
                try rejectDuplicateInstallation(
                    installationID,
                    excludingProfileID: current.id
                )
                targetProfile = ConnectionProfile(
                    id: current.id,
                    displayName: Self.normalizedProfileDisplayName(displayName ?? current.displayName, endpoint: normalizedEndpoint),
                    endpoint: normalizedEndpoint,
                    lastSuccessfulAt: prepared.validatedAt,
                    installationID: installationID ?? current.installationID,
                    revision: current.revision &+ 1
                )
            } else {
                try rejectDuplicateInstallation(installationID, excludingProfileID: nil)
                targetProfile = ConnectionProfile(
                    id: UUID().uuidString,
                    displayName: Self.normalizedProfileDisplayName(displayName ?? "", endpoint: normalizedEndpoint),
                    endpoint: normalizedEndpoint,
                    lastSuccessfulAt: prepared.validatedAt,
                    installationID: installationID
                )
            }
        case .newProfile(let id, let displayName):
            try rejectDuplicateInstallation(installationID, excludingProfileID: id)
            targetProfile = ConnectionProfile(
                id: id,
                displayName: Self.normalizedProfileDisplayName(displayName, endpoint: normalizedEndpoint),
                endpoint: normalizedEndpoint,
                lastSuccessfulAt: prepared.validatedAt,
                installationID: installationID
            )
        case .existingProfile(let id):
            guard let existing = connectionProfiles.first(where: { $0.id == id }) else {
                throw ConnectionProfileError.notFound
            }
            try Self.validateInstallationIdentity(
                actual: installationID,
                expected: existing.installationID,
                profileName: existing.displayName
            )
            try rejectDuplicateInstallation(
                installationID,
                excludingProfileID: existing.id
            )
            targetProfile = ConnectionProfile(
                id: existing.id,
                displayName: existing.displayName,
                endpoint: normalizedEndpoint,
                lastSuccessfulAt: prepared.validatedAt,
                installationID: installationID ?? existing.installationID,
                revision: existing.revision &+ 1
            )
        }

        var nextProfiles = connectionProfiles.filter { $0.id != targetProfile.id }
        nextProfiles.append(targetProfile)
        let encodedProfiles = try JSONEncoder().encode(nextProfiles)
        let didChange = normalizedEndpoint != endpoint ||
            prepared.token != token ||
            targetProfile.id != activeConnectionProfileID ||
            targetProfile.installationID != activeConnectionProfile?.installationID

        // Token 必须按档案先经 Vault actor 写入 Keychain；MainActor 不执行安全框架 I/O。
        // 失败时不能发布 activeID，更不能让 SessionStore 退役旧连接。
        let credentialLifecycle = credentialLifecycleGeneration
        let credentialReceipt = try await credentialVault.save(prepared.token, for: targetProfile.id)
        guard credentialLifecycle == credentialLifecycleGeneration, !Task.isCancelled else {
            // App 在 Keychain await 期间进入后台时，候选提交必须回滚，A 的元数据和 Runtime 不变。
            try? await credentialVault.rollback(credentialReceipt, profileID: targetProfile.id)
            throw CancellationError()
        }
        persistProfiles(encodedProfiles)
        defaults.set(targetProfile.id, forKey: Self.activeProfileIDKey)
        defaults.set(normalizedEndpoint, forKey: endpointKey)
        defaults.removeObject(forKey: retiredFallbackEndpointKey)
        defaults.removeObject(forKey: retiredConnectionModeKey)

        let previousRuntimeBundle = activeRuntimeBundle
        endpoint = normalizedEndpoint
        token = prepared.token
        connectionProfiles = nextProfiles
        activeConnectionProfileID = targetProfile.id
        connectionTermination = nil
        // 每次提交都开启新的连接代次。即使地址没变，旧异步结果也必须失效。
        connectionGeneration += 1
        activeRouteEndpoint = nil
        activeConnectionRoute = .configured
        if let candidateRuntime {
            prepared.hostContext?.markConsumed()
            activeRuntimeIdentity = runtimeIdentity(endpoint: normalizedEndpoint, token: prepared.token)
            activeRuntimeBundle = candidateRuntime
        } else {
            activeRuntimeIdentity = nil
            activeRuntimeBundle = nil
        }
        activeHostState = ActiveHostState(
            scope: HostScope(
                profileID: targetProfile.id,
                installationID: targetProfile.installationID ?? Self.unboundInstallationID(profileID: targetProfile.id),
                generation: UInt64(connectionGeneration)
            ),
            endpoint: normalizedEndpoint,
            displayName: targetProfile.displayName,
            committedAt: prepared.validatedAt
        )
        lastError = nil
        HostSwitchSignpost.event("host_commit")

        if let previousRuntimeBundle,
           candidateRuntime.map({ previousRuntimeBundle === $0 }) != true {
            Task {
                await previousRuntimeBundle.shutdownForHostSwitch()
            }
        }
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

    func clearPairing() async throws {
        // Keychain 删除是唯一可能失败的步骤，必须先完成它再清理 UserDefaults 和内存态。
        // 否则系统暂时禁止 Keychain 访问时，下一次启动会变成“旧 Token + 默认 Endpoint”的半提交状态。
        let nextProfiles: [ConnectionProfile]
        if let activeConnectionProfileID {
            nextProfiles = connectionProfiles.filter { $0.id != activeConnectionProfileID }
        } else {
            nextProfiles = connectionProfiles
        }
        let encodedProfiles = try JSONEncoder().encode(nextProfiles)
        let removedProfileID = activeConnectionProfileID
        if let removedProfileID {
            try await credentialVault.delete(profileID: removedProfileID)
        } else {
            try await credentialVault.deleteLegacy()
        }
        persistProfiles(encodedProfiles)
        defaults.removeObject(forKey: Self.activeProfileIDKey)
        defaults.removeObject(forKey: endpointKey)
        defaults.removeObject(forKey: retiredFallbackEndpointKey)
        defaults.removeObject(forKey: retiredConnectionModeKey)
        resetConnectionRoute()
        endpoint = defaultEndpoint
        connectionProfiles = nextProfiles
        activeConnectionProfileID = nil
        connectionGeneration += 1
        token = ""
        let legacyProfileID = "legacy"
        activeHostState = ActiveHostState(
            scope: HostScope(
                profileID: legacyProfileID,
                installationID: Self.unboundInstallationID(profileID: legacyProfileID),
                generation: UInt64(connectionGeneration)
            ),
            endpoint: defaultEndpoint,
            displayName: Self.defaultProfileDisplayName(endpoint: defaultEndpoint),
            committedAt: Date()
        )
        connectionTermination = nil
        connectionStatus = .idle
        lastError = nil
        lastConnectionTestDurationMillis = nil
        lastConnectionTestReport = nil
        recentConnectionTestReports = []
    }

    func deleteConnectionProfile(id: String) async throws {
        guard id != activeConnectionProfileID else {
            throw ConnectionProfileError.cannotDeleteCurrent
        }
        guard connectionProfiles.contains(where: { $0.id == id }) else {
            throw ConnectionProfileError.notFound
        }
        let nextProfiles = connectionProfiles.filter { $0.id != id }
        let encodedProfiles = try JSONEncoder().encode(nextProfiles)
        // 删除也以 Keychain 为提交点；系统暂时不可访问时保留整条档案，方便用户稍后重试。
        try await credentialVault.delete(profileID: id)
        persistProfiles(encodedProfiles)
        connectionProfiles = nextProfiles
    }

    /// 只修改 UserDefaults 中的非敏感显示名称，不进入连接切换事务，也不读取或写入 Keychain。
    /// 先完成编码再发布内存状态，避免持久化准备失败时列表出现半提交名称。
    @discardableResult
    func renameConnectionProfile(id: String, displayName rawDisplayName: String) throws -> Bool {
        guard let profileIndex = connectionProfiles.firstIndex(where: { $0.id == id }) else {
            throw ConnectionProfileError.notFound
        }
        let displayName = rawDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else {
            throw ConnectionProfileError.invalidDisplayName
        }
        guard displayName.count <= Self.connectionProfileDisplayNameLimit else {
            throw ConnectionProfileError.displayNameTooLong(maximum: Self.connectionProfileDisplayNameLimit)
        }
        guard displayName != connectionProfiles[profileIndex].displayName else {
            return false
        }

        var nextProfiles = connectionProfiles
        nextProfiles[profileIndex].displayName = displayName
        nextProfiles[profileIndex].revision &+= 1
        let encodedProfiles = try JSONEncoder().encode(nextProfiles)
        persistProfiles(encodedProfiles)
        connectionProfiles = nextProfiles
        if id == activeConnectionProfileID {
            activeHostState = ActiveHostState(
                scope: activeHostState.scope,
                endpoint: activeHostState.endpoint,
                displayName: displayName,
                committedAt: activeHostState.committedAt
            )
        }
        return true
    }

    @discardableResult
    func validateConnection(endpoint: String, token: String) async throws -> String {
        let startedAt = Date()
        var stages: [ConnectionTestStageTiming] = []
        var gatewayDiagnosticsBaseline: RelayDiagnosticsResponse?
        var gatewayDiagnostics: ConnectionTestGatewayDiagnostics?
        var gatewayDiagnosticsError: String?
        var tailscaleNetworkPath: TailscaleNetworkPathResponse?
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
                tailscaleNetworkPath: tailscaleNetworkPath,
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

        func captureTailscaleNetworkPath(client: AgentAPIClient) async {
            // Tailscale 路径是可选现场证据。旧 agentd、局域网或 CLI 不可用时不能影响主链路测速。
            tailscaleNetworkPath = try? await client.tailscaleNetworkPath()
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
            await captureTailscaleNetworkPath(client: client)
            publishReport()
            throw error
        }

        await captureGatewayDiagnostics(client: client, gatewayStartedAt: gatewayStartedAt)
        await captureTailscaleNetworkPath(client: client)
        publishReport()
        connectionStatus = .connected(version.version)
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

    /// 每次 App 生命周期内只在第一次进入正式设置页时自动测速一次。
    ///
    /// 冷启动的 RootView 可能仍在执行轻量 preflight；这里先等待它结束，再决定是否需要完整测速，
    /// 避免两个探测同时改写连接状态。用户手动点击“重新测速”不经过此门闩，后续仍可随时执行。
    @discardableResult
    func testConnectionOnFirstSettingsAppearanceIfNeeded() async -> Bool {
        guard case .pending = automaticSettingsConnectionTestState else {
            return false
        }
        automaticSettingsConnectionTestState = .running
        var shouldRetryAfterCancellation = false
        defer {
            automaticSettingsConnectionTestState = shouldRetryAfterCancellation ? .pending : .completed
        }

        guard isConfigured, !requiresRePairing else {
            return false
        }

        do {
            while case .testing = connectionStatus {
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            // 页面快速关闭导致任务取消时不消耗本次机会，下次真正进入设置仍会自动测速。
            shouldRetryAfterCancellation = true
            return false
        }

        guard !Task.isCancelled else {
            shouldRetryAfterCancellation = true
            return false
        }
        guard lastConnectionTestReport == nil else {
            return false
        }

        await testConnection(endpoint: endpoint, token: token)
        if Task.isCancelled {
            shouldRetryAfterCancellation = true
        }
        return true
    }

    /// 用已保存的连接信息做轻量真实链路探测，让设置页不必等用户手动点“测试连接”才显示状态。
    @discardableResult
    func preflightConnection(force: Bool = false) async -> Bool {
        let localAvailable = await detectLocalAgent(force: force)
        if !force, case .connected = connectionStatus {
            return true
        }
        // RootView 和设置页可能同时触发；只保留一次探测，避免重复建立 WebSocket。
        guard !isConnectionPreflightRunning else {
            return false
        }
        isConnectionPreflightRunning = true
        defer { isConnectionPreflightRunning = false }

        guard isConfigured else {
            guard localAvailable else {
                connectionStatus = .idle
                return false
            }
            connectionStatus = .testing
            lastError = nil
            do {
                try await connectToLocalAgentWithAutomaticPairing()
                return true
            } catch {
                if Task.isCancelled || error is CancellationError {
                    connectionStatus = .idle
                    return false
                }
                let message = L10n.text("ui.the_native_assistant_was_detected_but_the_automatic")
                connectionStatus = .failed(message)
                lastError = message
                return false
            }
        }

        connectionStatus = .testing
        lastError = nil

        let normalizedEndpoint: String
        do {
            normalizedEndpoint = try Self.validatedEndpoint(endpoint)
        } catch {
            connectionStatus = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            return false
        }

        var candidates: [(endpoint: String, route: ActiveConnectionRoute, timeout: TimeInterval)] = []
        if localAvailable,
           AgentAPIClient.normalizedEndpoint(normalizedEndpoint) != AgentAPIClient.normalizedEndpoint(localAgentEndpoint) {
            candidates.append((
                endpoint: localAgentEndpoint,
                route: .local,
                timeout: min(routeProbeTimeout, 1.5)
            ))
        }
        let configuredRoute: ActiveConnectionRoute = Self.isLoopbackEndpoint(normalizedEndpoint) ? .local : .configured
        candidates.append((endpoint: normalizedEndpoint, route: configuredRoute, timeout: routeProbeTimeout))

        var configuredRouteError: Error?
        for candidate in candidates {
            do {
                try await routeProbe(candidate.endpoint, token, candidate.timeout)
                activateConnectionRoute(candidate.route, endpoint: candidate.endpoint)
                connectionTermination = nil
                connectionStatus = .connected(candidate.route.statusTitle)
                lastError = nil
                return true
            } catch {
                if Task.isCancelled || error is CancellationError {
                    connectionStatus = .idle
                    return false
                }
                // loopback 可能运行着另一个用户配置；本机 Token 不匹配时继续尝试档案地址，
                // 不能提前把仍有效的 Tailscale 凭据标记为失效。
                if candidate.endpoint == normalizedEndpoint {
                    configuredRouteError = error
                }
            }
        }

        if localAvailable {
            do {
                try await connectToLocalAgentWithAutomaticPairing()
                return true
            } catch {
                if Task.isCancelled || error is CancellationError {
                    connectionStatus = .idle
                    return false
                }
                // 兼容尚未实现同机配对接口的旧 agentd；保留已配置路由的真实错误，
                // 让用户仍可扫码修复，而不是把 404 之类的升级细节当作凭据终态。
            }
        }

        resetConnectionRoute()
        let finalError = configuredRouteError ?? URLError(.cannotConnectToHost)
        if isCredentialInvalidatingError(finalError) {
            markCredentialsInvalid()
            return false
        }
        connectionStatus = .failed(finalError.localizedDescription)
        lastError = finalError.localizedDescription
        return false
    }

    /// Catalyst 只探测固定 loopback 健康端点，不扫描局域网，也不读取服务端配置文件。
    /// 这一步不携带 Token；后续必须用已保存或同机自动领取的凭据完成真实 WebSocket 验证。
    @discardableResult
    func detectLocalAgent(force: Bool = false) async -> Bool {
        guard prefersLocalConnection else {
            localAgentDetected = false
            return false
        }
        if !force, localAgentDetected {
            return true
        }
        if let localAgentProbeTask {
            return await localAgentProbeTask.value
        }
        let probe = localAgentProbe
        let endpoint = localAgentEndpoint
        let timeout = min(routeProbeTimeout, 1)
        let probeTask = Task { @MainActor in
            do {
                try await probe(endpoint, timeout)
                return true
            } catch {
                return false
            }
        }
        localAgentProbeTask = probeTask
        let detected = await probeTask.value
        localAgentProbeTask = nil
        // 探测任务由 AppStore 共享；即使某个触发它的 View 已消失，也发布这次有界结果，
        // 避免仍在等待的根启动任务拿到 true，而设置页状态仍停留在未检测。
        localAgentDetected = detected
        return detected
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
            let seconds = Double(milliseconds) / 1_000
            let formatter = NumberFormatter()
            formatter.locale = .autoupdatingCurrent
            formatter.minimumFractionDigits = 1
            formatter.maximumFractionDigits = 1
            let value = formatter.string(from: NSNumber(value: seconds)) ?? String(seconds)
            return L10n.format("ui.seconds_decimal", value)
        }
        return L10n.plural("ui.seconds_count", count: Int((Double(milliseconds) / 1_000).rounded()))
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
        // agentd 为保证同一秒刷新出的短期票据可以独立消费，会输出 RFC3339Nano 小数秒。
        // 先解析新版格式，再回退到旧版无小数秒格式，保持已发布二维码兼容。
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: raw) {
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    static func validatedEndpoint(_ raw: String) throws -> String {
        try EndpointTransportPolicy.validatedEndpoint(raw)
    }

    private static func loadConnectionProfiles(from defaults: UserDefaults) -> [ConnectionProfile] {
        guard let data = defaults.data(forKey: profilesKey) ?? defaults.data(forKey: legacyProfilesKey),
              let decoded = try? JSONDecoder().decode([ConnectionProfile].self, from: data)
        else {
            return []
        }
        var seenIDs = Set<String>()
        return decoded.compactMap { profile in
            let id = profile.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty,
                  seenIDs.insert(id).inserted,
                  let normalizedEndpoint = try? validatedEndpoint(profile.endpoint)
            else {
                return nil
            }
            return ConnectionProfile(
                id: id,
                displayName: normalizedProfileDisplayName(profile.displayName, endpoint: normalizedEndpoint),
                endpoint: normalizedEndpoint,
                lastSuccessfulAt: profile.lastSuccessfulAt,
                installationID: normalizedInstallationID(profile.installationID),
                revision: profile.revision
            )
        }
    }

    private func persistProfiles(_ encodedProfiles: Data) {
        // V1 镜像保留一个兼容周期，确保旧版本回滚后仍可读取连接档案；Token 仍只在 Keychain。
        defaults.set(encodedProfiles, forKey: Self.profilesKey)
        defaults.set(encodedProfiles, forKey: Self.legacyProfilesKey)
    }

    private static func normalizedProfileDisplayName(_ raw: String, endpoint: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultProfileDisplayName(endpoint: endpoint) : trimmed
    }

    private static func defaultProfileDisplayName(endpoint: String) -> String {
        guard let host = URLComponents(string: endpoint)?.host,
              !host.isEmpty else {
            return L10n.text("ui.my_mac")
        }
        if host == "127.0.0.1" || host == "::1" || host == "localhost" {
            return L10n.text("ui.this_mac")
        }
        return host
    }

    private func prepareFastHostContext(
        endpoint: String,
        token: String,
        profileTarget: PreparedConnectionProfileTarget
    ) async throws -> PreparedConnectionSettings {
        let deadline = Date().addingTimeInterval(8)
        let client = AgentAPIClient(endpoint: endpoint, token: token)
        HostSwitchSignpost.begin("switch_prepare")
        defer { HostSwitchSignpost.end("switch_prepare") }

        async let versionResponse: VersionResponse = Self.retryingIdempotentTransportRequest(
            deadline: deadline
        ) { timeout in
            try await client.version(timeout: timeout)
        }
        async let configResponse: CodexAppServerConfigResponse = Self.retryingIdempotentTransportRequest(
            deadline: deadline
        ) { timeout in
            try await client.appServerConfig(timeout: timeout)
        }

        let (version, config) = try await (versionResponse, configResponse)
        try Task.checkCancellation()
        guard let installationID = Self.normalizedInstallationID(version.installationID) else {
            throw ConnectionProfileError.installationIdentityRequired
        }
        try validateCandidateInstallationIdentity(installationID, target: profileTarget)

        var gatewayAttempt = 0
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0.25 else {
                throw URLError(.timedOut)
            }
            let bundle = AppServerRuntimeBundle(
                endpoint: endpoint,
                token: token,
                // 不给 initialize 人为增加最小超时，保证整个快速链路不会突破 8 秒总 deadline。
                requestTimeout: remaining,
                preparedConfig: config
            )
            do {
                try await bundle.prepareForHostActivation()
                try Task.checkCancellation()
                guard deadline.timeIntervalSinceNow > 0 else {
                    throw URLError(.timedOut)
                }

                HostSwitchSignpost.event("gateway_initialized")
                return PreparedConnectionSettings(
                    endpoint: endpoint,
                    token: token,
                    profileTarget: profileTarget,
                    installationID: installationID,
                    hostContext: PreparedHostContext(
                        lease: PreparedHostLease(
                            endpoint: endpoint,
                            installationID: installationID,
                            profileTarget: profileTarget,
                            profileRevision: profileRevision(for: profileTarget),
                            tokenFingerprint: Self.tokenFingerprint(token)
                        ),
                        runtimeBundle: bundle,
                        expiresAt: deadline
                    )
                )
            } catch {
                // 每次失败都先完整退役 candidate；重试时始终只有一条候选业务 WS。
                await bundle.shutdownForHostSwitch()
                guard gatewayAttempt == 0,
                      Self.isRetryableGatewayInitializationError(error),
                      deadline.timeIntervalSinceNow > 0.25 else {
                    throw error
                }
                gatewayAttempt += 1
            }
        }
    }

    private func validateCandidateInstallationIdentity(
        _ installationID: String,
        target: PreparedConnectionProfileTarget
    ) throws {
        switch target {
        case .existingProfile(let id):
            guard let profile = connectionProfiles.first(where: { $0.id == id }) else {
                throw ConnectionProfileError.notFound
            }
            try Self.validateInstallationIdentity(
                actual: installationID,
                expected: profile.installationID,
                profileName: profile.displayName
            )
            try rejectDuplicateInstallation(
                installationID,
                excludingProfileID: profile.id
            )
        case .newProfile(let id, _):
            try rejectDuplicateInstallation(installationID, excludingProfileID: id)
        case .currentOrNew:
            if let activeConnectionProfile {
                try Self.validateInstallationIdentity(
                    actual: installationID,
                    expected: activeConnectionProfile.installationID,
                    profileName: activeConnectionProfile.displayName
                )
                try rejectDuplicateInstallation(
                    installationID,
                    excludingProfileID: activeConnectionProfile.id
                )
            } else {
                try rejectDuplicateInstallation(installationID, excludingProfileID: nil)
            }
        }
    }

    private static func retryingIdempotentTransportRequest<T>(
        deadline: Date,
        operation: @escaping (_ timeout: TimeInterval) async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw URLError(.timedOut)
            }
            do {
                return try await operation(min(4, remaining))
            } catch {
                guard attempt == 0,
                      isRetryableTransportError(error),
                      deadline.timeIntervalSinceNow > 0.25 else {
                    throw error
                }
                attempt += 1
            }
        }
    }

    private static func isRetryableTransportError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else {
            return false
        }
        switch urlError.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .networkConnectionLost, .notConnectedToInternet, .internationalRoamingOff,
             .callIsActive, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    private static func isRetryableGatewayInitializationError(_ error: Error) -> Bool {
        if isCredentialInvalidatingError(error) {
            return false
        }
        if isRetryableTransportError(error) {
            return true
        }
        guard let connectionError = error as? CodexAppServerConnectionError else {
            return false
        }
        switch connectionError {
        case .disconnected, .notInitialized, .timeout, .transport:
            return true
        case .duplicateRequestID, .appServer, .decoding:
            return false
        }
    }

    private func profileRevision(for target: PreparedConnectionProfileTarget) -> UInt64? {
        switch target {
        case .existingProfile(let id), .newProfile(let id, _):
            return connectionProfiles.first(where: { $0.id == id })?.revision
        case .currentOrNew:
            return activeConnectionProfile?.revision
        }
    }

    private static func tokenFingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func rejectDuplicateInstallation(
        _ installationID: String?,
        excludingProfileID: String?
    ) throws {
        guard let installationID,
              let duplicate = connectionProfiles.first(where: {
                  $0.id != excludingProfileID && Self.normalizedInstallationID($0.installationID) == installationID
              }) else {
            return
        }
        throw ConnectionProfileError.duplicateInstallation(profileName: duplicate.displayName)
    }

    private static func validateInstallationIdentity(
        actual: String?,
        expected: String?,
        profileName: String
    ) throws {
        guard let expected = normalizedInstallationID(expected) else {
            return
        }
        guard normalizedInstallationID(actual) == expected else {
            throw ConnectionProfileError.installationIdentityMismatch(profileName: profileName)
        }
    }

    private static func normalizedInstallationID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func unboundInstallationID(profileID: String) -> String {
        "unbound:\(profileID)"
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

    private static func defaultLocalAgentProbe(endpoint: String, timeout: TimeInterval) async throws {
        _ = try await AgentAPIClient(endpoint: endpoint, token: "").health(timeout: timeout)
    }

    private static func defaultLocalAgentPairingClaim(endpoint: String, timeout: TimeInterval) async throws -> String {
        let response = try await AgentAPIClient(endpoint: endpoint, token: "").claimLocalPairing(timeout: timeout)
        let claimedToken = response.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !claimedToken.isEmpty else {
            throw PairingLinkError.missingToken
        }
        return claimedToken
    }

    private func connectToLocalAgentWithAutomaticPairing() async throws {
        let timeout = min(routeProbeTimeout, 2)
        let rawClaimedToken = try await localAgentPairingClaim(localAgentEndpoint, timeout)
        let claimedToken = rawClaimedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !claimedToken.isEmpty else {
            throw PairingLinkError.missingToken
        }
        // 不信任免鉴权响应中的 endpoint；网络目标始终锁定已探测成功的固定 loopback。
        // 同样走快速候选链路，确保首次本机配对也绑定 installation_id 并复用已初始化 gateway。
        let prepared = try await prepareConnectionSettings(
            endpoint: localAgentEndpoint,
            token: claimedToken,
            profileTarget: .currentOrNew(
                displayName: activeConnectionProfile == nil ? L10n.text("ui.this_mac") : nil
            )
        )
        _ = try await commitConnectionSettings(prepared)
        activateConnectionRoute(.local, endpoint: localAgentEndpoint)
        connectionTermination = nil
        connectionStatus = .connected(ActiveConnectionRoute.local.statusTitle)
        lastError = nil
    }

    private static var isRunningOnMacCatalyst: Bool {
#if targetEnvironment(macCatalyst)
        true
#else
        false
#endif
    }

    private static func isLoopbackEndpoint(_ endpoint: String) -> Bool {
        guard let host = URLComponents(string: endpoint)?.host?.lowercased() else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private func activateConnectionRoute(_ route: ActiveConnectionRoute, endpoint: String) {
        let normalized = AgentAPIClient.normalizedEndpoint(endpoint)
        if AgentAPIClient.normalizedEndpoint(connectionEndpoint) != normalized {
            resetDirectRuntime()
        }
        activeRouteEndpoint = normalized
        activeConnectionRoute = route
    }

    private func resetConnectionRoute() {
        activeRouteEndpoint = nil
        activeConnectionRoute = .configured
        resetDirectRuntime()
    }

    private func runtimeBundle(endpoint: String, token: String) -> AppServerRuntimeBundle {
        let identity = runtimeIdentity(endpoint: endpoint, token: token)
        if activeRuntimeIdentity == identity, let bundle = activeRuntimeBundle {
            return bundle
        }
        let bundle = AppServerRuntimeBundle(endpoint: endpoint, token: token)
        activeRuntimeIdentity = identity
        activeRuntimeBundle = bundle
        return bundle
    }

    private func runtimeIdentity(endpoint: String, token: String) -> String {
        "\(endpoint)\n\(token)"
    }

    private func resetDirectRuntime() {
        let retiredRuntime = activeRuntimeBundle
        activeRuntimeIdentity = nil
        activeRuntimeBundle = nil
        if let retiredRuntime {
            Task {
                await retiredRuntime.shutdownForHostSwitch()
            }
        }
    }
}

#if DEBUG
private struct DebugLaunchConfiguration {
    let opensWorkbenchWithoutPairing: Bool
    let seedsWorkbenchUI: Bool
    let seedsQueuedTurnsUI: Bool
    let endpoint: String?
    let token: String?

    static func current(processInfo: ProcessInfo = .processInfo) -> DebugLaunchConfiguration {
        let arguments = processInfo.arguments
        let environment = processInfo.environment
        let seedsQueuedTurnsUI = arguments.contains("--debug-seed-queue-ui")
            || boolValue(environment["MIMI_DEBUG_SEED_QUEUE_UI"])
        return DebugLaunchConfiguration(
            opensWorkbenchWithoutPairing: arguments.contains("--debug-skip-pairing")
                || boolValue(environment["MIMI_DEBUG_SKIP_PAIRING"]),
            seedsWorkbenchUI: arguments.contains("--debug-seed-ui")
                || boolValue(environment["MIMI_DEBUG_SEED_UI"])
                || seedsQueuedTurnsUI,
            seedsQueuedTurnsUI: seedsQueuedTurnsUI,
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
