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

struct ConnectionProfile: Codable, Identifiable, Equatable {
    let id: String
    var displayName: String
    var endpoint: String
    var lastSuccessfulAt: Date?
}

struct ConnectionProfileSettingsItem: Identifiable, Equatable {
    let profile: ConnectionProfile
    let isCurrent: Bool

    var id: String { profile.id }
    var canSwitch: Bool { !isCurrent }
    var canDelete: Bool { !isCurrent }
}

struct ConnectionProfileSettingsModel: Equatable {
    let current: ConnectionProfileSettingsItem?
    let others: [ConnectionProfileSettingsItem]

    init(profiles: [ConnectionProfile], activeProfileID: String?) {
        let items = profiles
            .sorted { lhs, rhs in
                let lhsDate = lhs.lastSuccessfulAt ?? .distantPast
                let rhsDate = rhs.lastSuccessfulAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            .map { ConnectionProfileSettingsItem(profile: $0, isCurrent: $0.id == activeProfileID) }
        current = items.first(where: \.isCurrent)
        others = items.filter { !$0.isCurrent }
    }
}

/// 删除连接凭据前展示的纯值确认模型。
/// 这里只保存目标和文案，不持有删除闭包，确保第一次点击按钮只会进入确认态。
struct ConnectionCredentialRemovalConfirmation: Identifiable, Equatable {
    enum Target: Equatable {
        case current(profileID: String?)
        case savedProfile(profileID: String)
    }

    let target: Target
    let displayName: String?

    static func forgettingCurrent(_ profile: ConnectionProfile?) -> Self {
        Self(
            target: .current(profileID: profile?.id),
            displayName: profile?.displayName
        )
    }

    static func deletingSavedProfile(_ profile: ConnectionProfile) -> Self {
        Self(
            target: .savedProfile(profileID: profile.id),
            displayName: profile.displayName
        )
    }

    var id: String {
        switch target {
        case .current(let profileID):
            return "forget-current:\(profileID ?? "legacy")"
        case .savedProfile(let profileID):
            return "delete-profile:\(profileID)"
        }
    }

    var title: String {
        switch target {
        case .current:
            return "忘记当前 Mac？"
        case .savedProfile:
            return "删除“\(displayName ?? "这台 Mac")”？"
        }
    }

    var message: String {
        switch target {
        case .current:
            let targetName = displayName.map { "“\($0)”" } ?? "当前 Mac"
            return "这会从当前设备的系统钥匙串（Keychain）删除\(targetName)的访问码，并清除 App 中当前连接的会话、消息和日志。再次连接时需要重新扫码配对。"
        case .savedProfile:
            let targetName = displayName ?? "这台 Mac"
            return "这会从当前设备删除“\(targetName)”的连接档案和系统钥匙串（Keychain）访问码。再次连接时需要重新扫码配对；当前 Mac 连接不会受影响。"
        }
    }

    var confirmButtonTitle: String {
        switch target {
        case .current:
            return "忘记这台 Mac"
        case .savedProfile:
            return "删除连接档案"
        }
    }
}

enum ConnectionProfileError: LocalizedError, Equatable {
    case notFound
    case missingToken
    case cannotDeleteCurrent
    case operationInProgress
    case invalidDisplayName
    case displayNameTooLong(maximum: Int)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "找不到这台 Mac 的连接档案"
        case .missingToken:
            return "这台 Mac 的访问码不存在，请重新配对"
        case .cannotDeleteCurrent:
            return "请先切换到其它 Mac，再删除这个档案"
        case .operationInProgress:
            return "另一项 Mac 连接操作仍在进行，请稍后再试"
        case .invalidDisplayName:
            return "Mac 名称不能为空"
        case .displayNameTooLong(let maximum):
            return "Mac 名称最多 \(maximum) 个字符"
        }
    }
}

enum PreparedConnectionProfileTarget: Equatable {
    case currentOrNew(displayName: String?)
    case newProfile(id: String, displayName: String)
    case existingProfile(id: String)
}

struct PreparedConnectionSettings: Equatable {
    let endpoint: String
    let token: String
    let profileTarget: PreparedConnectionProfileTarget
    let validatedAt: Date

    init(
        endpoint: String,
        token: String,
        profileTarget: PreparedConnectionProfileTarget = .currentOrNew(displayName: nil),
        validatedAt: Date = Date()
    ) {
        self.endpoint = endpoint
        self.token = token
        self.profileTarget = profileTarget
        self.validatedAt = validatedAt
    }
}

typealias ConnectionRouteProbe = (_ endpoint: String, _ token: String, _ timeout: TimeInterval) async throws -> Void
typealias LocalAgentProbe = (_ endpoint: String, _ timeout: TimeInterval) async throws -> Void

enum ActiveConnectionRoute: Equatable {
    case configured
    case local

    var statusTitle: String {
        switch self {
        case .configured:
            return "Tailscale"
        case .local:
            return "本机直连"
        }
    }
}

@MainActor
final class AppStore: ObservableObject {
    static let connectionProfileDisplayNameLimit = 48

    @Published var endpoint: String
    @Published private(set) var connectionProfiles: [ConnectionProfile]
    @Published private(set) var activeConnectionProfileID: String?
    @Published private(set) var connectionGeneration = 0
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
    private static let profilesKey = "agentd.connectionProfiles.v1"
    private static let activeProfileIDKey = "agentd.activeConnectionProfileID.v1"
    private let retiredFallbackEndpointKey = "agentd.fallbackEndpoint"
    private let retiredConnectionModeKey = "agentd.connectionMode"
    private let defaultEndpoint = "http://127.0.0.1:8787"
    private let localAgentEndpoint = "http://127.0.0.1:8787"
    private let maxConnectionTestReportHistory = 20
    private let defaults: UserDefaults
    private let tokenStore: TokenStore
    private let routeProbeTimeout: TimeInterval
    private let prefersLocalConnection: Bool
    private let localAgentProbe: LocalAgentProbe
    private let routeProbe: ConnectionRouteProbe
    private var isConnectionPreflightRunning = false
    private var isLocalAgentProbeRunning = false
    private var activeRouteEndpoint: String?
    private var activeRuntimeBundle: AppServerRuntimeBundle?
    private var activeRuntimeIdentity: String?
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
        routeProbe: ConnectionRouteProbe? = nil
    ) {
        self.defaults = defaults
        self.tokenStore = tokenStore
        self.routeProbeTimeout = routeProbeTimeout
        self.prefersLocalConnection = prefersLocalConnection ?? Self.isRunningOnMacCatalyst
        self.localAgentProbe = localAgentProbe ?? Self.defaultLocalAgentProbe
        self.routeProbe = routeProbe ?? Self.defaultConnectionRouteProbe

        var initialProfiles = Self.loadConnectionProfiles(from: defaults)
        var initialActiveProfileID = defaults.string(forKey: Self.activeProfileIDKey)
        var initialEndpoint = defaults.string(forKey: endpointKey) ?? defaultEndpoint
        var initialToken = tokenStore.load()

        if let activeProfileID = initialActiveProfileID,
           let activeProfile = initialProfiles.first(where: { $0.id == activeProfileID }),
           let profileToken = try? tokenStore.load(profileID: activeProfileID),
           !profileToken.isEmpty {
            initialEndpoint = activeProfile.endpoint
            initialToken = profileToken
        } else if initialProfiles.isEmpty, !initialToken.isEmpty {
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
        // 保存前先用短超时验证控制面和 WebSocket，失败时快速反馈；通过后再跑完整诊断报告。
        try await routeProbe(normalizedEndpoint, token, routeProbeTimeout)
        let validatedEndpoint = try await validateConnection(endpoint: normalizedEndpoint, token: token)
        return PreparedConnectionSettings(
            endpoint: validatedEndpoint,
            token: token,
            profileTarget: profileTarget
        )
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
        let profileToken = try tokenStore.load(profileID: id)
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
            validatedAt: prepared.validatedAt
        )
    }

    @discardableResult
    func commitConnectionSettings(_ prepared: PreparedConnectionSettings) throws -> Bool {
        let normalizedEndpoint = try Self.validatedEndpoint(prepared.endpoint)
        let targetProfile: ConnectionProfile
        switch prepared.profileTarget {
        case .currentOrNew(let displayName):
            if let activeConnectionProfileID,
               let current = connectionProfiles.first(where: { $0.id == activeConnectionProfileID }) {
                targetProfile = ConnectionProfile(
                    id: current.id,
                    displayName: Self.normalizedProfileDisplayName(displayName ?? current.displayName, endpoint: normalizedEndpoint),
                    endpoint: normalizedEndpoint,
                    lastSuccessfulAt: prepared.validatedAt
                )
            } else {
                targetProfile = ConnectionProfile(
                    id: UUID().uuidString,
                    displayName: Self.normalizedProfileDisplayName(displayName ?? "", endpoint: normalizedEndpoint),
                    endpoint: normalizedEndpoint,
                    lastSuccessfulAt: prepared.validatedAt
                )
            }
        case .newProfile(let id, let displayName):
            targetProfile = ConnectionProfile(
                id: id,
                displayName: Self.normalizedProfileDisplayName(displayName, endpoint: normalizedEndpoint),
                endpoint: normalizedEndpoint,
                lastSuccessfulAt: prepared.validatedAt
            )
        case .existingProfile(let id):
            guard let existing = connectionProfiles.first(where: { $0.id == id }) else {
                throw ConnectionProfileError.notFound
            }
            targetProfile = ConnectionProfile(
                id: existing.id,
                displayName: existing.displayName,
                endpoint: normalizedEndpoint,
                lastSuccessfulAt: prepared.validatedAt
            )
        }

        var nextProfiles = connectionProfiles.filter { $0.id != targetProfile.id }
        nextProfiles.append(targetProfile)
        let encodedProfiles = try JSONEncoder().encode(nextProfiles)
        let didChange = normalizedEndpoint != endpoint ||
            prepared.token != token ||
            targetProfile.id != activeConnectionProfileID

        // Token 必须按档案先写入 Keychain；失败时不能发布 activeID，更不能让 SessionStore 退役旧连接。
        try tokenStore.save(prepared.token, profileID: targetProfile.id)
        defaults.set(encodedProfiles, forKey: Self.profilesKey)
        defaults.set(targetProfile.id, forKey: Self.activeProfileIDKey)
        defaults.set(normalizedEndpoint, forKey: endpointKey)
        defaults.removeObject(forKey: retiredFallbackEndpointKey)
        defaults.removeObject(forKey: retiredConnectionModeKey)

        endpoint = normalizedEndpoint
        token = prepared.token
        connectionProfiles = nextProfiles
        activeConnectionProfileID = targetProfile.id
        connectionTermination = nil
        // 每次提交都开启新的连接代次。即使地址没变，也要清掉旧 config/allowlist 缓存。
        connectionGeneration += 1
        resetConnectionRoute()
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
        // Keychain 删除是唯一可能失败的步骤，必须先完成它再清理 UserDefaults 和内存态。
        // 否则系统暂时禁止 Keychain 访问时，下一次启动会变成“旧 Token + 默认 Endpoint”的半提交状态。
        let nextProfiles: [ConnectionProfile]
        if let activeConnectionProfileID {
            nextProfiles = connectionProfiles.filter { $0.id != activeConnectionProfileID }
        } else {
            nextProfiles = connectionProfiles
        }
        let encodedProfiles = try JSONEncoder().encode(nextProfiles)
        if let activeConnectionProfileID {
            try tokenStore.delete(profileID: activeConnectionProfileID, allowMissing: true)
        } else {
            try tokenStore.delete(allowMissing: true)
        }
        defaults.set(encodedProfiles, forKey: Self.profilesKey)
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
        connectionTermination = nil
        connectionStatus = .idle
        lastError = nil
        lastConnectionTestDurationMillis = nil
        lastConnectionTestReport = nil
        recentConnectionTestReports = []
    }

    func deleteConnectionProfile(id: String) throws {
        guard id != activeConnectionProfileID else {
            throw ConnectionProfileError.cannotDeleteCurrent
        }
        guard connectionProfiles.contains(where: { $0.id == id }) else {
            throw ConnectionProfileError.notFound
        }
        let nextProfiles = connectionProfiles.filter { $0.id != id }
        let encodedProfiles = try JSONEncoder().encode(nextProfiles)
        // 删除也以 Keychain 为提交点；系统暂时不可访问时保留整条档案，方便用户稍后重试。
        try tokenStore.delete(profileID: id, allowMissing: true)
        defaults.set(encodedProfiles, forKey: Self.profilesKey)
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
        let encodedProfiles = try JSONEncoder().encode(nextProfiles)
        defaults.set(encodedProfiles, forKey: Self.profilesKey)
        connectionProfiles = nextProfiles
        return true
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

    /// 用已保存的连接信息做轻量真实链路探测，让设置页不必等用户手动点“测试连接”才显示状态。
    @discardableResult
    func preflightConnection(force: Bool = false) async -> Bool {
        let localAvailable = await detectLocalAgent(force: force)
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
    /// 这一步不携带 Token；真正选路仍需用当前档案凭据完成控制面和 WebSocket 验证。
    @discardableResult
    func detectLocalAgent(force: Bool = false) async -> Bool {
        guard prefersLocalConnection else {
            localAgentDetected = false
            return false
        }
        if !force, localAgentDetected {
            return true
        }
        guard !isLocalAgentProbeRunning else {
            return localAgentDetected
        }
        isLocalAgentProbeRunning = true
        defer { isLocalAgentProbeRunning = false }
        do {
            try await localAgentProbe(localAgentEndpoint, min(routeProbeTimeout, 1))
            guard !Task.isCancelled else {
                return localAgentDetected
            }
            localAgentDetected = true
            return true
        } catch {
            if Task.isCancelled || error is CancellationError {
                return localAgentDetected
            }
            localAgentDetected = false
            return false
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
        guard let data = defaults.data(forKey: profilesKey),
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
                lastSuccessfulAt: profile.lastSuccessfulAt
            )
        }
    }

    private static func normalizedProfileDisplayName(_ raw: String, endpoint: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultProfileDisplayName(endpoint: endpoint) : trimmed
    }

    private static func defaultProfileDisplayName(endpoint: String) -> String {
        guard let host = URLComponents(string: endpoint)?.host,
              !host.isEmpty else {
            return "我的 Mac"
        }
        if host == "127.0.0.1" || host == "::1" || host == "localhost" {
            return "这台 Mac"
        }
        return host
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
