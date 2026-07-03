import Foundation

struct HealthResponse: Codable {
    let ok: Bool
    let version: String
}

struct VersionResponse: Codable {
    let name: String
    let version: String
}

struct VoiceTranscriptionRequest: Encodable {
    let filename: String
    let contentType: String
    let audioBase64: String
    let language: String?
    let prompt: String?

    enum CodingKeys: String, CodingKey {
        case filename
        case contentType = "content_type"
        case audioBase64 = "audio_base64"
        case language
        case prompt
    }
}

struct VoiceTranscriptionResponse: Decodable, Hashable {
    let text: String
    let model: String
}

struct CodexAppServerConfigResponse: Codable {
    let gatewayWSURL: String
    let runtime: CodexAppServerRuntimeMetadata
    let projects: [AgentProject]
    let policy: CodexAppServerPolicyMetadata

    enum CodingKeys: String, CodingKey {
        case gatewayWSURL = "gateway_ws_url"
        case runtime
        case projects
        case policy
    }
}

struct CodexAppServerRuntimeMetadata: Codable, Hashable {
    let type: String
    let transport: String
    let managed: Bool
    let gatewayAvailable: Bool
    let upstreamConfigured: Bool
    let running: Bool
    let initialized: Bool
    let pendingRequests: Int

    enum CodingKeys: String, CodingKey {
        case type
        case transport
        case managed
        case gatewayAvailable = "gateway_available"
        case upstreamConfigured = "upstream_configured"
        case running
        case initialized
        case pendingRequests = "pending_requests"
    }
}

struct CodexAppServerPolicyMetadata: Codable, Hashable {
    let allowedMethods: [String]
    let projectsSource: String

    enum CodingKeys: String, CodingKey {
        case allowedMethods = "allowed_methods"
        case projectsSource = "projects_source"
    }
}

struct RelayDiagnosticsResponse: Decodable, Equatable {
    let generatedAt: Date
    let appServerGateway: RelayGatewayStats
    let hints: [String]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case appServerGateway = "app_server_gateway"
        case hints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        appServerGateway = try container.decode(RelayGatewayStats.self, forKey: .appServerGateway)
        // Go 端空 slice 在部分路径会编码成 null；诊断提示为空时按无提示处理，不影响连接证据解码。
        hints = try container.decodeIfPresent([String].self, forKey: .hints) ?? []
    }
}

struct RelayGatewayStats: Decodable, Equatable {
    let totalConnections: Int
    let activeConnections: Int
    let failedUpstreamDials: Int
    let upstreamDialMillisMax: Int
    let clientToUpstream: RelayGatewayDirectionStats
    let upstreamToClient: RelayGatewayDirectionStats
    let rpc: RelayGatewayRPCStats
    let recentConnections: [RelayGatewayConnectionStats]
    let activeConnectionDetail: [RelayGatewayConnectionStats]
    let recentRPC: [RelayGatewayRPCSample]

    enum CodingKeys: String, CodingKey {
        case totalConnections = "total_connections"
        case activeConnections = "active_connections"
        case failedUpstreamDials = "failed_upstream_dials"
        case upstreamDialMillisMax = "upstream_dial_ms_max"
        case clientToUpstream = "client_to_upstream"
        case upstreamToClient = "upstream_to_client"
        case rpc
        case recentConnections = "recent_connections"
        case activeConnectionDetail = "active_connections_detail"
        case recentRPC = "recent_rpc"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalConnections = try container.decode(Int.self, forKey: .totalConnections)
        activeConnections = try container.decode(Int.self, forKey: .activeConnections)
        failedUpstreamDials = try container.decode(Int.self, forKey: .failedUpstreamDials)
        upstreamDialMillisMax = try container.decode(Int.self, forKey: .upstreamDialMillisMax)
        clientToUpstream = try container.decode(RelayGatewayDirectionStats.self, forKey: .clientToUpstream)
        upstreamToClient = try container.decode(RelayGatewayDirectionStats.self, forKey: .upstreamToClient)
        rpc = try container.decode(RelayGatewayRPCStats.self, forKey: .rpc)
        // relay 监控里 nil slice 会以 null 返回；移动端展示时统一当空列表处理。
        recentConnections = try container.decodeIfPresent([RelayGatewayConnectionStats].self, forKey: .recentConnections) ?? []
        activeConnectionDetail = try container.decodeIfPresent([RelayGatewayConnectionStats].self, forKey: .activeConnectionDetail) ?? []
        recentRPC = try container.decodeIfPresent([RelayGatewayRPCSample].self, forKey: .recentRPC) ?? []
    }
}

struct RelayGatewayDirectionStats: Decodable, Equatable {
    let frames: Int
    let bytes: Int
    let writeMillisMax: Int
    let lastWriteMillis: Int
    let lastFrameBytes: Int

    enum CodingKeys: String, CodingKey {
        case frames
        case bytes
        case writeMillisMax = "write_ms_max"
        case lastWriteMillis = "last_write_ms"
        case lastFrameBytes = "last_frame_bytes"
    }
}

struct RelayGatewayRPCStats: Decodable, Equatable {
    let responses: Int
    let latencyMillisMax: Int
    let outstandingRequests: Int
    let outstandingMillisMax: Int

    enum CodingKeys: String, CodingKey {
        case responses
        case latencyMillisMax = "latency_ms_max"
        case outstandingRequests = "outstanding_requests"
        case outstandingMillisMax = "outstanding_ms_max"
    }
}

struct RelayGatewayConnectionStats: Decodable, Equatable, Identifiable {
    let id: String
    let startedAt: Date
    let endedAt: Date?
    let durationMillis: Int
    let upstreamDialMillis: Int
    let closeReason: String?
    let clientToUpstream: RelayGatewayDirectionStats
    let upstreamToClient: RelayGatewayDirectionStats
    let rpc: RelayGatewayRPCStats
    let recentRPC: [RelayGatewayRPCSample]
    let lastClientMethod: String?
    let lastUpstreamMethod: String?

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationMillis = "duration_ms"
        case upstreamDialMillis = "upstream_dial_ms"
        case closeReason = "close_reason"
        case clientToUpstream = "client_to_upstream"
        case upstreamToClient = "upstream_to_client"
        case rpc
        case recentRPC = "recent_rpc"
        case lastClientMethod = "last_client_method"
        case lastUpstreamMethod = "last_upstream_method"
    }

    init(
        id: String,
        startedAt: Date,
        endedAt: Date?,
        durationMillis: Int,
        upstreamDialMillis: Int,
        closeReason: String?,
        clientToUpstream: RelayGatewayDirectionStats,
        upstreamToClient: RelayGatewayDirectionStats,
        rpc: RelayGatewayRPCStats,
        recentRPC: [RelayGatewayRPCSample],
        lastClientMethod: String?,
        lastUpstreamMethod: String?
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMillis = durationMillis
        self.upstreamDialMillis = upstreamDialMillis
        self.closeReason = closeReason
        self.clientToUpstream = clientToUpstream
        self.upstreamToClient = upstreamToClient
        self.rpc = rpc
        self.recentRPC = recentRPC
        self.lastClientMethod = lastClientMethod
        self.lastUpstreamMethod = lastUpstreamMethod
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
        self.endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        self.durationMillis = try container.decode(Int.self, forKey: .durationMillis)
        self.upstreamDialMillis = try container.decode(Int.self, forKey: .upstreamDialMillis)
        self.closeReason = try container.decodeIfPresent(String.self, forKey: .closeReason)
        self.clientToUpstream = try container.decode(RelayGatewayDirectionStats.self, forKey: .clientToUpstream)
        self.upstreamToClient = try container.decode(RelayGatewayDirectionStats.self, forKey: .upstreamToClient)
        self.rpc = try container.decode(RelayGatewayRPCStats.self, forKey: .rpc)
        self.recentRPC = try container.decodeIfPresent([RelayGatewayRPCSample].self, forKey: .recentRPC) ?? []
        self.lastClientMethod = try container.decodeIfPresent(String.self, forKey: .lastClientMethod)
        self.lastUpstreamMethod = try container.decodeIfPresent(String.self, forKey: .lastUpstreamMethod)
    }
}

struct RelayGatewayRPCSample: Decodable, Equatable, Identifiable {
    let completedAt: Date
    let method: String
    let latencyMillis: Int
    let requestBytes: Int
    let responseBytes: Int
    let outstanding: Bool?
    let outstandingForMillis: Int?

    var id: String {
        "\(completedAt.timeIntervalSince1970)-\(method)-\(latencyMillis)"
    }

    enum CodingKeys: String, CodingKey {
        case completedAt = "completed_at"
        case method
        case latencyMillis = "latency_ms"
        case requestBytes = "request_bytes"
        case responseBytes = "response_bytes"
        case outstanding
        case outstandingForMillis = "outstanding_for_ms"
    }
}

struct CapabilityListRequest: Encodable {
    let path: String?
}

struct CapabilityListResponse: Codable, Hashable {
    let path: String?
    let skills: [SkillCapability]
    let mcpServers: [MCPCapability]

    enum CodingKeys: String, CodingKey {
        case path
        case skills
        case mcpServers = "mcp_servers"
    }
}

struct SkillCapability: Codable, Hashable, Identifiable {
    let name: String
    let description: String?
    let scope: String
    let path: String
    let enabled: Bool

    var id: String { path }
}

struct MCPCapability: Codable, Hashable, Identifiable {
    let name: String
    let scope: String
    let configPath: String
    let transport: String?
    let command: String?
    let url: String?
    let enabled: Bool
    let plugin: String?
    let status: String?
    let statusNote: String?

    var id: String {
        "\(configPath)#\(plugin ?? "")#\(name)"
    }

    enum CodingKeys: String, CodingKey {
        case name
        case scope
        case configPath = "config_path"
        case transport
        case command
        case url
        case enabled
        case plugin
        case status
        case statusNote = "status_note"
    }

    init(
        name: String,
        scope: String,
        configPath: String,
        transport: String?,
        command: String?,
        url: String?,
        enabled: Bool,
        plugin: String?,
        status: String? = nil,
        statusNote: String? = nil
    ) {
        self.name = name
        self.scope = scope
        self.configPath = configPath
        self.transport = transport
        self.command = command
        self.url = url
        self.enabled = enabled
        self.plugin = plugin
        self.status = status
        self.statusNote = statusNote
    }
}

struct ProjectsResponse: Codable {
    let projects: [AgentProject]
}

struct WorkspaceResolveRequest: Encodable {
    let path: String
}

struct WorkspaceResolveResponse: Codable {
    let workspace: AgentWorkspace
}

struct WorktreeCreateRequest: Encodable {
    let path: String
    let name: String?
    let base: String?
    let branch: String?
}

struct WorktreeBranchListRequest: Encodable {
    let path: String
}

struct WorktreeBranchListResponse: Codable, Hashable {
    let path: String
    let defaultBase: String?
    let currentBranch: String?
    let branches: [WorktreeBranchItem]

    enum CodingKeys: String, CodingKey {
        case path
        case defaultBase = "default_base"
        case currentBranch = "current_branch"
        case branches
    }
}

struct WorktreeBranchItem: Codable, Hashable, Identifiable {
    let name: String
    let kind: String
    let isCurrent: Bool
    let isDefault: Bool

    var id: String { "\(kind):\(name)" }

    enum CodingKeys: String, CodingKey {
        case name
        case kind
        case isCurrent = "is_current"
        case isDefault = "is_default"
    }

    init(name: String, kind: String, isCurrent: Bool = false, isDefault: Bool = false) {
        self.name = name
        self.kind = kind
        self.isCurrent = isCurrent
        self.isDefault = isDefault
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(String.self, forKey: .kind)
        isCurrent = try container.decodeIfPresent(Bool.self, forKey: .isCurrent) ?? false
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }
}

struct WorktreeListResponse: Codable {
    let worktrees: [WorktreeListItem]
}

struct WorktreeListItem: Codable, Hashable, Identifiable {
    let workspace: AgentWorkspace
    let worktree: WorktreeDescriptor

    var id: String { workspace.id }
}

struct WorktreeDeleteRequest: Encodable {
    let path: String
    let force: Bool
}

struct WorktreeDeleteResponse: Codable {
    let deletedPath: String
    let worktrees: [WorktreeListItem]
    let workspace: AgentWorkspace?
    let worktree: WorktreeDescriptor?

    enum CodingKeys: String, CodingKey {
        case deletedPath = "deleted_path"
        case worktrees
        case workspace
        case worktree
    }
}

struct WorktreePruneResponse: Codable {
    let prunedPaths: [String]
    let worktrees: [WorktreeListItem]

    enum CodingKeys: String, CodingKey {
        case prunedPaths = "pruned_paths"
        case worktrees
    }
}

struct WorktreeCreateResponse: Codable {
    let workspace: AgentWorkspace
    let worktree: WorktreeDescriptor
}

struct WorktreeDescriptor: Codable, Hashable {
    let path: String
    let repositoryPath: String
    let base: String
    let branch: String?
    let dirty: Bool
    let ahead: Int
    let behind: Int
    let upstream: String?
    let rootProjectID: String
    let rootProjectName: String
    let rootProjectPath: String

    enum CodingKeys: String, CodingKey {
        case path
        case repositoryPath = "repository_path"
        case base
        case branch
        case dirty
        case ahead
        case behind
        case upstream
        case rootProjectID = "root_project_id"
        case rootProjectName = "root_project_name"
        case rootProjectPath = "root_project_path"
    }

    init(
        path: String,
        repositoryPath: String,
        base: String,
        branch: String?,
        dirty: Bool = false,
        ahead: Int = 0,
        behind: Int = 0,
        upstream: String? = nil,
        rootProjectID: String,
        rootProjectName: String,
        rootProjectPath: String
    ) {
        self.path = path
        self.repositoryPath = repositoryPath
        self.base = base
        self.branch = branch
        self.dirty = dirty
        self.ahead = ahead
        self.behind = behind
        self.upstream = upstream
        self.rootProjectID = rootProjectID
        self.rootProjectName = rootProjectName
        self.rootProjectPath = rootProjectPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        repositoryPath = try container.decode(String.self, forKey: .repositoryPath)
        base = try container.decode(String.self, forKey: .base)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        dirty = try container.decodeIfPresent(Bool.self, forKey: .dirty) ?? false
        ahead = try container.decodeIfPresent(Int.self, forKey: .ahead) ?? 0
        behind = try container.decodeIfPresent(Int.self, forKey: .behind) ?? 0
        upstream = try container.decodeIfPresent(String.self, forKey: .upstream)
        rootProjectID = try container.decode(String.self, forKey: .rootProjectID)
        rootProjectName = try container.decode(String.self, forKey: .rootProjectName)
        rootProjectPath = try container.decode(String.self, forKey: .rootProjectPath)
    }
}

struct DirectoryListRequest: Encodable {
    let path: String
}

struct DirectoryEntry: Codable, Hashable, Identifiable {
    let name: String
    let path: String
    let isDir: Bool
    let canOpen: Bool
    let canBrowse: Bool
    let canPreview: Bool

    var id: String { path }
    var isPreviewable: Bool { canPreview }

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case isDir = "is_dir"
        case canOpen = "can_open"
        case canBrowse = "can_browse"
        case canPreview = "can_preview"
    }

    init(name: String, path: String, isDir: Bool, canOpen: Bool, canBrowse: Bool, canPreview: Bool = false) {
        self.name = name
        self.path = path
        self.isDir = isDir
        self.canOpen = canOpen
        self.canBrowse = canBrowse
        self.canPreview = canPreview
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        isDir = try container.decode(Bool.self, forKey: .isDir)
        canOpen = try container.decode(Bool.self, forKey: .canOpen)
        canBrowse = try container.decode(Bool.self, forKey: .canBrowse)
        canPreview = try container.decodeIfPresent(Bool.self, forKey: .canPreview) ?? false
    }
}

struct DirectoryListResponse: Codable, Hashable {
    let path: String
    let parentPath: String?
    let entries: [DirectoryEntry]
    let truncated: Bool?

    enum CodingKeys: String, CodingKey {
        case path
        case parentPath = "parent_path"
        case entries
        case truncated
    }
}

struct FileReadRequest: Encodable {
    let path: String
}

struct FileReadResponse: Codable, Hashable {
    let path: String
    let name: String
    let contentType: String
    let size: Int64
    let contentBase64: String

    enum CodingKeys: String, CodingKey {
        case path
        case name
        case contentType = "content_type"
        case size
        case contentBase64 = "content_base64"
    }
}

struct CommandActionListRequest: Encodable {
    let path: String
}

struct CommandActionRunRequest: Encodable {
    let path: String
    let id: String
    let confirmed: Bool
}

struct PairingClaimRequest: Encodable, Equatable {
    let endpoint: String
    let issuedAt: String
    let expiresAt: String
    let pairSignature: String

    enum CodingKeys: String, CodingKey {
        case endpoint
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
        case pairSignature = "pair_sig"
    }
}

struct PairingClaimResponse: Decodable, Equatable {
    let endpoint: String
    let token: String
}

struct CommandActionListResponse: Codable, Hashable {
    let path: String
    let actions: [AgentCommandAction]
}

struct AgentCommandAction: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let command: String
    let args: [String]
    let workingDir: String
    let timeoutSeconds: Int
    let requiresConfirmation: Bool

    var displayCommand: String {
        ([command] + args).joined(separator: " ")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case command
        case args
        case workingDir = "working_dir"
        case timeoutSeconds = "timeout_seconds"
        case requiresConfirmation = "requires_confirmation"
    }

    init(id: String, name: String, command: String, args: [String] = [], workingDir: String, timeoutSeconds: Int, requiresConfirmation: Bool = false) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.workingDir = workingDir
        self.timeoutSeconds = timeoutSeconds
        self.requiresConfirmation = requiresConfirmation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        workingDir = try container.decode(String.self, forKey: .workingDir)
        timeoutSeconds = try container.decode(Int.self, forKey: .timeoutSeconds)
        requiresConfirmation = try container.decodeIfPresent(Bool.self, forKey: .requiresConfirmation) ?? false
    }
}

struct CommandActionRunResponse: Codable, Hashable {
    let id: String
    let name: String
    let path: String
    let workingDir: String
    let command: String
    let args: [String]
    let success: Bool
    let exitCode: Int
    let output: String?
    let truncated: Bool?
    let timedOut: Bool?
    let durationMS: Int64

    var displayCommand: String {
        ([command] + args).joined(separator: " ")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case path
        case workingDir = "working_dir"
        case command
        case args
        case success
        case exitCode = "exit_code"
        case output
        case truncated
        case timedOut = "timed_out"
        case durationMS = "duration_ms"
    }

    init(
        id: String,
        name: String,
        path: String,
        workingDir: String,
        command: String,
        args: [String] = [],
        success: Bool,
        exitCode: Int,
        output: String?,
        truncated: Bool?,
        timedOut: Bool?,
        durationMS: Int64
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.workingDir = workingDir
        self.command = command
        self.args = args
        self.success = success
        self.exitCode = exitCode
        self.output = output
        self.truncated = truncated
        self.timedOut = timedOut
        self.durationMS = durationMS
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        workingDir = try container.decode(String.self, forKey: .workingDir)
        command = try container.decode(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        success = try container.decode(Bool.self, forKey: .success)
        exitCode = try container.decode(Int.self, forKey: .exitCode)
        output = try container.decodeIfPresent(String.self, forKey: .output)
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated)
        timedOut = try container.decodeIfPresent(Bool.self, forKey: .timedOut)
        durationMS = try container.decode(Int64.self, forKey: .durationMS)
    }
}

struct GitStatusRequest: Encodable {
    let path: String
}

enum GitActionKind: String, Codable, Hashable {
    case stage
    case unstage
    case revert
    case stagePatch = "stage_patch"
    case unstagePatch = "unstage_patch"
    case revertPatch = "revert_patch"
}

struct GitActionRequest: Encodable {
    let path: String
    let action: GitActionKind
    let files: [String]
    let patch: String?

    init(path: String, action: GitActionKind, files: [String] = [], patch: String? = nil) {
        self.path = path
        self.action = action
        self.files = files
        self.patch = patch
    }
}

struct GitCommitRequest: Encodable {
    let path: String
    let message: String
}

struct GitPushRequest: Encodable {
    let path: String
    let remote: String?
}

struct GitPullRequestRequest: Encodable {
    let path: String
    let title: String
    let body: String
    let draft: Bool
}

struct GitPullRequestStatusRequest: Encodable {
    let path: String
}

struct GitPushResponse: Codable, Hashable {
    let path: String
    let remote: String
    let branch: String
    let output: String?
    let status: GitStatusResponse
}

struct GitPullRequestResponse: Codable, Hashable {
    let path: String
    let branch: String
    let url: String?
    let output: String?
}

struct GitPullRequestStatusResponse: Codable, Hashable {
    let path: String
    let branch: String
    let exists: Bool
    let number: Int?
    let title: String?
    let state: String?
    let url: String?
    let isDraft: Bool
    let reviewDecision: String?
    let mergeStateStatus: String?
    let headRefName: String?
    let baseRefName: String?

    enum CodingKeys: String, CodingKey {
        case path
        case branch
        case exists
        case number
        case title
        case state
        case url
        case isDraft = "is_draft"
        case reviewDecision = "review_decision"
        case mergeStateStatus = "merge_state_status"
        case headRefName = "head_ref_name"
        case baseRefName = "base_ref_name"
    }

    init(
        path: String,
        branch: String,
        exists: Bool,
        number: Int? = nil,
        title: String? = nil,
        state: String? = nil,
        url: String? = nil,
        isDraft: Bool = false,
        reviewDecision: String? = nil,
        mergeStateStatus: String? = nil,
        headRefName: String? = nil,
        baseRefName: String? = nil
    ) {
        self.path = path
        self.branch = branch
        self.exists = exists
        self.number = number
        self.title = title
        self.state = state
        self.url = url
        self.isDraft = isDraft
        self.reviewDecision = reviewDecision
        self.mergeStateStatus = mergeStateStatus
        self.headRefName = headRefName
        self.baseRefName = baseRefName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        branch = try container.decode(String.self, forKey: .branch)
        exists = try container.decode(Bool.self, forKey: .exists)
        number = try container.decodeIfPresent(Int.self, forKey: .number)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        isDraft = try container.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        reviewDecision = try container.decodeIfPresent(String.self, forKey: .reviewDecision)
        mergeStateStatus = try container.decodeIfPresent(String.self, forKey: .mergeStateStatus)
        headRefName = try container.decodeIfPresent(String.self, forKey: .headRefName)
        baseRefName = try container.decodeIfPresent(String.self, forKey: .baseRefName)
    }
}

struct GitFileStatus: Codable, Hashable, Identifiable {
    let path: String
    let code: String
    let staged: Bool
    let unstaged: Bool
    let untracked: Bool

    var id: String { path }

    var displayCode: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "--" : code
    }

    enum CodingKeys: String, CodingKey {
        case path
        case code
        case staged
        case unstaged
        case untracked
    }
}

struct GitStatusResponse: Codable, Hashable {
    let path: String
    let isRepository: Bool
    let branch: String?
    let head: String?
    let statusText: String?
    let diffStat: String?
    let unstagedDiff: String?
    let stagedDiff: String?
    let files: [GitFileStatus]
    let truncated: Bool?
    let truncatedNote: String?

    var hasChanges: Bool {
        [statusText, diffStat, unstagedDiff, stagedDiff].contains { value in
            !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    enum CodingKeys: String, CodingKey {
        case path
        case isRepository = "is_repository"
        case branch
        case head
        case statusText = "status_text"
        case diffStat = "diff_stat"
        case unstagedDiff = "unstaged_diff"
        case stagedDiff = "staged_diff"
        case files
        case truncated
        case truncatedNote = "truncated_note"
    }

    init(
        path: String,
        isRepository: Bool,
        branch: String?,
        head: String?,
        statusText: String?,
        diffStat: String?,
        unstagedDiff: String?,
        stagedDiff: String?,
        files: [GitFileStatus] = [],
        truncated: Bool?,
        truncatedNote: String?
    ) {
        self.path = path
        self.isRepository = isRepository
        self.branch = branch
        self.head = head
        self.statusText = statusText
        self.diffStat = diffStat
        self.unstagedDiff = unstagedDiff
        self.stagedDiff = stagedDiff
        self.files = files
        self.truncated = truncated
        self.truncatedNote = truncatedNote
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try container.decode(String.self, forKey: .path)
        self.isRepository = try container.decode(Bool.self, forKey: .isRepository)
        self.branch = try container.decodeIfPresent(String.self, forKey: .branch)
        self.head = try container.decodeIfPresent(String.self, forKey: .head)
        self.statusText = try container.decodeIfPresent(String.self, forKey: .statusText)
        self.diffStat = try container.decodeIfPresent(String.self, forKey: .diffStat)
        self.unstagedDiff = try container.decodeIfPresent(String.self, forKey: .unstagedDiff)
        self.stagedDiff = try container.decodeIfPresent(String.self, forKey: .stagedDiff)
        self.files = try container.decodeIfPresent([GitFileStatus].self, forKey: .files) ?? []
        self.truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated)
        self.truncatedNote = try container.decodeIfPresent(String.self, forKey: .truncatedNote)
    }
}

struct SessionsResponse: Codable {
    let sessions: [AgentSession]
    let rows: [DataFlowSessionRow]
    let nextCursor: String?
    let hasMore: Bool?

    enum CodingKeys: String, CodingKey {
        case sessions
        case rows
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rows = try container.decodeIfPresent([DataFlowSessionRow].self, forKey: .rows) ?? []
        self.rows = rows
        self.sessions = try container.decodeIfPresent([AgentSession].self, forKey: .sessions) ?? rows.map(AgentSession.init(row:))
        self.nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
        self.hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore)
    }
}

struct SessionsPage: Equatable {
    let sessions: [AgentSession]
    let nextCursor: String?
    let hasMore: Bool

    init(response: SessionsResponse) {
        self.sessions = response.sessions
        self.nextCursor = response.nextCursor
        self.hasMore = response.hasMore ?? false
    }

    init(sessions: [AgentSession], nextCursor: String? = nil, hasMore: Bool = false) {
        self.sessions = sessions
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

struct SessionResponse: Codable {
    let session: AgentSession
    let row: DataFlowSessionRow?
    let recentOutput: String?
    let lastSeq: EventSequence?

    enum CodingKeys: String, CodingKey {
        case session
        case row
        case recentOutput = "recent_output"
        case lastSeq = "last_seq"
    }

    init(session: AgentSession, row: DataFlowSessionRow? = nil, recentOutput: String? = nil, lastSeq: EventSequence? = nil) {
        self.session = session
        self.row = row
        self.recentOutput = recentOutput
        self.lastSeq = lastSeq
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let row = try container.decodeIfPresent(DataFlowSessionRow.self, forKey: .row)
        self.row = row
        if let session = try container.decodeIfPresent(AgentSession.self, forKey: .session) {
            self.session = session
        } else if let row {
            self.session = AgentSession(row: row)
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.session,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "缺少 session 或 row")
            )
        }
        self.recentOutput = try container.decodeIfPresent(String.self, forKey: .recentOutput)
        self.lastSeq = try container.decodeIfPresent(EventSequence.self, forKey: .lastSeq)
    }
}

struct CreateSessionResponse: Codable {
    let session: AgentSession
    let row: DataFlowSessionRow?
    let wsURL: String
    let firstMessage: AgentMessage?

    enum CodingKeys: String, CodingKey {
        case session
        case row
        case wsURL = "ws_url"
        case firstMessage = "first_message"
    }

    init(session: AgentSession, row: DataFlowSessionRow? = nil, wsURL: String, firstMessage: AgentMessage? = nil) {
        self.session = session
        self.row = row
        self.wsURL = wsURL
        self.firstMessage = firstMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let row = try container.decodeIfPresent(DataFlowSessionRow.self, forKey: .row)
        self.row = row
        if let session = try container.decodeIfPresent(AgentSession.self, forKey: .session) {
            self.session = session
        } else if let row {
            self.session = AgentSession(row: row)
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.session,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "缺少 session 或 row")
            )
        }
        self.wsURL = try container.decode(String.self, forKey: .wsURL)
        self.firstMessage = try container.decodeIfPresent(AgentMessage.self, forKey: .firstMessage)
    }
}

struct MessagesResponse: Codable {
    let messages: [CodexHistoryMessage]
    let page: MessagePage?
    let nextCursor: String?
    let previousCursor: String?
    let hasMoreBefore: Bool?
    let snapshotSeq: EventSequence?

    enum CodingKeys: String, CodingKey {
        case messages
        case page
        case nextCursor = "next_cursor"
        case previousCursor = "previous_cursor"
        case hasMoreBefore = "has_more_before"
        case snapshotSeq = "snapshot_seq"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.page = try container.decodeIfPresent(MessagePage.self, forKey: .page)
        if let page {
            self.messages = page.messages.map {
                CodexHistoryMessage(
                    id: $0.id,
                    role: $0.role.rawValue,
                    content: $0.content,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt,
                    clientMessageID: $0.clientMessageID,
                    turnID: $0.turnID,
                    itemID: $0.itemID,
                    seq: $0.seq,
                    revision: $0.revision,
                    sendStatus: $0.sendStatus,
                    isTimestampFallback: $0.isTimestampFallback
                )
            }
            self.nextCursor = page.nextCursor
            self.previousCursor = page.previousCursor
            self.hasMoreBefore = page.hasMoreBefore
            self.snapshotSeq = page.snapshotSeq
        } else {
            self.messages = try container.decodeIfPresent([CodexHistoryMessage].self, forKey: .messages) ?? []
            self.nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
            self.previousCursor = try container.decodeIfPresent(String.self, forKey: .previousCursor)
            self.hasMoreBefore = try container.decodeIfPresent(Bool.self, forKey: .hasMoreBefore)
            self.snapshotSeq = try container.decodeIfPresent(EventSequence.self, forKey: .snapshotSeq)
        }
    }
}

struct HistoryMessagesPage: Equatable {
    let messages: [CodexHistoryMessage]
    let previousCursor: String?
    let hasMoreBefore: Bool
    let context: SessionContextSnapshot?
    let snapshotSeq: EventSequence?

    init(response: MessagesResponse) {
        self.messages = response.messages
        self.previousCursor = response.previousCursor
        self.hasMoreBefore = response.hasMoreBefore ?? false
        self.context = nil
        self.snapshotSeq = response.snapshotSeq
    }

    init(
        messages: [CodexHistoryMessage],
        previousCursor: String? = nil,
        hasMoreBefore: Bool = false,
        context: SessionContextSnapshot? = nil,
        snapshotSeq: EventSequence? = nil
    ) {
        self.messages = messages
        self.previousCursor = previousCursor
        self.hasMoreBefore = hasMoreBefore
        self.context = context
        self.snapshotSeq = snapshotSeq
    }
}

struct CreateSessionRequest: Encodable {
    let projectID: String
    let projectPath: String?
    let projectName: String?
    let rootProjectID: String?
    let prompt: String
    let input: [CodexAppServerUserInput]
    let turnOptions: CodexAppServerTurnOptions
    let initialGoalObjective: String?
    let resumeID: String
    let clientMessageID: ClientMessageID?

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case projectPath = "project_path"
        case projectName = "project_name"
        case rootProjectID = "root_project_id"
        case prompt
        case input
        case turnOptions = "turn_options"
        case initialGoalObjective = "initial_goal_objective"
        case resumeID = "resume_id"
        case clientMessageID = "client_message_id"
    }

    init(
        projectID: String,
        projectPath: String? = nil,
        projectName: String? = nil,
        rootProjectID: String? = nil,
        prompt: String,
        input: [CodexAppServerUserInput]? = nil,
        turnOptions: CodexAppServerTurnOptions = .default,
        initialGoalObjective: String? = nil,
        resumeID: String,
        clientMessageID: ClientMessageID? = nil
    ) {
        self.projectID = projectID
        self.projectPath = projectPath
        self.projectName = projectName
        self.rootProjectID = rootProjectID
        self.prompt = prompt
        self.input = input ?? CodexAppServerTurnPayload.defaultInput(for: prompt)
        self.turnOptions = turnOptions
        self.initialGoalObjective = initialGoalObjective
        self.resumeID = resumeID
        self.clientMessageID = clientMessageID
    }
}

enum CodexAppServerImageDetail: String, Codable, CaseIterable, Hashable, Identifiable {
    case auto
    case low
    case high
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:
            return "自动"
        case .low:
            return "低"
        case .high:
            return "高"
        case .original:
            return "原图"
        }
    }
}

enum CodexAppServerUserInput: Codable, Hashable, Identifiable {
    case text(String, textElements: [CodexAppServerJSONValue] = [])
    case image(url: String, detail: CodexAppServerImageDetail? = nil)
    case localImage(path: String, detail: CodexAppServerImageDetail? = nil)
    case skill(name: String, path: String)
    case mention(name: String, path: String)

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case textElements = "text_elements"
        case url
        case path
        case name
        case detail
    }

    var id: String {
        switch self {
        case .text(let text, _):
            return "text:\(text)"
        case .image(let url, _):
            return "image:\(Self.stableDigest(url))"
        case .localImage(let path, _):
            return "localImage:\(path)"
        case .skill(let name, let path):
            return "skill:\(name):\(path)"
        case .mention(let name, let path):
            return "mention:\(name):\(path)"
        }
    }

    private static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    var retainedAfterAcceptedSend: CodexAppServerUserInput? {
        switch self {
        case .image:
            // 图片消息发送成功后仍然要保留可渲染来源，否则 UI 只能剩下「[图片]」占位。
            // 这里牺牲一点内存，换取当前会话里的真实图片预览和失败重试一致性。
            return self
        default:
            return self
        }
    }

    var previewText: String {
        switch self {
        case .text(let text, _):
            return text
        case .image:
            return "[图片]"
        case .localImage(let path, _):
            return "[图片 \(URL(fileURLWithPath: path).lastPathComponent)]"
        case .skill(let name, _):
            return "[$\(name)]"
        case .mention(let name, _):
            return "[@\(name)]"
        }
    }

    var jsonValue: CodexAppServerJSONValue {
        switch self {
        case .text(let text, let textElements):
            return .object([
                "type": .string("text"),
                "text": .string(text),
                "text_elements": .array(textElements)
            ])
        case .image(let url, let detail):
            var object: [String: CodexAppServerJSONValue] = [
                "type": .string("image"),
                "url": .string(url)
            ]
            if let detail {
                object["detail"] = .string(detail.rawValue)
            }
            return .object(object)
        case .localImage(let path, let detail):
            var object: [String: CodexAppServerJSONValue] = [
                "type": .string("localImage"),
                "path": .string(path)
            ]
            if let detail {
                object["detail"] = .string(detail.rawValue)
            }
            return .object(object)
        case .skill(let name, let path):
            return .object([
                "type": .string("skill"),
                "name": .string(name),
                "path": .string(path)
            ])
        case .mention(let name, let path):
            return .object([
                "type": .string("mention"),
                "name": .string(name),
                "path": .string(path)
            ])
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(
                try container.decode(String.self, forKey: .text),
                textElements: try container.decodeIfPresent([CodexAppServerJSONValue].self, forKey: .textElements) ?? []
            )
        case "image":
            self = .image(
                url: try container.decode(String.self, forKey: .url),
                detail: try container.decodeIfPresent(CodexAppServerImageDetail.self, forKey: .detail)
            )
        case "localImage":
            self = .localImage(
                path: try container.decode(String.self, forKey: .path),
                detail: try container.decodeIfPresent(CodexAppServerImageDetail.self, forKey: .detail)
            )
        case "skill":
            self = .skill(
                name: try container.decode(String.self, forKey: .name),
                path: try container.decode(String.self, forKey: .path)
            )
        case "mention":
            self = .mention(
                name: try container.decode(String.self, forKey: .name),
                path: try container.decode(String.self, forKey: .path)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "未知 app-server UserInput 类型：\(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text, let textElements):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encode(textElements, forKey: .textElements)
        case .image(let url, let detail):
            try container.encode("image", forKey: .type)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(detail, forKey: .detail)
        case .localImage(let path, let detail):
            try container.encode("localImage", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(detail, forKey: .detail)
        case .skill(let name, let path):
            try container.encode("skill", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(path, forKey: .path)
        case .mention(let name, let path):
            try container.encode("mention", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(path, forKey: .path)
        }
    }
}

enum CodexAppServerReasoningEffort: String, Codable, CaseIterable, Hashable, Identifiable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }
}

enum CodexAppServerReasoningSummary: String, Codable, CaseIterable, Hashable, Identifiable {
    case auto
    case concise
    case detailed
    case none

    var id: String { rawValue }
}

enum CodexAppServerPersonality: String, Codable, CaseIterable, Hashable, Identifiable {
    case none
    case friendly
    case pragmatic

    var id: String { rawValue }
}

private enum CodexAppServerDefaults {
    static let model: String? = nil
    static let reasoningEffort: CodexAppServerReasoningEffort = .xhigh
}

enum CodexAppServerApprovalPolicy: String, Codable, CaseIterable, Hashable, Identifiable {
    case untrusted
    case onFailure = "on-failure"
    case onRequest = "on-request"

    var id: String { rawValue }
}

enum CodexAppServerSandboxMode: String, Codable, CaseIterable, Hashable, Identifiable {
    case readOnly
    case workspaceWrite
    case dangerFullAccess

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readOnly:
            return "只读"
        case .workspaceWrite:
            return "可写"
        case .dangerFullAccess:
            return "完全访问"
        }
    }
}

struct CodexAppServerTurnOptions: Codable, Hashable {
    enum CollaborationMode: String, Codable, Hashable {
        case plan
        case `default`
    }

    var model: String?
    var modelProvider: String?
    var serviceTier: String?
    var reasoningEffort: CodexAppServerReasoningEffort?
    var reasoningSummary: CodexAppServerReasoningSummary?
    var approvalPolicy: CodexAppServerApprovalPolicy
    var approvalsReviewer: String
    var sandboxMode: CodexAppServerSandboxMode
    var networkAccess: Bool
    var personality: CodexAppServerPersonality?
    var config: CodexAppServerJSONValue?
    var baseInstructions: String?
    var developerInstructions: String?
    var outputSchema: CodexAppServerJSONValue?
    var serviceName: String?
    var sessionStartSource: String?
    var threadSource: String?
    // 只在 iPad 发起 turn/start 时消费的本地发送配置；不模拟 prompt，不影响 thread/start。
    var collaborationMode: CollaborationMode?
    var planGuidanceEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case modelProvider = "model_provider"
        case serviceTier = "service_tier"
        case reasoningEffort = "reasoning_effort"
        case reasoningSummary = "reasoning_summary"
        case approvalPolicy = "approval_policy"
        case approvalsReviewer = "approvals_reviewer"
        case sandboxMode = "sandbox_mode"
        case networkAccess = "network_access"
        case personality
        case config
        case baseInstructions = "base_instructions"
        case developerInstructions = "developer_instructions"
        case outputSchema = "output_schema"
        case serviceName = "service_name"
        case sessionStartSource = "session_start_source"
        case threadSource = "thread_source"
        case collaborationMode = "collaboration_mode"
        case planGuidanceEnabled = "plan_guidance_enabled"
    }

    init(
        model: String? = CodexAppServerDefaults.model,
        modelProvider: String? = nil,
        serviceTier: String? = nil,
        reasoningEffort: CodexAppServerReasoningEffort? = CodexAppServerDefaults.reasoningEffort,
        reasoningSummary: CodexAppServerReasoningSummary? = nil,
        approvalPolicy: CodexAppServerApprovalPolicy = .onRequest,
        approvalsReviewer: String = "user",
        sandboxMode: CodexAppServerSandboxMode = .dangerFullAccess,
        networkAccess: Bool = false,
        personality: CodexAppServerPersonality? = nil,
        config: CodexAppServerJSONValue? = nil,
        baseInstructions: String? = nil,
        developerInstructions: String? = nil,
        outputSchema: CodexAppServerJSONValue? = nil,
        serviceName: String? = nil,
        sessionStartSource: String? = nil,
        threadSource: String? = nil,
        collaborationMode: CollaborationMode? = .default,
        planGuidanceEnabled: Bool = false
    ) {
        self.model = model
        self.modelProvider = modelProvider
        self.serviceTier = serviceTier
        self.reasoningEffort = reasoningEffort
        self.reasoningSummary = reasoningSummary
        self.approvalPolicy = approvalPolicy
        self.approvalsReviewer = approvalsReviewer
        self.sandboxMode = sandboxMode
        self.networkAccess = networkAccess
        self.personality = personality
        self.config = config
        self.baseInstructions = baseInstructions
        self.developerInstructions = developerInstructions
        self.outputSchema = outputSchema
        self.serviceName = serviceName
        self.sessionStartSource = sessionStartSource
        self.threadSource = threadSource
        self.collaborationMode = collaborationMode
        self.planGuidanceEnabled = planGuidanceEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            model: try container.decodeIfPresent(String.self, forKey: .model),
            modelProvider: try container.decodeIfPresent(String.self, forKey: .modelProvider),
            serviceTier: try container.decodeIfPresent(String.self, forKey: .serviceTier),
            reasoningEffort: try container.decodeIfPresent(CodexAppServerReasoningEffort.self, forKey: .reasoningEffort) ?? CodexAppServerDefaults.reasoningEffort,
            reasoningSummary: try container.decodeIfPresent(CodexAppServerReasoningSummary.self, forKey: .reasoningSummary),
            approvalPolicy: try container.decodeIfPresent(CodexAppServerApprovalPolicy.self, forKey: .approvalPolicy) ?? .onRequest,
            approvalsReviewer: try container.decodeIfPresent(String.self, forKey: .approvalsReviewer) ?? "user",
            sandboxMode: try container.decodeIfPresent(CodexAppServerSandboxMode.self, forKey: .sandboxMode) ?? .dangerFullAccess,
            networkAccess: try container.decodeIfPresent(Bool.self, forKey: .networkAccess) ?? false,
            personality: try container.decodeIfPresent(CodexAppServerPersonality.self, forKey: .personality),
            config: try container.decodeIfPresent(CodexAppServerJSONValue.self, forKey: .config),
            baseInstructions: try container.decodeIfPresent(String.self, forKey: .baseInstructions),
            developerInstructions: try container.decodeIfPresent(String.self, forKey: .developerInstructions),
            outputSchema: try container.decodeIfPresent(CodexAppServerJSONValue.self, forKey: .outputSchema),
            serviceName: try container.decodeIfPresent(String.self, forKey: .serviceName),
            sessionStartSource: try container.decodeIfPresent(String.self, forKey: .sessionStartSource),
            threadSource: try container.decodeIfPresent(String.self, forKey: .threadSource),
            collaborationMode: try container.decodeIfPresent(CollaborationMode.self, forKey: .collaborationMode) ?? .default,
            planGuidanceEnabled: try container.decodeIfPresent(Bool.self, forKey: .planGuidanceEnabled) ?? false
        )
    }

    static let `default` = CodexAppServerTurnOptions(
        model: CodexAppServerDefaults.model,
        modelProvider: nil,
        serviceTier: nil,
        reasoningEffort: CodexAppServerDefaults.reasoningEffort,
        reasoningSummary: nil,
        approvalPolicy: .onRequest,
        approvalsReviewer: "user",
        sandboxMode: .dangerFullAccess,
        networkAccess: false,
        personality: nil,
        config: nil,
        baseInstructions: nil,
        developerInstructions: nil,
        outputSchema: nil,
        serviceName: nil,
        sessionStartSource: nil,
        threadSource: nil,
        collaborationMode: .default,
        planGuidanceEnabled: false
    )

    func sanitizedForStandardComposer() -> CodexAppServerTurnOptions {
        var sanitized = self
        // 标准模式只保留用户能从主工具栏明确选择的运行偏好；权限按钮现在是主工具栏的一部分，
        // 因此保留安全的审批/沙盒预设，但仍清掉高级 JSON、网络访问和其它隐藏运行时字段。
        sanitized.applyStandardComposerPermissionPreset()
        sanitized.modelProvider = nil
        sanitized.networkAccess = false
        sanitized.config = nil
        sanitized.baseInstructions = nil
        sanitized.developerInstructions = nil
        sanitized.outputSchema = nil
        sanitized.serviceName = nil
        sanitized.sessionStartSource = nil
        sanitized.threadSource = nil
        sanitized.collaborationMode = .default
        sanitized.planGuidanceEnabled = false
        return sanitized
    }

    private mutating func applyStandardComposerPermissionPreset() {
        let reviewer = approvalsReviewer.trimmingCharacters(in: .whitespacesAndNewlines)
        if sandboxMode == .readOnly {
            approvalPolicy = .onRequest
            approvalsReviewer = "user"
            return
        }
        if sandboxMode == .dangerFullAccess {
            approvalPolicy = .onRequest
            approvalsReviewer = "user"
            return
        }
        if approvalPolicy == .onFailure, reviewer == "auto_review" {
            approvalsReviewer = reviewer
            sandboxMode = .workspaceWrite
            return
        }
        approvalPolicy = .onRequest
        approvalsReviewer = "user"
        sandboxMode = .workspaceWrite
    }

    func turnParams(projectPath: String) -> [String: CodexAppServerJSONValue?] {
        [
            "model": model.flatMap(nonEmptyString).map { .string($0) },
            "serviceTier": serviceTier.flatMap(nonEmptyString).map { .string($0) },
            "effort": reasoningEffort.map { .string($0.rawValue) },
            "summary": reasoningSummary.map { .string($0.rawValue) },
            "approvalPolicy": .string(approvalPolicy.rawValue),
            "approvalsReviewer": .string(approvalsReviewer),
            "sandboxPolicy": sandboxPolicy(projectPath: projectPath),
            "personality": personality.map { .string($0.rawValue) },
            "outputSchema": outputSchema,
            // app-server 会把 collaboration mode 作为 turn 级状态处理；普通模式也必须显式发送
            // default，避免上一轮 Plan Mode 在上游被沿用。
            "collaborationMode": collaborationModePayload(mode: collaborationMode ?? .default)
        ]
    }

    func threadParams(projectPath: String) -> [String: CodexAppServerJSONValue?] {
        [
            "model": model.flatMap(nonEmptyString).map { .string($0) },
            "modelProvider": modelProvider.flatMap(nonEmptyString).map { .string($0) },
            "serviceTier": serviceTier.flatMap(nonEmptyString).map { .string($0) },
            "approvalPolicy": .string(approvalPolicy.rawValue),
            "approvalsReviewer": .string(approvalsReviewer),
            "sandbox": .string(threadSandboxValue),
            "personality": personality.map { .string($0.rawValue) },
            "config": config,
            "serviceName": serviceName.flatMap(nonEmptyString).map { .string($0) },
            "baseInstructions": baseInstructions.flatMap(nonEmptyString).map { .string($0) },
            "developerInstructions": developerInstructions.flatMap(nonEmptyString).map { .string($0) },
            "sessionStartSource": sessionStartSource.flatMap(nonEmptyString).map { .string($0) },
            "threadSource": threadSource.flatMap(nonEmptyString).map { .string($0) }
        ]
    }

    private func sandboxPolicy(projectPath: String) -> CodexAppServerJSONValue {
        switch sandboxMode {
        case .readOnly:
            return .object([
                "type": .string("readOnly"),
                "networkAccess": .bool(networkAccess)
            ])
        case .workspaceWrite:
            return .object([
                "type": .string("workspaceWrite"),
                "writableRoots": .array([.string(projectPath)]),
                "networkAccess": .bool(networkAccess),
                "excludeTmpdirEnvVar": .bool(false),
                "excludeSlashTmp": .bool(false)
            ])
        case .dangerFullAccess:
            return .object([
                "type": .string("dangerFullAccess"),
                "networkAccess": .bool(networkAccess)
            ])
        }
    }

    private var threadSandboxValue: String {
        switch sandboxMode {
        case .readOnly:
            return "read-only"
        case .workspaceWrite:
            return "workspace-write"
        case .dangerFullAccess:
            return "danger-full-access"
        }
    }

    private func nonEmptyString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private func collaborationModePayload(mode: CollaborationMode) -> CodexAppServerJSONValue {
        // Plan/default 都带 settings：Plan 用于启用规划协作，default 用于明确退出规划协作。
        // developer_instructions 固定 null，表示使用 Codex 内置指令，避免移动端透传危险自定义指令。
        var settings: [String: CodexAppServerJSONValue] = [
            "reasoning_effort": reasoningEffort.map { .string($0.rawValue) } ?? .null,
            "developer_instructions": .null
        ]
        // 默认模型交给 app-server 根据账号 rollout 选择；只有用户显式选模型时才透传，避免
        // 硬编码模型在没有 rollout 权限的账号上触发 “no rollout found”。
        if let model = model.flatMap(nonEmptyString) {
            settings["model"] = .string(model)
        }
        return .object([
            "mode": .string(mode.rawValue),
            "settings": .object(settings)
        ])
    }
}

struct CodexAppServerTurnPayload: Codable, Hashable {
    var input: [CodexAppServerUserInput]
    var options: CodexAppServerTurnOptions

    init(input: [CodexAppServerUserInput], options: CodexAppServerTurnOptions = .default) {
        self.input = input
        self.options = options
    }

    init(prompt: String, options: CodexAppServerTurnOptions = .default) {
        self.input = Self.defaultInput(for: prompt)
        self.options = options
    }

    var isEmpty: Bool {
        input.allSatisfy { item in
            switch item {
            case .text(let text, _):
                return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default:
                return false
            }
        }
    }

    var previewText: String {
        input.map(\.previewText)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var textPrompt: String {
        input.compactMap { item in
            if case .text(let text, _) = item {
                return text
            }
            return nil
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var appServerInput: CodexAppServerJSONValue {
        .array(input.map(\.jsonValue))
    }

    func retainedAfterAcceptedSend() -> CodexAppServerTurnPayload? {
        let retainedInput = input.compactMap(\.retainedAfterAcceptedSend)
        let retained = CodexAppServerTurnPayload(input: retainedInput, options: options)
        if retained.input.isEmpty && retained.options == .default {
            return nil
        }
        return retained
    }

    static func defaultInput(for prompt: String) -> [CodexAppServerUserInput] {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [.text(trimmed)]
    }
}

struct CodexAppServerModelOption: Codable, Hashable, Identifiable {
    let model: String
    let title: String
    let provider: String?
    let description: String?
    let isDefault: Bool

    init(
        id: String,
        title: String? = nil,
        provider: String? = nil,
        description: String? = nil,
        isDefault: Bool = false
    ) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = trimmedID
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? trimmedID
        self.provider = provider?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.description = description?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.isDefault = isDefault
    }

    var id: String {
        guard let provider else {
            return model
        }
        return "\(model)@\(provider)"
    }

    var menuTitle: String {
        guard let provider else {
            return title
        }
        return "\(title) · \(provider)"
    }

    static let builtInFallback: [CodexAppServerModelOption] = [
        CodexAppServerModelOption(id: "gpt-5.5", title: "GPT-5.5", isDefault: true),
        CodexAppServerModelOption(id: "gpt-5-codex", title: "gpt-5-codex"),
        CodexAppServerModelOption(id: "gpt-5.1-codex", title: "gpt-5.1-codex"),
        CodexAppServerModelOption(id: "gpt-5", title: "gpt-5"),
        CodexAppServerModelOption(id: "gpt-5.1", title: "gpt-5.1")
    ]

    static func parseListResult(_ result: CodexAppServerJSONValue?) -> [CodexAppServerModelOption] {
        let rawItems = modelItems(from: result)
        var seen: Set<String> = []
        var options: [CodexAppServerModelOption] = []
        for item in rawItems {
            guard let option = option(from: item), !seen.contains(option.id) else {
                continue
            }
            seen.insert(option.id)
            options.append(option)
        }
        return options.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault {
                return lhs.isDefault
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private static func modelItems(from result: CodexAppServerJSONValue?) -> [CodexAppServerJSONValue] {
        guard let result else {
            return []
        }
        if let items = result.arrayValue {
            return items
        }
        guard let object = result.objectValue else {
            return []
        }
        for key in ["models", "data", "items"] {
            if let items = object[key]?.arrayValue {
                return items
            }
            if let keyed = object[key]?.objectValue {
                return keyed.map { key, value in
                    if var object = value.objectValue {
                        object["id"] = object["id"] ?? .string(key)
                        return .object(object)
                    }
                    return .object(["id": .string(key), "title": value])
                }
            }
        }
        return object.map { key, value in
            if var item = value.objectValue {
                item["id"] = item["id"] ?? .string(key)
                return .object(item)
            }
            return .object(["id": .string(key), "title": value])
        }
    }

    private static func option(from item: CodexAppServerJSONValue) -> CodexAppServerModelOption? {
        if let id = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return CodexAppServerModelOption(id: id)
        }
        guard let object = item.objectValue else {
            return nil
        }
        let id = firstString(in: object, keys: ["id", "model", "name", "slug"])
        guard let id, !id.isEmpty else {
            return nil
        }
        return CodexAppServerModelOption(
            id: id,
            title: firstString(in: object, keys: ["title", "label", "displayName", "display_name", "name"]),
            provider: firstString(in: object, keys: ["provider", "modelProvider", "model_provider"]),
            description: firstString(in: object, keys: ["description", "summary"]),
            // app-server 历史返回里默认标记存在 camelCase 和 snake_case 两种形态。
            isDefault: object["isDefault"]?.boolValue ?? object["is_default"]?.boolValue ?? object["default"]?.boolValue ?? false
        )
    }

    private static func firstString(in object: [String: CodexAppServerJSONValue], keys: [String]) -> String? {
        for key in keys {
            let value = object[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

indirect enum CodexAppServerJSONValue: Codable, Hashable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case object([String: CodexAppServerJSONValue])
    case array([CodexAppServerJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CodexAppServerJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: CodexAppServerJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "app-server JSON 值格式无效")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        default:
            return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let value):
            return Int(value)
        case .double(let value):
            return Int(value)
        case .string(let value):
            return Int(value)
        default:
            return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self {
            return value
        }
        return nil
    }

    var objectValue: [String: CodexAppServerJSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }

    var arrayValue: [CodexAppServerJSONValue]? {
        if case .array(let value) = self {
            return value
        }
        return nil
    }

    subscript(key: String) -> CodexAppServerJSONValue? {
        objectValue?[key]
    }

    static func objectValue(_ values: [String: CodexAppServerJSONValue?]) -> CodexAppServerJSONValue {
        .object(values.compactMapValues { $0 })
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

enum CodexAppServerRequestID: Codable, Hashable, CustomStringConvertible {
    case int(Int64)
    case string(String)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "JSON-RPC id 必须是 string、number 或 null")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var description: String {
        switch self {
        case .int(let value):
            return String(value)
        case .string(let value):
            return value
        case .null:
            return "null"
        }
    }
}

struct CodexAppServerRequest: Codable, Hashable {
    let id: CodexAppServerRequestID
    let method: String
    let params: CodexAppServerJSONValue?

    enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case method
        case params
    }

    init(id: CodexAppServerRequestID, method: String, params: CodexAppServerJSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(CodexAppServerRequestID.self, forKey: .id)
        self.method = try container.decode(String.self, forKey: .method)
        self.params = try container.decodeIfPresent(CodexAppServerJSONValue.self, forKey: .params)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Codex app-server 线路格式会省略 jsonrpc 字段；这里保持原样，避免 Swift 端引入额外协议差异。
        try container.encode(id, forKey: .id)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
    }
}

struct CodexAppServerNotification: Codable, Hashable {
    let method: String
    let params: CodexAppServerJSONValue?

    enum CodingKeys: String, CodingKey {
        case jsonrpc
        case method
        case params
    }

    init(method: String, params: CodexAppServerJSONValue? = nil) {
        self.method = method
        self.params = params
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.method = try container.decode(String.self, forKey: .method)
        self.params = try container.decodeIfPresent(CodexAppServerJSONValue.self, forKey: .params)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
    }
}

struct CodexAppServerServerRequest: Codable, Hashable {
    let id: CodexAppServerRequestID
    let method: String
    let params: CodexAppServerJSONValue?

    init(id: CodexAppServerRequestID, method: String, params: CodexAppServerJSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

struct CodexAppServerError: Codable, Hashable, LocalizedError {
    let code: Int
    let message: String
    let data: CodexAppServerJSONValue?

    var errorDescription: String? {
        "app-server 错误 \(code)：\(message)"
    }
}

struct CodexAppServerResponse: Codable, Hashable {
    let id: CodexAppServerRequestID
    let result: CodexAppServerJSONValue?
    let error: CodexAppServerError?

    enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case result
        case error
    }

    init(id: CodexAppServerRequestID, result: CodexAppServerJSONValue? = nil, error: CodexAppServerError? = nil) {
        self.id = id
        self.result = result
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(CodexAppServerRequestID.self, forKey: .id)
        self.result = try container.decodeIfPresent(CodexAppServerJSONValue.self, forKey: .result)
        self.error = try container.decodeIfPresent(CodexAppServerError.self, forKey: .error)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

enum CodexAppServerMessage: Hashable {
    case response(CodexAppServerResponse)
    case notification(CodexAppServerNotification)
    case serverRequest(CodexAppServerServerRequest)
}

extension CodexAppServerMessage: Decodable {
    enum CodingKeys: String, CodingKey {
        case id
        case method
        case params
        case result
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let method = try container.decodeIfPresent(String.self, forKey: .method) {
            let params = try container.decodeIfPresent(CodexAppServerJSONValue.self, forKey: .params)
            if container.contains(.id) {
                self = .serverRequest(CodexAppServerServerRequest(
                    id: try container.decode(CodexAppServerRequestID.self, forKey: .id),
                    method: method,
                    params: params
                ))
            } else {
                self = .notification(CodexAppServerNotification(method: method, params: params))
            }
            return
        }
        guard container.contains(.id) else {
            throw DecodingError.keyNotFound(
                CodingKeys.id,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "JSON-RPC 响应缺少 id")
            )
        }
        self = .response(CodexAppServerResponse(
            id: try container.decode(CodexAppServerRequestID.self, forKey: .id),
            result: try container.decodeIfPresent(CodexAppServerJSONValue.self, forKey: .result),
            error: try container.decodeIfPresent(CodexAppServerError.self, forKey: .error)
        ))
    }
}

struct CodexAppServerRequestSpec: Hashable {
    let method: String
    let params: CodexAppServerJSONValue?

    init(method: String, params: CodexAppServerJSONValue? = .object([:])) {
        self.method = method
        self.params = params
    }

    func request(id: CodexAppServerRequestID) -> CodexAppServerRequest {
        CodexAppServerRequest(id: id, method: method, params: params)
    }
}

enum CodexAppServerRequestBuilderError: LocalizedError, Equatable {
    case projectNotAllowlisted(String)
    case pathNotAllowlisted(String)
    case unsafeParameter(String)

    var errorDescription: String? {
        switch self {
        case .projectNotAllowlisted(let id):
            return "项目不在远程 allowlist 中：\(id)"
        case .pathNotAllowlisted(let path):
            return "工作目录不在远程 allowlist 中：\(path)"
        case .unsafeParameter(let reason):
            return "app-server 请求参数不安全：\(reason)"
        }
    }
}

struct CodexAppServerRequestBuilder {
    private let projectsByID: [String: AgentProject]
    private let allowlistedPaths: Set<String>

    init(allowlistedProjects: [AgentProject]) {
        self.projectsByID = Dictionary(uniqueKeysWithValues: allowlistedProjects.map { ($0.id, $0) })
        self.allowlistedPaths = Set(allowlistedProjects.map(\.path).compactMap(Self.standardizedAllowlistPath))
    }

    func threadList(cwd: String, limit: Int? = 20, cursor: String? = nil) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        return CodexAppServerRequestSpec(method: "thread/list", params: CodexAppServerJSONValue.objectValue([
            "cwd": .string(path),
            "limit": limit.map { .int(Int64($0)) },
            "cursor": cursor.map { .string($0) }
        ]))
    }

    func modelList() -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "model/list")
    }

    func threadStart(projectID: String, model: String? = nil, options: CodexAppServerTurnOptions = .default) throws -> CodexAppServerRequestSpec {
        var resolved = options
        if resolved.model == nil {
            resolved.model = model
        }
        return try threadStart(cwd: pathForProject(id: projectID), options: resolved)
    }

    func threadStart(cwd: String, model: String? = nil, options: CodexAppServerTurnOptions = .default) throws -> CodexAppServerRequestSpec {
        var resolved = options
        if resolved.model == nil {
            resolved.model = model
        }
        return try threadStart(cwd: cwd, options: resolved)
    }

    func threadStart(cwd: String, options: CodexAppServerTurnOptions = .default) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        var params = safeThreadRuntimeParams(cwd: path)
        options.threadParams(projectPath: path).forEach { key, value in
            params[key] = value
        }
        try validateRemoteSafeParams(params, projectPath: path)
        return CodexAppServerRequestSpec(method: "thread/start", params: .object(params.compactMapValues { $0 }))
    }

    func threadResume(threadID: String, projectID: String, model: String? = nil, options: CodexAppServerTurnOptions = .default) throws -> CodexAppServerRequestSpec {
        var resolved = options
        if resolved.model == nil {
            resolved.model = model
        }
        return try threadResume(threadID: threadID, cwd: pathForProject(id: projectID), options: resolved)
    }

    func threadResume(threadID: String, cwd: String, model: String? = nil, options: CodexAppServerTurnOptions = .default) throws -> CodexAppServerRequestSpec {
        var resolved = options
        if resolved.model == nil {
            resolved.model = model
        }
        return try threadResume(threadID: threadID, cwd: cwd, options: resolved)
    }

    func threadResume(threadID: String, cwd: String, options: CodexAppServerTurnOptions = .default) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        var params = safeThreadRuntimeParams(cwd: path)
        params["threadId"] = .string(threadID)
        params["excludeTurns"] = .bool(true)
        params["ephemeral"] = nil
        options.threadParams(projectPath: path).forEach { key, value in
            params[key] = value
        }
        try validateRemoteSafeParams(params, projectPath: path)
        return CodexAppServerRequestSpec(method: "thread/resume", params: .object(params.compactMapValues { $0 }))
    }

    func threadFork(threadID: String, cwd: String, options: CodexAppServerTurnOptions = .default) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        var params = safeThreadRuntimeParams(cwd: path)
        params["threadId"] = .string(threadID)
        options.threadParams(projectPath: path).forEach { key, value in
            params[key] = value
        }
        params["sessionStartSource"] = nil
        try validateRemoteSafeParams(params, projectPath: path)
        return CodexAppServerRequestSpec(method: "thread/fork", params: .object(params.compactMapValues { $0 }))
    }

    func threadRead(threadID: String, includeTurns: Bool = true) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "thread/read", params: CodexAppServerJSONValue.objectValue([
            "threadId": .string(threadID),
            "includeTurns": .bool(includeTurns)
        ]))
    }

    func threadTurnsList(
        threadID: String,
        cursor: String? = nil,
        limit: Int? = 40,
        sortDirection: String = "desc",
        itemsView: String = "full"
    ) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "thread/turns/list", params: CodexAppServerJSONValue.objectValue([
            "threadId": .string(threadID),
            "cursor": cursor.map { .string($0) },
            "limit": limit.map { .int(Int64($0)) },
            "sortDirection": .string(sortDirection),
            "itemsView": .string(itemsView)
        ]))
    }

    func threadGoalGet(threadID: String) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "thread/goal/get", params: CodexAppServerJSONValue.objectValue([
            "threadId": .string(threadID)
        ]))
    }

    func threadGoalSet(
        threadID: String,
        objective: String? = nil,
        status: ThreadGoalStatus? = nil,
        tokenBudget: Int64? = nil
    ) -> CodexAppServerRequestSpec {
        // 目标状态由 app-server 持久化；iPad 端只提交明确变化的字段。
        CodexAppServerRequestSpec(method: "thread/goal/set", params: CodexAppServerJSONValue.objectValue([
            "threadId": .string(threadID),
            "objective": objective.map { .string($0) },
            "status": status.map { .string($0.rawValue) },
            "tokenBudget": tokenBudget.map { .int($0) }
        ]))
    }

    func threadGoalClear(threadID: String) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "thread/goal/clear", params: CodexAppServerJSONValue.objectValue([
            "threadId": .string(threadID)
        ]))
    }

    func threadArchive(threadID: String) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "thread/archive", params: CodexAppServerJSONValue.objectValue([
            "threadId": .string(threadID)
        ]))
    }

    func threadUnarchive(threadID: String) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "thread/unarchive", params: CodexAppServerJSONValue.objectValue([
            "threadId": .string(threadID)
        ]))
    }

    func turnStart(
        threadID: String,
        projectID: String,
        prompt: String,
        clientMessageID: ClientMessageID? = nil
    ) throws -> CodexAppServerRequestSpec {
        try turnStart(
            threadID: threadID,
            cwd: pathForProject(id: projectID),
            payload: CodexAppServerTurnPayload(prompt: prompt),
            clientMessageID: clientMessageID
        )
    }

    func turnStart(
        threadID: String,
        cwd: String,
        prompt: String,
        clientMessageID: ClientMessageID? = nil
    ) throws -> CodexAppServerRequestSpec {
        try turnStart(
            threadID: threadID,
            cwd: cwd,
            payload: CodexAppServerTurnPayload(prompt: prompt),
            clientMessageID: clientMessageID
        )
    }

    func turnStart(
        threadID: String,
        projectID: String,
        payload: CodexAppServerTurnPayload,
        clientMessageID: ClientMessageID? = nil
    ) throws -> CodexAppServerRequestSpec {
        try turnStart(threadID: threadID, cwd: pathForProject(id: projectID), payload: payload, clientMessageID: clientMessageID)
    }

    func turnStart(
        threadID: String,
        cwd: String,
        payload: CodexAppServerTurnPayload,
        clientMessageID: ClientMessageID? = nil
    ) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        var params: [String: CodexAppServerJSONValue?] = [
            "threadId": .string(threadID),
            "cwd": .string(path),
            "input": payload.appServerInput,
            "clientUserMessageId": clientMessageID.map { .string($0) }
        ]
        payload.options.turnParams(projectPath: path).forEach { key, value in
            params[key] = value
        }
        try validateRemoteSafeParams(params, projectPath: path)
        return CodexAppServerRequestSpec(method: "turn/start", params: .object(params.compactMapValues { $0 }))
    }

    func turnSteer(
        threadID: String,
        cwd: String,
        payload: CodexAppServerTurnPayload,
        clientMessageID: ClientMessageID? = nil,
        expectedTurnID: TurnID
    ) throws -> CodexAppServerRequestSpec {
        let path = try allowlistedPath(cwd)
        let params: [String: CodexAppServerJSONValue?] = [
            "threadId": .string(threadID),
            "input": payload.appServerInput,
            "clientUserMessageId": clientMessageID.map { .string($0) },
            "expectedTurnId": .string(expectedTurnID)
        ]
        // steer 是对当前 active turn 的补充输入，不携带模型/权限等 turn 启动参数；
        // 这里只复用结构化输入校验，确保附件路径仍然来自 allowlist。
        try validateRemoteSafeParams(params, projectPath: path)
        return CodexAppServerRequestSpec(method: "turn/steer", params: .object(params.compactMapValues { $0 }))
    }

    func turnInterrupt(threadID: String, turnID: String) -> CodexAppServerRequestSpec {
        CodexAppServerRequestSpec(method: "turn/interrupt", params: CodexAppServerJSONValue.objectValue([
            "threadId": .string(threadID),
            "turnId": .string(turnID)
        ]))
    }

    func validateRemoteSafeParams(_ params: CodexAppServerJSONValue, projectPath: String) throws {
        let path = try allowlistedPath(projectPath)
        guard let object = params.objectValue else {
            throw CodexAppServerRequestBuilderError.unsafeParameter("params 必须是 object")
        }
        try validateRemoteSafeParams(object.mapValues { Optional($0) }, projectPath: path)
    }

    private func pathForProject(id: String) throws -> String {
        guard let project = projectsByID[id] else {
            throw CodexAppServerRequestBuilderError.projectNotAllowlisted(id)
        }
        return try allowlistedPath(project.path)
    }

    private func allowlistedPath(_ path: String) throws -> String {
        let standardized = Self.standardizedAllowlistPath(path) ?? ""
        guard allowlistedPaths.contains(standardized) else {
            throw CodexAppServerRequestBuilderError.pathNotAllowlisted(path.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return standardized
    }

    private func safeThreadRuntimeParams(cwd: String) -> [String: CodexAppServerJSONValue?] {
        [
            "cwd": .string(cwd),
            // thread/start 只建立 app-server thread，使用 proven app-server 字段，不发送 runtimeWorkspaceRoots。
            "approvalPolicy": .string("on-request"),
            "approvalsReviewer": .string("user"),
            "sandbox": .string("danger-full-access"),
            "ephemeral": .bool(false)
        ]
    }

    private func validateRemoteSafeParams(_ params: [String: CodexAppServerJSONValue?], projectPath: String) throws {
        if let cwd = params["cwd"]??.stringValue, cwd != projectPath {
            throw CodexAppServerRequestBuilderError.unsafeParameter("cwd 必须来自项目 allowlist")
        }
        if normalizedDangerToken(params["approvalPolicy"]??.stringValue) == "never" {
            throw CodexAppServerRequestBuilderError.unsafeParameter("approvalPolicy=never 被禁止")
        }
        try validateNoDangerousConfig(params["config"] ?? nil)
        guard let sandbox = params["sandboxPolicy"]??.objectValue else {
            return
        }
        // 默认允许用户批准下的最高文件系统权限，但仍不默认打开网络访问。
        if sandbox["networkAccess"]?.boolValue == true {
            throw CodexAppServerRequestBuilderError.unsafeParameter("远程默认禁止网络访问")
        }
        let writableRoots = sandbox["writableRoots"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if writableRoots.contains(where: { $0 != projectPath }) {
            throw CodexAppServerRequestBuilderError.unsafeParameter("writableRoots 只能包含当前 allowlist 项目")
        }
        let inputPaths = try collectWorkspaceInputPaths(params["input"] ?? nil)
        if inputPaths.contains(where: { !isPathInAllowlist($0) }) {
            throw CodexAppServerRequestBuilderError.unsafeParameter("结构化输入路径必须来自当前 allowlist 项目")
        }
    }

    private func normalizedDangerToken(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    private func collectWorkspaceInputPaths(_ input: CodexAppServerJSONValue?) throws -> [String] {
        guard let items = input?.arrayValue else {
            return []
        }
        var paths: [String] = []
        for item in items {
            guard let object = item.objectValue else {
                throw CodexAppServerRequestBuilderError.unsafeParameter("turn/start.input item 必须是 object")
            }
            let type = object["type"]?.stringValue ?? ""
            switch type {
            case "localImage", "mention":
                guard let path = object["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
                    throw CodexAppServerRequestBuilderError.unsafeParameter("turn/start.input.\(type).path 不能为空")
                }
                paths.append(path)
            case "skill":
                // Skill 可能来自用户级 / 管理员级 skill root 或插件缓存，不一定在当前项目 allowlist 内。
                // 这里只校验字段完整性；skill root 的来源可信度由 agentd capabilities / app-server 负责。
                guard let path = object["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
                    throw CodexAppServerRequestBuilderError.unsafeParameter("turn/start.input.skill.path 不能为空")
                }
            case "image":
                let url = object["url"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !url.isEmpty else {
                    throw CodexAppServerRequestBuilderError.unsafeParameter("turn/start.input.image.url 不能为空")
                }
                if url.lowercased().hasPrefix("file:") {
                    throw CodexAppServerRequestBuilderError.unsafeParameter("image.url 不允许 file URL，请使用 localImage.path")
                }
            case "text":
                continue
            default:
                throw CodexAppServerRequestBuilderError.unsafeParameter("turn/start.input 类型不支持：\(type)")
            }
        }
        return paths
    }

    private func isPathInAllowlist(_ raw: String) -> Bool {
        guard let path = Self.standardizedAllowlistPath(raw) else {
            return false
        }
        return allowlistedPaths.contains { root in
            path == root || path.hasPrefix(root + "/")
        }
    }

    private func validateNoDangerousConfig(_ value: CodexAppServerJSONValue?, parentKey: String? = nil) throws {
        guard let value else {
            return
        }
        switch value {
        case .object(let object):
            for (key, child) in object {
                let normalizedKey = normalizedDangerToken(key)
                if normalizedKey == "dangerfullaccess" {
                    throw CodexAppServerRequestBuilderError.unsafeParameter("config 不允许 dangerFullAccess")
                }
                if normalizedKey == "approvalpolicy",
                   normalizedDangerToken(child.stringValue) == "never" {
                    throw CodexAppServerRequestBuilderError.unsafeParameter("config 不允许 approvalPolicy=never")
                }
                if normalizedKey == "sandbox" || normalizedKey == "sandboxmode" || (parentKey == "sandboxpolicy" && normalizedKey == "type"),
                   normalizedDangerToken(child.stringValue) == "dangerfullaccess" {
                    throw CodexAppServerRequestBuilderError.unsafeParameter("config 不允许 dangerFullAccess")
                }
                if normalizedKey == "networkaccess",
                   child.boolValue == true || child.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true" {
                    throw CodexAppServerRequestBuilderError.unsafeParameter("config 不允许 networkAccess=true")
                }
                try validateNoDangerousConfig(child, parentKey: normalizedKey)
            }
        case .array(let values):
            for child in values {
                try validateNoDangerousConfig(child, parentKey: parentKey)
            }
        default:
            return
        }
    }

    private static func standardizedAllowlistPath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }
}
