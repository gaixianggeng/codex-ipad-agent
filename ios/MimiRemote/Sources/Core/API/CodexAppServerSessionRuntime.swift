import Foundation
enum CodexAppServerSessionRuntimeError: LocalizedError {
    case invalidGatewayURL
    case gatewayUnavailable
    case threadSearchUnavailable
    case projectNotFound(String)
    case projectRequired
    case sessionNotFound(SessionID)
    case missingActiveTurn(SessionID)
    case approvalNotFound(String)
    case userInputRequestNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidGatewayURL:
            return L10n.text("ui.app_server_gateway_url_is_invalid")
        case .gatewayUnavailable:
            return L10n.text("ui.agentd_does_not_enable_app_server_gateway_please")
        case .threadSearchUnavailable:
            return L10n.text("ui.currently_agentd_or_codex_app_server_does_not")
        case .projectNotFound(let projectID):
            return L10n.format("ui.the_project_does_not_exist_or_is_not", projectID)
        case .projectRequired:
            return L10n.text("ui.direct_mode_must_first_select_the_allowlist_item")
        case .sessionNotFound(let sessionID):
            return L10n.format("ui.app_server_thread_does_not_exist_value", sessionID)
        case .missingActiveTurn(let sessionID):
            return L10n.format("ui.there_is_no_interruptible_active_turn_for_the", sessionID)
        case .approvalNotFound(let approvalID):
            return L10n.format("ui.approval_request_has_expired_value", approvalID)
        case .userInputRequestNotFound(let requestID):
            return L10n.format("ui.the_request_for_additional_information_has_expired_value", requestID)
        }
    }
}

struct CodexAppServerSessionContext {
    var session: AgentSession
    var cwd: String
    var activeTurnID: TurnID?
}

struct CodexAppServerPreparedConnection {
    let connection: CodexAppServerConnection
    let notifications: AsyncStream<CodexAppServerNotification>
    let serverRequests: AsyncStream<CodexAppServerServerRequest>
}

struct CodexAppServerResolvedServerRequests {
    var approvalSessionIDs: [SessionID] = []
    var userInputSessionIDs: [SessionID] = []
}

enum CodexAppServerBufferedEventReplayPolicy {
    case all
    case stateOnly
}

actor CodexAppServerSessionRuntime {
    let endpoint: String
    let token: String
    let runtimeProvider: String
    let transportFactory: () -> CodexAppServerTransport
    let configProvider: () async throws -> CodexAppServerConfigResponse
    var config: CodexAppServerConfigResponse?
    var connection: CodexAppServerConnection?
    var connectionTask: Task<CodexAppServerPreparedConnection, Error>?
    var notificationPumpTask: Task<Void, Never>?
    var serverRequestPumpTask: Task<Void, Never>?
    var projector = CodexAppServerEventProjector()
    var contextsBySessionID: [SessionID: CodexAppServerSessionContext] = [:]
    // app-server 只向「在当前 gateway 连接上 resume/start 过」的 thread 推送 turn 事件；记录本连接已
    // 经绑定的 thread，断线重连后这个集合随新连接清空，确保再次发送时会先补一次 thread/resume。
    var threadsResumedOnConnection: Set<SessionID> = []
    var bufferedEventsBySessionID: [SessionID: [AgentEvent]] = [:]
    var eventMailboxesBySessionID: [
        SessionID: [UUID: CodexAppServerEventMailbox]
    ] = [:]
    var pendingApprovalRequestsByID: [String: CodexAppServerServerRequest] = [:]
    var pendingUserInputRequestsByID: [String: CodexAppServerServerRequest] = [:]
    var userInputPromptsEnabledBySessionID: [SessionID: Bool] = [:]
    var accountRateLimit: RateLimitSummary?
    var rateLimitRefreshTask: Task<RateLimitSummary?, Never>?
    var lastRateLimitRefreshAt: Date?
    // 正在 startTurn 中的 thread：turn/start 请求挂起期间，actor 会重入处理 server-request，
    // 此时本地还没记上 activeTurnID、状态也可能仍是空闲。这一窗口内到达的审批一定属于刚发起的
    // 新 turn，不能被 isStaleReplayedApproval 误判成过期重放。
    var sessionsStartingTurn: Set<SessionID> = []
    // 本端这条 runtime 亲自发起过的 turn。app-server 在 resume 时会重放“仍未应答”的审批；只有属于这些
    // turn 的审批才是当前用户真正在等待的，其余（Desktop 发起、或历史里没 terminal 化的旧审批）需要按
    // 过期处理。即使本端的审批挂了很久也不能误杀，所以单列出来优先放行。
    var turnsStartedByThisRuntime: Set<TurnID> = []
    // thread/read 没有分页参数，一次会返回整段 thread。把上次整段读取缓存下来，翻看更早历史时直接
    // 从缓存切窗口，避免每次翻页都在 Tailscale 这类慢链路上重新拉一遍大会话（会很慢甚至超时）。
    var threadHistoryCacheBySessionID: [SessionID: [CodexHistoryMessage]] = [:]
    var threadAuthoritativeCompletedTurnItemsBySessionID: [SessionID: [TurnID: Set<AgentItemID>]] = [:]
    var threadTurnsListUnavailable = false
    var stateDBOnlyListUnavailable = false
    var stateDBOnlyScanRequiredCWDs: Set<String> = []
    var recencySortUnavailable = false
    var turnStartTasksBySessionID: [SessionID: (token: UUID, task: Task<TurnID?, Error>)] = [:]
    // thread/list 在 Tailscale Peer Relay/DERP 弱链路上可能要扫本机 Codex 历史并传回较大的 JSON。
    // 只给列表请求放宽超时，避免影响 turn/start 等交互命令的失败反馈速度。
    let threadListRequestTimeout: TimeInterval = 60
    let requestTimeout: TimeInterval
    var rateLimitRequestTimeout: TimeInterval {
        // Claude 首次读取可能需要通过交互式 `/status` 刷新 Keychain 凭据；
        // 该请求仍在独立 actor/transport 上等待，不阻塞主线程。Codex 保持原 5 秒上限。
        runtimeProvider == "claude" ? min(requestTimeout, 15) : min(requestTimeout, 5)
    }
    // 每个 thread 最近一次收到上游实时通知的时间。thread/list、thread/read 偶发把正在执行的
    // turn 误读成 idle/notLoaded；刚收到过实时信号的 thread 在这个时间窗内不接受 history 降级。
    var lastLiveSignalAtBySessionID: [SessionID: Date] = [:]
    let historyDowngradeGraceInterval: TimeInterval = 15

    init(
        endpoint: String,
        token: String,
        runtimeProvider: String = "codex",
        transportFactory: @escaping () -> CodexAppServerTransport = { URLSessionCodexAppServerTransport() },
        requestTimeout: TimeInterval = 20,
        configProvider: (() async throws -> CodexAppServerConfigResponse)? = nil
    ) {
        let normalizedEndpoint = AgentAPIClient.normalizedEndpoint(endpoint)
        self.endpoint = normalizedEndpoint
        self.token = token
        self.runtimeProvider = Self.normalizedRuntimeProvider(runtimeProvider)
        self.transportFactory = transportFactory
        self.requestTimeout = requestTimeout
        self.configProvider = configProvider ?? {
            try await AgentAPIClient(endpoint: normalizedEndpoint, token: token).appServerConfig()
        }
    }

    deinit {
        connectionTask?.cancel()
        notificationPumpTask?.cancel()
        serverRequestPumpTask?.cancel()
        rateLimitRefreshTask?.cancel()
    }

    func projects() async throws -> [AgentProject] {
        try await ensureConfig().projects
    }

    func modelOptions() async throws -> [CodexAppServerModelOption] {
        let result = try await sendRecoveringFromStaleInitialization(
            CodexAppServerRequestBuilder(allowlistedProjects: try await projects()).modelList()
        )
        return CodexAppServerModelOption.parseListResult(result).map {
            $0.withRuntimeProvider($0.runtimeProvider ?? runtimeProvider)
        }
    }

    func capabilities(path: String?) async throws -> CapabilityListResponse {
        let legacyClient = AgentAPIClient(endpoint: endpoint, token: token)
        guard let cwd = path?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty else {
            return try await legacyClient.capabilities(path: path)
        }

        // Skill 与已安装插件都以 app-server 的只读列表为准；旧 REST 发现继续作为
        // Skill 兼容兜底并提供 MCP 摘要。plugin/installed 失败时只降级为空列表。
        do {
            let builder = CodexAppServerRequestBuilder(allowlistedProjects: try await projects())
            let skillResult = try await sendRecoveringFromStaleInitialization(
                builder.skillsList(cwd: cwd, forceReload: true)
            )
            let pluginResult = try? await sendRecoveringFromStaleInitialization(
                builder.installedPluginList(cwd: cwd)
            )
            let skills = SkillCapability.parseAppServerListResult(skillResult, cwd: cwd)
            let plugins = CodexPluginCapability.parseAppServerInstalledResult(pluginResult)
            let legacy = try? await legacyClient.capabilities(path: cwd)
            return CapabilityListResponse(
                path: cwd,
                skills: skills.isEmpty ? (legacy?.skills ?? []) : skills,
                mcpServers: legacy?.mcpServers ?? [],
                plugins: plugins
            )
        } catch {
            if let legacy = try? await legacyClient.capabilities(path: cwd) {
                return legacy
            }
            throw error
        }
    }

    func transcribeVoice(filename: String, contentType: String, audioData: Data, language: String?) async throws -> VoiceTranscriptionResponse {
        // 语音转写属于 agentd 控制面：移动端只上传音频，Codex 登录态始终留在 Mac。
        try await AgentAPIClient(endpoint: endpoint, token: token).transcribeVoice(
            filename: filename,
            contentType: contentType,
            audioData: audioData,
            language: language
        )
    }

    func validateDirectGateway() async throws {
        let config = try await ensureConfig(forceRefresh: true)
        guard runtimeGatewayAvailable(in: config) else {
            throw CodexAppServerSessionRuntimeError.gatewayUnavailable
        }
        let gatewayURL = try gatewayURL(from: config)
        let probe = CodexAppServerConnection(transport: transportFactory())
        try await probe.connect(url: gatewayURL, token: token)
        await probe.disconnect()
    }

    func channelAvailable(runtimeProvider raw: String) async throws -> Bool {
        let runtime = Self.normalizedRuntimeProvider(raw)
        let config = try await ensureConfig()
        if runtime == "codex" {
            return true
        }
        return config.channels.contains { channel in
            (Self.normalizedRuntimeProvider(channel.runtimeID ?? channel.id) == runtime ||
                Self.normalizedRuntimeProvider(channel.provider) == runtime) &&
                channel.gatewayAvailable
        }
    }

    func sessionsPage(
        projectID: String?,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency = .fastIndexed
    ) async throws -> SessionsPage {
        let projects = try await projects()
        guard let projectID else {
            throw CodexAppServerSessionRuntimeError.projectRequired
        }
        guard let project = projects.first(where: { $0.id == projectID }) else {
            throw CodexAppServerSessionRuntimeError.projectNotFound(projectID)
        }
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: projects)
        let page = try await threadListPageWithIndexedFallback(
            cwd: project.path,
            cursor: cursor,
            limit: limit,
            builder: builder,
            projects: projects,
            fallbackProject: project,
            consistency: consistency
        )
        for session in page.sessions {
            contextsBySessionID[session.id] = CodexAppServerSessionContext(
                session: session,
                cwd: session.dir,
                activeTurnID: session.activeTurnID
            )
        }
        scheduleRateLimitRefreshIfAvailable()
        return page
    }

    func sessionsPage(
        workspace: AgentWorkspace,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency = .fastIndexed
    ) async throws -> SessionsPage {
        let baseProjects = try await projects()
        let projects = projectsIncludingWorkspace(baseProjects, workspace: workspace)
        let workspaceProject = workspace.project
        let listCWD = threadListCWD(for: workspace, projects: baseProjects)
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: projects)
        let page = try await threadListPageWithIndexedFallback(
            cwd: listCWD,
            cursor: cursor,
            limit: limit,
            builder: builder,
            projects: projects,
            fallbackProject: workspaceProject,
            consistency: consistency
        )
        for session in page.sessions {
            contextsBySessionID[session.id] = CodexAppServerSessionContext(
                session: session,
                cwd: session.dir,
                activeTurnID: session.activeTurnID
            )
        }
        scheduleRateLimitRefreshIfAvailable()
        return page
    }

    func searchSessions(query: String, cursor: String?, limit: Int?) async throws -> ThreadSearchPage {
        let searchTerm = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchTerm.isEmpty else {
            return ThreadSearchPage(results: [])
        }
        let config = try await ensureConfig()
        guard config.policy.allowedMethods.contains("thread/search") else {
            throw CodexAppServerSessionRuntimeError.threadSearchUnavailable
        }
        let projects = config.projects
        let result = try await sendRecoveringFromStaleInitialization(
            try CodexAppServerRequestBuilder(allowlistedProjects: projects).threadSearch(
                query: searchTerm,
                limit: limit,
                cursor: cursor
            ),
            timeout: threadListRequestTimeout
        )
        let page = try threadSearchPage(from: result, projects: projects)
        for session in page.sessions {
            contextsBySessionID[session.id] = CodexAppServerSessionContext(
                session: session,
                cwd: session.dir,
                activeTurnID: session.activeTurnID
            )
        }
        return page
    }

    func resolveWorkspace(path: String) async throws -> AgentWorkspace {
        // resolve 是 agentd 控制面的 REST 接口（非 app-server JSON-RPC），用 runtime 自己的 endpoint/token 直接请求。
        try await AgentAPIClient(endpoint: endpoint, token: token).resolveWorkspace(path: path)
    }

    func createWorktree(path: String, name: String?, base: String?, branch: String?) async throws -> WorktreeCreateResponse {
        // Worktree 是 agentd 管理的本机 Git checkout；创建后返回可直接用于 thread/start 的 workspace。
        try await AgentAPIClient(endpoint: endpoint, token: token).createWorktree(path: path, name: name, base: base, branch: branch)
    }

    func worktreeBranches(path: String) async throws -> WorktreeBranchListResponse {
        // 分支列表是 agentd 控制面的只读 Git 引用发现，不走 app-server JSON-RPC。
        try await AgentAPIClient(endpoint: endpoint, token: token).worktreeBranches(path: path)
    }

    func listWorktrees() async throws -> [WorktreeListItem] {
        // Worktree registry 属于 agentd 控制面状态；列表用于 iPad 管理本机 checkout，不走 app-server。
        try await AgentAPIClient(endpoint: endpoint, token: token).listWorktrees()
    }

    func deleteWorktree(path: String, force: Bool) async throws -> WorktreeDeleteResponse {
        // 删除会改变本机文件系统，所有路径和 managed registry 校验都留在 agentd 后端执行。
        try await AgentAPIClient(endpoint: endpoint, token: token).deleteWorktree(path: path, force: force)
    }

    func pruneMissingWorktrees() async throws -> WorktreePruneResponse {
        // 只清理 agentd registry 中已经不存在的 checkout 登记，不删除真实文件。
        try await AgentAPIClient(endpoint: endpoint, token: token).pruneMissingWorktrees()
    }

    func previewWorktreeCleanup() async throws -> WorktreeCleanupResponse {
        try await AgentAPIClient(endpoint: endpoint, token: token).previewWorktreeCleanup()
    }

    func executeWorktreeCleanup(paths: [String], planID: String) async throws -> WorktreeCleanupResponse {
        try await AgentAPIClient(endpoint: endpoint, token: token).executeWorktreeCleanup(paths: paths, planID: planID)
    }

    func listDirectories(path: String) async throws -> DirectoryListResponse {
        // 目录浏览同样走 agentd 控制面 REST 接口，传空 path 表示从服务端默认浏览根开始。
        try await AgentAPIClient(endpoint: endpoint, token: token).listDirectories(path: path)
    }

    func readFile(path: String) async throws -> FileReadResponse {
        // 文件预览只通过 agentd 控制面读取授权边界内的普通文件，iPad 端不直接访问本机文件系统。
        try await AgentAPIClient(endpoint: endpoint, token: token).readFile(path: path)
    }

    func readHistoryMedia(id: String) async throws -> FileReadResponse {
        // 历史媒体是 gateway 脱水后生成的短期缓存，只在用户点按历史图片占位时读取。
        try await AgentAPIClient(endpoint: endpoint, token: token).readHistoryMedia(id: id)
    }

    func commandActions(path: String) async throws -> [AgentCommandAction] {
        // 快捷动作是 agentd 配置的 allowlist 能力，只在控制面列出，不让 app-server 接触命令定义。
        try await AgentAPIClient(endpoint: endpoint, token: token).commandActions(path: path)
    }

    func runCommandAction(path: String, id: String, confirmed: Bool) async throws -> CommandActionRunResponse {
        // 执行动作会改变本机状态或产生副作用，统一交给 agentd 做路径和 action ID 校验。
        try await AgentAPIClient(endpoint: endpoint, token: token).runCommandAction(path: path, id: id, confirmed: confirmed)
    }

    func gitStatus(path: String) async throws -> GitStatusResponse {
        // Git 状态是 agentd 控制面的只读接口；不走 app-server，避免把 Git 审查和对话协议耦合。
        try await AgentAPIClient(endpoint: endpoint, token: token).gitStatus(path: path)
    }

    func gitAction(path: String, action: GitActionKind, files: [String]) async throws -> GitStatusResponse {
        // Git 写动作仍由 agentd 控制面执行，方便统一做 allowlist、路径和动作白名单校验。
        try await AgentAPIClient(endpoint: endpoint, token: token).gitAction(path: path, action: action, files: files)
    }

    func gitPatchAction(path: String, action: GitActionKind, patch: String) async throws -> GitStatusResponse {
        // hunk 级 Git 动作仍复用 agentd 控制面，由后端限制单 hunk 和安全相对路径。
        try await AgentAPIClient(endpoint: endpoint, token: token).gitPatchAction(path: path, action: action, patch: patch)
    }

    func gitCommit(path: String, message: String) async throws -> GitStatusResponse {
        // 本地 commit 属于 Git 控制面能力；只提交已暂存内容，保持对话协议单纯。
        try await AgentAPIClient(endpoint: endpoint, token: token).gitCommit(path: path, message: message)
    }

    func gitPush(path: String, remote: String?) async throws -> GitPushResponse {
        // push 仍由 agentd 控制面执行，禁止 force，复用本机 Git 凭证。
        try await AgentAPIClient(endpoint: endpoint, token: token).gitPush(path: path, remote: remote)
    }

    func gitQuickPublish(path: String, message: String, remote: String?, confirmed: Bool) async throws -> GitQuickPublishResponse {
        // 快捷发布固定走 agentd 的受限组合动作，客户端不直接拼接 Git 命令。
        try await AgentAPIClient(endpoint: endpoint, token: token).gitQuickPublish(
            path: path,
            message: message,
            remote: remote,
            confirmed: confirmed
        )
    }

    func gitTestFlightStatus(path: String) async throws -> GitTestFlightStatusResponse {
        // 发布能力以主机本地预检为准，避免只看到 iOS 工程就错误开放按钮。
        try await AgentAPIClient(endpoint: endpoint, token: token).gitTestFlightStatus(path: path)
    }

    func gitTestFlightRun(path: String, whatToTest: String, confirmed: Bool) async throws -> GitTestFlightStatusResponse {
        try await AgentAPIClient(endpoint: endpoint, token: token).gitTestFlightRun(
            path: path,
            whatToTest: whatToTest,
            confirmed: confirmed
        )
    }

    func gitCreatePullRequest(path: String, title: String, body: String, draft: Bool) async throws -> GitPullRequestResponse {
        // PR 通过本机已登录的 gh CLI 创建，iPad 不接触 GitHub token。
        try await AgentAPIClient(endpoint: endpoint, token: token).gitCreatePullRequest(path: path, title: title, body: body, draft: draft)
    }

    func gitPullRequestStatus(path: String) async throws -> GitPullRequestStatusResponse {
        // PR 状态同样读取本机 gh CLI，移动端只展示当前分支摘要。
        try await AgentAPIClient(endpoint: endpoint, token: token).gitPullRequestStatus(path: path)
    }

    func session(id: SessionID, afterSeq: EventSequence?) async throws -> SessionResponse {
        let result = try await sendRecoveringFromStaleInitialization(
            CodexAppServerRequestBuilder(allowlistedProjects: try await projects()).threadRead(threadID: id, includeTurns: false)
        )
        guard let thread = threadObject(from: result) else {
            throw CodexAppServerSessionRuntimeError.sessionNotFound(id)
        }
        _ = await refreshRateLimitIfAvailable(force: true)
        let session = try agentSession(from: thread, projects: try await projects(), fallbackProject: nil)
        contextsBySessionID[id] = CodexAppServerSessionContext(
            session: session,
            cwd: session.dir,
            activeTurnID: session.activeTurnID
        )
        return SessionResponse(session: session, recentOutput: nil, lastSeq: session.lastSeq)
    }

    func refreshRateLimit() async -> RateLimitSummary? {
        await refreshRateLimitIfAvailable(force: true)
    }

    func threadGoal(threadID: SessionID) async throws -> ThreadGoal? {
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: try await projects())
        let result = try await sendRecoveringFromStaleInitialization(builder.threadGoalGet(threadID: threadID))
        guard let goal = threadGoal(from: result) else {
            clearThreadGoalLocal(threadID: threadID)
            emit(.goalCleared(metadata(threadID: threadID, turnID: nil)))
            return nil
        }
        applyThreadGoal(goal)
        emit(.goalUpdated(goal, metadata(threadID: goal.threadID, turnID: nil)))
        return goal
    }

    @discardableResult
    func setThreadGoal(
        threadID: SessionID,
        objective: String? = nil,
        status: ThreadGoalStatus? = nil,
        tokenBudget: Int64? = nil
    ) async throws -> ThreadGoal {
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: try await projects())
        let normalizedObjective = objective?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await sendRecoveringFromStaleInitialization(builder.threadGoalSet(
            threadID: threadID,
            objective: normalizedObjective?.isEmpty == false ? normalizedObjective : nil,
            status: status,
            tokenBudget: tokenBudget
        ))
        guard let goal = threadGoal(from: result) else {
            throw AgentAPIError.invalidResponse
        }
        applyThreadGoal(goal)
        emit(.goalUpdated(goal, metadata(threadID: goal.threadID, turnID: nil)))
        return goal
    }

    func clearThreadGoal(threadID: SessionID) async throws {
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: try await projects())
        _ = try await sendRecoveringFromStaleInitialization(builder.threadGoalClear(threadID: threadID))
        clearThreadGoalLocal(threadID: threadID)
        emit(.goalCleared(metadata(threadID: threadID, turnID: nil)))
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        let baseProjects = try await projects()
        let projectPath = payload.projectPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let project: AgentProject
        let projects: [AgentProject]
        if let projectPath, !projectPath.isEmpty {
            project = AgentProject(
                id: payload.projectID,
                name: firstNonEmpty(payload.projectName?.trimmingCharacters(in: .whitespacesAndNewlines), URL(fileURLWithPath: projectPath).lastPathComponent),
                path: projectPath
            )
            projects = projectsIncludingWorkspace(baseProjects, workspace: AgentWorkspace(
                id: project.id,
                name: project.name,
                path: project.path,
                rootProjectID: payload.rootProjectID
            ))
        } else {
            guard let existingProject = baseProjects.first(where: { $0.id == payload.projectID }) else {
                throw CodexAppServerSessionRuntimeError.projectNotFound(payload.projectID)
            }
            project = existingProject
            projects = baseProjects
        }
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: projects)
        var threadOptions = payload.turnOptions
        // 线程级请求只负责创建/恢复会话；模型由随后的 turn/start 携带。
        // 部分 app-server 版本会拒绝 thread/start/resume 上的 model/modelProvider，
        // 所以这里必须保持主线兼容行为，不能让纯 Codex 用户回归。
        threadOptions.model = nil
        threadOptions.modelProvider = nil
        threadOptions = runtimeScopedThreadOptions(threadOptions)
        let spec: CodexAppServerRequestSpec
        if payload.resumeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            spec = projectPath?.isEmpty == false
                ? try builder.threadStart(cwd: project.path, options: threadOptions)
                : try builder.threadStart(projectID: payload.projectID, options: threadOptions)
        } else {
            spec = projectPath?.isEmpty == false
                ? try builder.threadResume(threadID: payload.resumeID, cwd: project.path, options: threadOptions)
                : try builder.threadResume(threadID: payload.resumeID, projectID: payload.projectID, options: threadOptions)
        }

        let result: CodexAppServerJSONValue?
        do {
            result = try await sendRecoveringFromStaleInitialization(spec)
        } catch {
            guard !payload.resumeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  shouldFallbackFromInitialTurnsPage(error) else {
                throw error
            }
            // idle 历史会话的发送会通过 createSession(resume:) 进入这里；它和事件订阅一样
            // 必须允许 initialTurnsPage 因响应过大或版本不兼容而降级，否则 turn/start 永远不会发出。
            let fallback = try builder.threadResume(
                threadID: payload.resumeID,
                cwd: project.path,
                options: threadOptions,
                includeInitialTurnsPage: false
            )
            result = try await sendRecoveringFromStaleInitialization(fallback)
        }
        guard let thread = threadObject(from: result) else {
            throw AgentAPIError.invalidResponse
        }
        var session = try agentSession(from: thread, projects: projects, fallbackProject: project, forceRunning: true)
        let cwd = session.dir
        contextsBySessionID[session.id] = CodexAppServerSessionContext(session: session, cwd: cwd, activeTurnID: session.activeTurnID)
        let turnPayload = CodexAppServerTurnPayload(input: payload.input, options: payload.turnOptions)
        if !turnPayload.isEmpty {
            // thread/start 后立刻 turn/start 仍沿用当前连接；但空会话没有立即 turn，
            // 后续监听/发送前必须补 thread/resume，否则真实 app-server 可能不回推事件。
            threadsResumedOnConnection.insert(session.id)
        }

        let initialGoalObjective = payload.initialGoalObjective?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let initialGoalObjective, !initialGoalObjective.isEmpty {
            // 目标任务必须先写入 thread 元数据，再启动首个 turn；这样 app-server 从一开始就知道
            // 这次执行属于 goal，而不是普通 turn 完成后再补标签。
            try await setThreadGoal(threadID: session.id, objective: initialGoalObjective, status: .active)
            if let updated = contextsBySessionID[session.id]?.session {
                session = updated
            }
        }

        if !turnPayload.isEmpty {
            let turnID = try await startTurn(
                sessionID: session.id,
                payload: turnPayload,
                clientMessageID: payload.clientMessageID
            )
            session = withUpdatedSession(session.id) { item in
                item.status = "running"
                item.activeTurnID = turnID
            } ?? session
        }

        return CreateSessionResponse(
            session: session,
            wsURL: try Self.gatewayURL(endpoint: endpoint, sessionID: session.id, runtimeProvider: runtimeProvider).absoluteString
        )
    }

    func stopSession(id: SessionID) async throws {
        guard let activeTurnID = contextsBySessionID[id]?.activeTurnID else {
            _ = withUpdatedSession(id) { item in
                item.status = "closed"
            }
            return
        }
        let spec = CodexAppServerRequestBuilder(allowlistedProjects: try await projects()).turnInterrupt(threadID: id, turnID: activeTurnID)
        _ = try await sendRecoveringFromStaleInitialization(spec)
        _ = withUpdatedSession(id) { item in
            item.status = "closed"
            item.activeTurnID = nil
        }
    }

    func setSessionArchived(id: SessionID, archived: Bool) async throws {
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: try await projects())
        let spec = archived
            ? builder.threadArchive(threadID: id)
            : builder.threadUnarchive(threadID: id)
        _ = try await sendRecoveringFromStaleInitialization(spec)
        if archived {
            contextsBySessionID.removeValue(forKey: id)
            threadHistoryCacheBySessionID.removeValue(forKey: id)
            threadAuthoritativeCompletedTurnItemsBySessionID.removeValue(forKey: id)
        }
    }

    func setThreadName(threadID: SessionID, name: String) async throws {
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: try await projects())
        _ = try await sendRecoveringFromStaleInitialization(
            try builder.threadSetName(threadID: threadID, name: name)
        )
        // title 是 AgentSession 的不可变快照；等 thread/name/updated 通知后由投影层告知 UI，
        // 下次 thread/list/read 会拉取权威名称，避免本地与 app-server 状态分叉。
    }

    func compactThread(threadID: SessionID) async throws {
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: try await projects())
        _ = try await sendRecoveringFromStaleInitialization(builder.threadCompactStart(threadID: threadID))
    }

    @discardableResult
    func unsubscribeThread(threadID: SessionID) async throws -> CodexAppServerThreadUnsubscribeStatus? {
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: try await projects())
        let result = try await sendRecoveringFromStaleInitialization(builder.threadUnsubscribe(threadID: threadID))
        threadsResumedOnConnection.remove(threadID)
        return result?.objectValue?["status"]?.stringValue.flatMap(CodexAppServerThreadUnsubscribeStatus.init(rawValue:))
    }

    @discardableResult
    func startReview(
        threadID: SessionID,
        target: CodexAppServerReviewTarget,
        delivery: CodexAppServerReviewDelivery? = nil
    ) async throws -> CodexAppServerReviewStartResult {
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: try await projects())
        let result = try await sendRecoveringFromStaleInitialization(
            try builder.reviewStart(threadID: threadID, target: target, delivery: delivery)
        )
        guard let object = result?.objectValue,
              let reviewThreadID = object["reviewThreadId"]?.stringValue else {
            throw AgentAPIError.invalidResponse
        }
        let turnID = object["turn"]?.objectValue?["id"]?.stringValue
        if reviewThreadID == threadID {
            _ = withUpdatedSession(threadID) { session in
                session.status = "running"
                session.activeTurnID = turnID
            }
        }
        return CodexAppServerReviewStartResult(reviewThreadID: reviewThreadID, turnID: turnID)
    }

    func forkSession(threadID: SessionID, workspace: AgentWorkspace) async throws -> AgentSession {
        let baseProjects = try await projects()
        let project = AgentProject(id: workspace.id, name: workspace.name, path: workspace.path)
        let projects = projectsIncludingWorkspace(baseProjects, workspace: workspace)
        var options = CodexAppServerTurnOptions.default
        options.threadSource = "worktree_handoff"
        let result = try await sendRecoveringFromStaleInitialization(
            try CodexAppServerRequestBuilder(allowlistedProjects: projects).threadFork(
                threadID: threadID,
                cwd: workspace.path,
                options: options
            )
        )
        guard let thread = threadObject(from: result) else {
            throw AgentAPIError.invalidResponse
        }
        let session = try agentSession(from: thread, projects: projects, fallbackProject: project)
        contextsBySessionID[session.id] = CodexAppServerSessionContext(
            session: session,
            cwd: session.dir,
            activeTurnID: session.activeTurnID
        )
        threadsResumedOnConnection.insert(session.id)
        return session
    }

    // thread/read 是整段历史的批量拉取，慢链路（Tailscale）下比交互式请求耗时得多；给它一个更宽的
    // 超时，避免大会话首屏因为 20s 的默认请求超时而直接报错。
    static let bulkReadTimeout: TimeInterval = 60
    static let threadTurnsCursorPrefix = "turns:"
    static let economyHistoryNotice = L10n.text("ui.this_session_contains_large_images_or_tool_output")

    func messagesPage(
        sessionID: SessionID,
        before: String?,
        limit: Int?,
        loadMode: HistoryMessagesPage.LoadMode = .full
    ) async throws -> HistoryMessagesPage {
        let config = try await ensureConfig()
        if shouldUseThreadTurnsList(config: config) {
            do {
                return try await messagesPageFromTurnPages(
                    sessionID: sessionID,
                    before: before,
                    limit: limit,
                    loadMode: loadMode,
                    projects: config.projects
                )
            } catch {
                if shouldFallbackFromThreadTurnsList(error) {
                    threadTurnsListUnavailable = true
                } else {
                    throw error
                }
            }
        }
        return try await messagesPageFromFullThreadRead(
            sessionID: sessionID,
            before: before,
            limit: limit,
            projects: config.projects
        )
    }

    func messagesPageFromFullThreadRead(
        sessionID: SessionID,
        before: String?,
        limit: Int?,
        projects: [AgentProject]
    ) async throws -> HistoryMessagesPage {
        // 翻看更早历史：老 turn 不会变，直接用上次整段读取的缓存切窗口，不再重复拉整段 thread。
        if before != nil, let cached = threadHistoryCacheBySessionID[sessionID] {
            return Self.paginateHistory(
                cached,
                before: before,
                limit: limit,
                context: contextsBySessionID[sessionID]?.session.context,
                authoritativeCompletedTurnItems: threadAuthoritativeCompletedTurnItemsBySessionID[sessionID] ?? [:]
            )
        }
        let result = try await sendRecoveringFromStaleInitialization(
            CodexAppServerRequestBuilder(allowlistedProjects: projects).threadRead(threadID: sessionID, includeTurns: true),
            timeout: Self.bulkReadTimeout
        )
        guard let thread = threadObject(from: result) else {
            throw CodexAppServerSessionRuntimeError.sessionNotFound(sessionID)
        }
        let turns = thread["turns"]?.arrayValue?.compactMap(\.objectValue) ?? []
        let messages = historyMessages(from: thread, sessionID: sessionID, snapshotReadAt: Date())
        let authoritativeCompletedTurnItems = Self.authoritativeCompletedTurnItems(fromTurns: turns)
        var context: SessionContextSnapshot?
        if let session = try? agentSession(from: thread, projects: projects, fallbackProject: nil) {
            let recoveredTerminalTurn = storeAuthoritativeTurnsSnapshot(session, thread: thread)
            context = session.context
            if let recoveredTerminalTurn {
                emit(.turnCompleted(
                    metadata(threadID: session.id, turnID: recoveredTerminalTurn.turnID)
                        .withTurnLifecycle(recoveredTerminalTurn.lifecycle)
                ))
            }
        }
        threadHistoryCacheBySessionID[sessionID] = messages
        threadAuthoritativeCompletedTurnItemsBySessionID[sessionID] = authoritativeCompletedTurnItems
        return Self.paginateHistory(
            messages,
            before: before,
            limit: limit,
            context: context,
            authoritativeCompletedTurnItems: authoritativeCompletedTurnItems
        )
    }

    func messagesPageFromTurnPages(
        sessionID: SessionID,
        before: String?,
        limit: Int?,
        loadMode: HistoryMessagesPage.LoadMode,
        projects: [AgentProject]
    ) async throws -> HistoryMessagesPage {
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: projects)
        let cursor = Self.decodeThreadTurnsCursor(before)
        let threadMetadata = try await threadMetadataForHistoryPage(
            sessionID: sessionID,
            builder: builder,
            projects: projects,
            shouldRefresh: contextsBySessionID[sessionID] == nil
        )
        let result = try await sendRecoveringFromStaleInitialization(
            builder.threadTurnsList(
                threadID: sessionID,
                cursor: cursor,
                limit: Self.threadTurnPageLimit(forMessageLimit: limit, loadMode: loadMode),
                sortDirection: "desc",
                itemsView: Self.threadTurnItemsView(loadMode: loadMode)
            ),
            timeout: requestTimeout
        )
        let object = result?.objectValue ?? [:]
        let turns = object["data"]?.arrayValue?.compactMap(\.objectValue) ?? []
        let chronologicalTurns = Array(turns.reversed())
        // iPad 在 turn 结束后才恢复连接时，会错过实时 turn/completed，但分页历史已经能看到
        // 对应 turn 的终态。这里用最新一页的权威 turn 结果补回完成事件，避免消息已显示完成，
        // runtime 仍保留陈旧 activeTurnID，进而让后续输入永久卡在本地队列。
        let recoveredTerminalTurn = cursor == nil
            ? recoverCompletedActiveTurnFromLatestTurnsPage(
                sessionID: sessionID,
                turns: chronologicalTurns
            )
            : nil
        var thread = threadMetadata ?? historyThreadShell(sessionID: sessionID, projects: projects)
        thread["turns"] = .array(chronologicalTurns.map { .object($0) })
        let messages = historyMessages(
            fromTurns: chronologicalTurns,
            sessionID: sessionID,
            threadCreatedAt: firstDate(in: thread, keys: ["createdAt", "created_at"]),
            threadUpdatedAt: firstDate(in: thread, keys: ["updatedAt", "updated_at"]),
            threadIsActive: isActiveHistoryThread(thread),
            snapshotReadAt: Date()
        )
        let context = contextForHistoryThread(thread, sessionID: sessionID, projects: projects)
        if let recoveredTerminalTurn {
            emit(.turnCompleted(
                metadata(threadID: sessionID, turnID: recoveredTerminalTurn.turnID)
                    .withTurnLifecycle(recoveredTerminalTurn.lifecycle)
            ))
        }
        let nextCursor = firstString(in: object, keys: ["nextCursor", "next_cursor"])
        return HistoryMessagesPage(
            messages: messages,
            previousCursor: nextCursor.map(Self.encodeThreadTurnsCursor),
            hasMoreBefore: nextCursor != nil,
            context: context,
            loadMode: loadMode,
            notice: Self.historyNotice(loadMode: loadMode, hasMoreBefore: nextCursor != nil, turns: chronologicalTurns),
            authoritativeCompletedTurnItems: Self.authoritativeCompletedTurnItems(fromTurns: chronologicalTurns)
        )
    }

    func recoverCompletedActiveTurnFromLatestTurnsPage(
        sessionID: SessionID,
        turns: [[String: CodexAppServerJSONValue]]
    ) -> (turnID: TurnID, lifecycle: ConversationTurnLifecycle)? {
        guard var context = contextsBySessionID[sessionID],
              let activeTurnID = context.activeTurnID,
              let activeTurnIndex = turns.lastIndex(where: { $0["id"]?.stringValue == activeTurnID })
        else {
            return nil
        }
        let activeTurn = turns[activeTurnIndex]
        let hasTerminalStatus = isTerminalHistoryStatus(activeTurn["status"])
        let hasCompletionTimestamp = firstDate(in: activeTurn, keys: ["completedAt", "completed_at"]) != nil
        guard hasTerminalStatus || hasCompletionTimestamp else {
            return nil
        }

        // 如果分页里已经出现更新但尚未确认终态的 turn，旧 turn 的完成不能把当前执行误判为空闲。
        let laterTurns = turns.index(after: activeTurnIndex)..<turns.endIndex
        guard !laterTurns.contains(where: { index in
            let turn = turns[index]
            return !isTerminalHistoryStatus(turn["status"])
                && firstDate(in: turn, keys: ["completedAt", "completed_at"]) == nil
        }) else {
            return nil
        }

        context.activeTurnID = nil
        context.session.activeTurnID = nil
        context.session.status = SessionStatus.history.rawValue
        context.session.pendingApproval = nil
        context.session.pendingUserInput = nil
        contextsBySessionID[sessionID] = context
        return (
            activeTurnID,
            historyTurnLifecycle(
                activeTurn,
                isInProgress: false,
                completedAt: firstDate(in: activeTurn, keys: ["completedAt", "completed_at"])
            )
        )
    }

    func threadMetadataForHistoryPage(
        sessionID: SessionID,
        builder: CodexAppServerRequestBuilder,
        projects: [AgentProject],
        shouldRefresh: Bool
    ) async throws -> [String: CodexAppServerJSONValue]? {
        if !shouldRefresh {
            return nil
        }
        let result = try await sendRecoveringFromStaleInitialization(
            builder.threadRead(threadID: sessionID, includeTurns: false),
            timeout: requestTimeout
        )
        guard let thread = threadObject(from: result) else {
            throw CodexAppServerSessionRuntimeError.sessionNotFound(sessionID)
        }
        if let session = try? agentSession(from: thread, projects: projects, fallbackProject: nil) {
            contextsBySessionID[sessionID] = CodexAppServerSessionContext(
                session: session,
                cwd: session.dir,
                activeTurnID: session.activeTurnID
            )
        }
        return thread
    }

    func contextForHistoryThread(
        _ thread: [String: CodexAppServerJSONValue],
        sessionID: SessionID,
        projects: [AgentProject]
    ) -> SessionContextSnapshot? {
        if let session = try? agentSession(from: thread, projects: projects, fallbackProject: nil) {
            contextsBySessionID[sessionID] = CodexAppServerSessionContext(
                session: session,
                cwd: session.dir,
                activeTurnID: session.activeTurnID
            )
            return session.context
        }
        return contextsBySessionID[sessionID]?.session.context
    }

    func historyThreadShell(
        sessionID: SessionID,
        projects: [AgentProject]
    ) -> [String: CodexAppServerJSONValue] {
        if let cached = contextsBySessionID[sessionID]?.session {
            return [
                "id": .string(cached.id),
                "sessionId": .string(cached.id),
                "cwd": .string(cached.dir),
                "name": .string(cached.title),
                "preview": cached.preview.map { .string($0) } ?? .null,
                "status": .object(["type": .string(cached.isRunning ? "active" : "notLoaded")]),
                "modelProvider": .string("openai"),
                "createdAt": cached.createdAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                "updatedAt": cached.updatedAt.map { .double($0.timeIntervalSince1970) } ?? .null
            ]
        }
        let project = projects.first
        let cwd: CodexAppServerJSONValue
        if let path = project?.path {
            cwd = .string(path)
        } else {
            cwd = .null
        }
        return [
            "id": .string(sessionID),
            "sessionId": .string(sessionID),
            "cwd": cwd,
            "name": .string("Thread \(sessionID.prefix(8))"),
            "status": .object(["type": .string("notLoaded")]),
            "modelProvider": .string("openai")
        ]
    }

    func shouldUseThreadTurnsList(config: CodexAppServerConfigResponse) -> Bool {
        !threadTurnsListUnavailable && config.policy.allowedMethods.contains("thread/turns/list")
    }

    func threadListPageWithIndexedFallback(
        cwd: String,
        cursor: String?,
        limit: Int?,
        builder: CodexAppServerRequestBuilder,
        projects: [AgentProject],
        fallbackProject: AgentProject,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage {
        let canUseIndexedList = consistency == .fastIndexed
            && cursor == nil
            && !stateDBOnlyListUnavailable
            && !stateDBOnlyScanRequiredCWDs.contains(cwd)
        let sortKey = preferredThreadListSortKey
        do {
            let result = try await sendRecoveringFromStaleInitialization(
                try builder.threadList(
                    cwd: cwd,
                    limit: limit,
                    cursor: cursor,
                    useStateDBOnly: canUseIndexedList,
                    sortKey: sortKey
                ),
                timeout: threadListRequestTimeout
            )
            let page = threadListPage(from: result, projects: projects, fallbackProject: fallbackProject)
            guard canUseIndexedList, indexedThreadListNeedsRepair(page, cwd: cwd) else {
                return page
            }
            // 状态库漏掉本连接已知 thread 时，本连接后续固定走普通扫描，避免每轮都先错一次再回退。
            stateDBOnlyScanRequiredCWDs.insert(cwd)
            return try await ordinaryThreadListPage(
                cwd: cwd,
                cursor: cursor,
                limit: limit,
                builder: builder,
                projects: projects,
                fallbackProject: fallbackProject
            )
        } catch {
            if sortKey == "recency_at", shouldFallbackFromRecencySort(error) {
                // 旧 agentd/Codex 不认识 recency_at 时，本连接只探测一次，之后稳定退回 updated_at。
                recencySortUnavailable = true
                return try await threadListPageWithIndexedFallback(
                    cwd: cwd,
                    cursor: cursor,
                    limit: limit,
                    builder: builder,
                    projects: projects,
                    fallbackProject: fallbackProject,
                    consistency: consistency
                )
            }
            guard canUseIndexedList, shouldFallbackFromStateDBOnlyList(error) else {
                throw error
            }
            stateDBOnlyListUnavailable = true
            return try await ordinaryThreadListPage(
                cwd: cwd,
                cursor: cursor,
                limit: limit,
                builder: builder,
                projects: projects,
                fallbackProject: fallbackProject
            )
        }
    }

    func ordinaryThreadListPage(
        cwd: String,
        cursor: String?,
        limit: Int?,
        builder: CodexAppServerRequestBuilder,
        projects: [AgentProject],
        fallbackProject: AgentProject
    ) async throws -> SessionsPage {
        let result = try await sendRecoveringFromStaleInitialization(
            try builder.threadList(
                cwd: cwd,
                limit: limit,
                cursor: cursor,
                useStateDBOnly: false,
                sortKey: preferredThreadListSortKey
            ),
            timeout: threadListRequestTimeout
        )
        return threadListPage(from: result, projects: projects, fallbackProject: fallbackProject)
    }

    func indexedThreadListNeedsRepair(_ page: SessionsPage, cwd: String) -> Bool {
        let knownSessions = contextsBySessionID.values.compactMap { context in
            context.cwd == cwd ? context.session : nil
        }
        guard !knownSessions.isEmpty else {
            return false
        }
        let pageIDs = Set(page.sessions.map(\.id))
        let missing = knownSessions.filter { !pageIDs.contains($0.id) }
        guard !missing.isEmpty else {
            return false
        }
        guard page.hasMore, let tail = page.sessions.last else {
            return true
        }
        let tailDate = SessionIndexStore.orderingDate(for: tail)
        // 满页时只修复“按最近活动本应位于本页”的缺口；更老的已知会话留在后续分页，避免无谓扫描。
        return missing.contains { known in
            let knownDate = SessionIndexStore.orderingDate(for: known)
            return knownDate > tailDate || (knownDate == tailDate && known.id > tail.id)
        }
    }

    var preferredThreadListSortKey: String {
        runtimeProvider == "codex" && !recencySortUnavailable ? "recency_at" : "updated_at"
    }

    func shouldFallbackFromRecencySort(_ error: Error) -> Bool {
        guard case CodexAppServerConnectionError.appServer(let appError) = error else {
            return false
        }
        let message = appError.message.lowercased()
        return appError.code == -32601
            || message.contains("recency_at")
            || message.contains("sortkey") && (message.contains("unsupported") || message.contains("not supported"))
            || message.contains("sortkey") && message.contains("不支持")
    }

    func shouldFallbackFromStateDBOnlyList(_ error: Error) -> Bool {
        guard case CodexAppServerConnectionError.appServer(let appError) = error else {
            return false
        }
        let message = appError.message.lowercased()
        return appError.code == -32601
            || message.contains("usestatedbonly")
            || message.contains("unknown field")
            || message.contains("unsupported")
            || message.contains("not supported")
    }

    func shouldFallbackFromThreadTurnsList(_ error: Error) -> Bool {
        guard case CodexAppServerConnectionError.appServer(let appError) = error else {
            return false
        }
        let message = appError.message.lowercased()
        return appError.code == -32601
            || message.contains("unsupported")
            || message.contains("not supported")
            || message.contains("method not found")
            || message.contains("method 不允许")
            || message.contains("experimentalapi")
    }

    static func threadTurnPageLimit(forMessageLimit limit: Int?, loadMode: HistoryMessagesPage.LoadMode) -> Int {
        let requestedMessages = max(1, limit ?? 120)
        switch loadMode {
        case .economy:
            // 核心逻辑：一条 turn 可能包含 base64 图片或超长工具输出。
            // 控制 turn 页大小，比降低 WebSocket message size 更温和，不会制造重连风暴。
            return max(5, min(20, (requestedMessages + 3) / 4))
        case .full:
            // full 手动加载仍要服从 Go gateway 的硬上限，避免弱网下大响应被 50 limit 拒绝。
            return max(10, min(50, (requestedMessages + 1) / 2))
        }
    }

    static func threadTurnItemsView(loadMode: HistoryMessagesPage.LoadMode) -> String {
        switch loadMode {
        case .economy:
            return "summary"
        case .full:
            return "full"
        }
    }

    static func authoritativeCompletedTurnItems(
        fromTurns turns: [[String: CodexAppServerJSONValue]]
    ) -> [TurnID: Set<AgentItemID>] {
        var result: [TurnID: Set<AgentItemID>] = [:]
        for turn in turns {
            guard turn["status"]?.stringValue == "completed",
                  turn["itemsView"]?.stringValue == "full" || turn["items_view"]?.stringValue == "full",
                  let turnID = turn["id"]?.stringValue else {
                continue
            }
            let itemIDs = Set(
                turn["items"]?.arrayValue?
                    .compactMap(\.objectValue)
                    .compactMap { $0["id"]?.stringValue }
                    .filter { !$0.isEmpty } ?? []
            )
            result[turnID] = itemIDs
        }
        return result
    }

    static func historyNotice(
        loadMode: HistoryMessagesPage.LoadMode,
        hasMoreBefore: Bool,
        turns: [[String: CodexAppServerJSONValue]]
    ) -> String? {
        guard loadMode == .economy else {
            return nil
        }
        // 后端 summary 视图表示 item 详情可按需再拉；没有显式字段时，大历史分页也按省流提示处理。
        let hasLazyContentSignal = turns.contains { turn in
            turn["itemsView"]?.stringValue == "summary"
                || turn["items_view"]?.stringValue == "summary"
                || turn["hasFullItems"]?.boolValue == false
                || turn["has_full_items"]?.boolValue == false
        }
        guard hasMoreBefore || hasLazyContentSignal || !turns.isEmpty else {
            return nil
        }
        return economyHistoryNotice
    }

    static func encodeThreadTurnsCursor(_ cursor: String) -> String {
        threadTurnsCursorPrefix + Data(cursor.utf8).base64EncodedString()
    }

    static func decodeThreadTurnsCursor(_ cursor: String?) -> String? {
        guard let cursor,
              cursor.hasPrefix(threadTurnsCursorPrefix)
        else {
            return nil
        }
        let encoded = String(cursor.dropFirst(threadTurnsCursorPrefix.count))
        guard let data = Data(base64Encoded: encoded) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // thread/read 一次性返回整段 thread 历史；分页只能在客户端做。按消息稳定 id 切窗口，并回填
    // previousCursor / hasMoreBefore，否则长会话只会拿到最近一窗，最早的消息既被 suffix 截掉、又因为
    // 没有 cursor 而永远翻不回去（直连取代旧 REST 兼容链路后这条路是唯一来源）。
    static func paginateHistory(
        _ messages: [CodexHistoryMessage],
        before: String?,
        limit: Int?,
        context: SessionContextSnapshot? = nil,
        authoritativeCompletedTurnItems: [TurnID: Set<AgentItemID>] = [:]
    ) -> HistoryMessagesPage {
        let upperBound: Int
        if let before {
            guard let index = messages.firstIndex(where: { $0.id == before }) else {
                // 游标对应的消息已不在历史里（极少见），关闭分页，避免反复请求同一页。
                return HistoryMessagesPage(
                    messages: [],
                    previousCursor: nil,
                    hasMoreBefore: false,
                    context: context,
                    authoritativeCompletedTurnItems: authoritativeCompletedTurnItems
                )
            }
            upperBound = index
        } else {
            upperBound = messages.count
        }
        let window = messages[..<upperBound]
        let bounded: [CodexHistoryMessage]
        if let limit, limit > 0, window.count > limit {
            bounded = Array(window.suffix(limit))
        } else {
            bounded = Array(window)
        }
        let hasMoreBefore = bounded.count < window.count
        return HistoryMessagesPage(
            messages: bounded,
            previousCursor: hasMoreBefore ? bounded.first?.id : nil,
            hasMoreBefore: hasMoreBefore,
            context: context,
            authoritativeCompletedTurnItems: authoritativeCompletedTurnItems
        )
    }

    func attachEvents(
        sessionID: SessionID,
        replayPolicy: CodexAppServerBufferedEventReplayPolicy = .all
    ) -> CodexAppServerEventStream {
        // 这里承接的是已经投影好的 thread 事件；正常连接完整保序交付，切回会话的 backlog
        // 可降级为状态级回放，避免历史输出在消息区重新直播一遍。每个订阅者使用独立合并邮箱：
        // 主线程渲染变慢时连续 delta 会收敛为少量完整 chunk，控制事件仍严格无损有序。
        let token = UUID()
        let mailbox = CodexAppServerEventMailbox { [weak self] in
            Task {
                await self?.detachEvents(sessionID: sessionID, token: token)
            }
        }
        let isFirstSubscriber = eventMailboxesBySessionID[sessionID]?.isEmpty != false
        eventMailboxesBySessionID[sessionID, default: [:]][token] = mailbox
        // backlog 只能被第一个订阅者消费一次；之后同 thread 的可见页面与后台队列
        // 都从实时扇出接收事件，避免两个 SessionWebSocketClient 互相顶掉订阅者。
        var replayedInteractionIDs: Set<String> = []
        if isFirstSubscriber {
            for event in bufferedEvents(sessionID: sessionID, replayPolicy: replayPolicy) {
                if let interactionID = pendingInteractionReplayID(for: event) {
                    replayedInteractionIDs.insert(interactionID)
                }
                mailbox.send(event)
            }
        }
        // server request 本身不在 thread/list/read 里，页面切换或进后台时又可能已经从
        // runtime 收到、但还没投影到新页面。新订阅者必须直接补放 runtime 内存里仍挂起的
        // 审批/补充信息请求，否则侧边栏只会显示“待输入”，详情却没有可操作卡片。
        for event in pendingInteractionEvents(sessionID: sessionID) {
            guard let interactionID = pendingInteractionReplayID(for: event),
                  replayedInteractionIDs.insert(interactionID).inserted else {
                continue
            }
            mailbox.send(event)
        }
        return CodexAppServerEventStream(mailbox: mailbox)
    }

    func bufferedEvents(
        sessionID: SessionID,
        replayPolicy: CodexAppServerBufferedEventReplayPolicy
    ) -> [AgentEvent] {
        let events = bufferedEventsBySessionID.removeValue(forKey: sessionID) ?? []
        switch replayPolicy {
        case .all:
            return events
        case .stateOnly:
            // 切回运行会话前已经用 thread/read 快照补齐消息区；旧 delta 和日志不再逐条补播。
            // 但审批、补充信息、turn 完成和会话状态仍要回放，避免丢掉当前可操作状态。
            return events.filter(shouldReplayBufferedStateEvent)
        }
    }

    nonisolated func shouldReplayBufferedStateEvent(_ event: AgentEvent) -> Bool {
        switch event {
        case .session,
             .sessionRow,
             .sessionStatus,
             .sessionContext,
             .goalUpdated,
             .goalCleared,
             .turnStarted,
             .approvalRequest,
             .approvalResolved,
             .userInputRequest,
             .userInputResolved,
             .turnCompleted,
             .warning,
             .error,
             .unknown:
            return true
        case .messageCompleted:
            // thread/read 快照不含 commandExecution 等过程 item；completed 内容事件必须补播，
            // 否则离开期间完成的命令卡会永久丢失。排序与去重由 ConversationStore 兜底。
            return true
        case .processItemCompleted(let message, _, _):
            // item/started 复用该事件类型以便当前页面立即看到运行态；stateOnly 恢复已经先加载
            // thread/read 权威快照，不能让旧 started 再把已完成命令覆盖回 inProgress。
            return message.activityPayload?.isInProgress != true
        case .assistantDelta,
             .logDelta,
             .diffUpdated:
            return false
        }
    }

    func pendingInteractionEvents(sessionID: SessionID) -> [AgentEvent] {
        var seenApprovalRequestIDs: Set<CodexAppServerRequestID> = []
        let approvalEvents = pendingApprovalRequestsByID.values.compactMap { request -> AgentEvent? in
            guard approvalSessionID(for: request) == sessionID,
                  seenApprovalRequestIDs.insert(request.id).inserted else {
                return nil
            }
            return projector.project(request)
        }
        var seenUserInputRequestIDs: Set<CodexAppServerRequestID> = []
        let userInputEvents = pendingUserInputRequestsByID.values.compactMap { request -> AgentEvent? in
            guard approvalSessionID(for: request) == sessionID,
                  seenUserInputRequestIDs.insert(request.id).inserted else {
                return nil
            }
            return projector.project(request)
        }
        return approvalEvents + userInputEvents
    }

    nonisolated func pendingInteractionReplayID(for event: AgentEvent) -> String? {
        switch event {
        case .approvalRequest(let request, _):
            return "approval:\(request.id)"
        case .userInputRequest(let request, _):
            return "user-input:\(request.id)"
        default:
            return nil
        }
    }

    func connectForEvents(sessionID: SessionID) async throws {
        if contextsBySessionID[sessionID] == nil {
            _ = try await session(id: sessionID, afterSeq: nil)
        }
        guard let context = contextsBySessionID[sessionID] else {
            throw CodexAppServerSessionRuntimeError.sessionNotFound(sessionID)
        }
        let connection = try await ensureConnection()
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: projectsIncludingSessionContext(try await projects(), context: context))
        if needsPendingInteractionRecovery(for: context.session) {
            // App 进后台时只取消页面事件泵，底层 gateway 连接可能仍存活，所以这个
            // thread 仍被记为已 resume。若列表已是等待态、runtime 却没有对应 server request，
            // 说明请求落在了 iOS 挂起/切会话窗口；清掉本地绑定标记，强制 thread/resume 让
            // app-server 重放未处理请求。
            threadsResumedOnConnection.remove(sessionID)
        }
        // 官方 app-server 客户端选择历史 thread 时会使用 thread/resume 建立 live listener；thread/read/list 只能做
        // hydration。移动端打开会话也要先绑定当前连接，否则历史里的 pending approval 和后续 turn 事件
        // 可能不会回流到 iPad。
        try await ensureThreadResumedOnConnection(sessionID: sessionID, cwd: context.cwd, builder: builder, connection: connection)
        // 目标状态是增强信息，不应该卡住实时事件连接。旧 app-server 可能不支持 thread/goal/get，
        // 慢链路也可能延迟响应；后台刷新即可，连接状态先进入 connected。
        Task {
            await refreshThreadGoalIfAvailable(sessionID: sessionID, builder: builder, connection: connection)
        }
    }

    func needsPendingInteractionRecovery(for session: AgentSession) -> Bool {
        switch session.status {
        case SessionStatus.waitingForApproval.rawValue:
            return !pendingApprovalRequestsByID.values.contains {
                approvalSessionID(for: $0) == session.id
            }
        case SessionStatus.waitingForInput.rawValue:
            return !pendingUserInputRequestsByID.values.contains {
                approvalSessionID(for: $0) == session.id
            }
        default:
            return false
        }
    }

    @discardableResult
    func startTurn(sessionID: SessionID, prompt: String, clientMessageID: ClientMessageID?) async throws -> TurnID? {
        try await startTurn(
            sessionID: sessionID,
            payload: CodexAppServerTurnPayload(prompt: prompt),
            clientMessageID: clientMessageID
        )
    }

    @discardableResult
    func startTurn(sessionID: SessionID, payload: CodexAppServerTurnPayload, clientMessageID: ClientMessageID?) async throws -> TurnID? {
        guard !payload.isEmpty else {
            return nil
        }
        let previous = turnStartTasksBySessionID[sessionID]?.task
        let token = UUID()
        let task = Task { [self] in
            if let previous {
                _ = try? await previous.value
            }
            return try await performStartTurn(sessionID: sessionID, payload: payload, clientMessageID: clientMessageID)
        }
        turnStartTasksBySessionID[sessionID] = (token, task)
        do {
            let turnID = try await task.value
            clearTurnStartTask(sessionID: sessionID, token: token)
            return turnID
        } catch {
            clearTurnStartTask(sessionID: sessionID, token: token)
            throw error
        }
    }

    @discardableResult
    func performStartTurn(sessionID: SessionID, payload: CodexAppServerTurnPayload, clientMessageID: ClientMessageID?) async throws -> TurnID? {
        guard let context = contextsBySessionID[sessionID] else {
            throw CodexAppServerSessionRuntimeError.sessionNotFound(sessionID)
        }
        // request_user_input 是 turn 内部的补充信息请求；是否展示由本地发送选项决定，
        // 不和目标模式绑定。运行中“引导对话”另走 turn/steer。
        userInputPromptsEnabledBySessionID[sessionID] = payload.options.planGuidanceEnabled
        sessionsStartingTurn.insert(sessionID)
        defer {
            sessionsStartingTurn.remove(sessionID)
        }
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: projectsIncludingSessionContext(try await projects(), context: context))
        let result: CodexAppServerJSONValue?
        var didRetryAfterStaleInitialization = false
        while true {
            let connection = try await ensureConnection()
            do {
                try await ensureThreadResumedOnConnection(sessionID: sessionID, cwd: context.cwd, builder: builder, connection: connection)
                result = try await connection.send(try builder.turnStart(
                    threadID: sessionID,
                    cwd: context.cwd,
                    payload: payload,
                    clientMessageID: clientMessageID
                ))
                break
            } catch {
                if !didRetryAfterStaleInitialization,
                   await recoverConnectionAfterStaleInitialization(connection, error: error) {
                    didRetryAfterStaleInitialization = true
                    continue
                }
                await refreshRateLimitAfterQuotaError(error)
                await retireCurrentConnectionAfterRecoverableError(connection, error: error)
                throw error
            }
        }
        let turnID = result?["turn"]?.objectValue?["id"]?.stringValue
        if let turnID {
            turnsStartedByThisRuntime.insert(turnID)
        }
        _ = withUpdatedSession(sessionID) { item in
            item.status = "running"
            item.activeTurnID = turnID
        }
        return turnID
    }

    func steerTurn(
        sessionID: SessionID,
        payload: CodexAppServerTurnPayload,
        clientMessageID: ClientMessageID?,
        expectedTurnID: TurnID
    ) async throws {
        guard !payload.isEmpty else {
            return
        }
        guard let context = contextsBySessionID[sessionID] else {
            throw CodexAppServerSessionRuntimeError.sessionNotFound(sessionID)
        }
        guard context.activeTurnID == expectedTurnID else {
            throw CodexAppServerSessionRuntimeError.missingActiveTurn(sessionID)
        }
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: projectsIncludingSessionContext(try await projects(), context: context))
        var didRetryAfterStaleInitialization = false
        while true {
            let connection = try await ensureConnection()
            do {
                try await ensureThreadResumedOnConnection(sessionID: sessionID, cwd: context.cwd, builder: builder, connection: connection)
                _ = try await connection.send(try builder.turnSteer(
                    threadID: sessionID,
                    cwd: context.cwd,
                    payload: payload,
                    clientMessageID: clientMessageID,
                    expectedTurnID: expectedTurnID
                ))
                return
            } catch {
                if !didRetryAfterStaleInitialization,
                   await recoverConnectionAfterStaleInitialization(connection, error: error) {
                    didRetryAfterStaleInitialization = true
                    continue
                }
                await refreshRateLimitAfterQuotaError(error)
                await retireCurrentConnectionAfterRecoverableError(connection, error: error)
                throw error
            }
        }
    }

    func clearTurnStartTask(sessionID: SessionID, token: UUID) {
        guard turnStartTasksBySessionID[sessionID]?.token == token else {
            return
        }
        turnStartTasksBySessionID.removeValue(forKey: sessionID)
    }

    // thread/start、thread/resume 的 options 必须按本 runtime 的通道策略先降级再发送：
    // Claude 通道不接受 dangerFullAccess，.default 草稿直接上桥会被 gateway 拒绝，
    // 会话恢复就会陷入确定性失败的重连循环。runtime 连接的 gateway 由自身 runtimeProvider
    // 决定，所以这里强制以 actor 的 runtime 为准，而不是相信 payload 里的残留值。
    func runtimeScopedThreadOptions(_ options: CodexAppServerTurnOptions) -> CodexAppServerTurnOptions {
        var scoped = options
        scoped.runtimeProvider = runtimeProvider
        return scoped.sanitizedForRuntimePolicy()
    }

    // 直连发送路径下，thread 可能只在 thread/list 或 thread/start 里出现过，但没有在当前 gateway
    // 连接上执行过 thread/resume。真实 app-server 只有 resume 后才稳定建立 live listener；
    // 否则 turn/start 虽然被接受，iPad 也可能收不到 turn/started、delta 和 completed，界面就会一直等待。
    func ensureThreadResumedOnConnection(
        sessionID: SessionID,
        cwd: String,
        builder: CodexAppServerRequestBuilder,
        connection: CodexAppServerConnection
    ) async throws {
        guard !threadsResumedOnConnection.contains(sessionID) else {
            return
        }
        let result: CodexAppServerJSONValue?
        do {
            result = try await connection.send(try builder.threadResume(threadID: sessionID, cwd: cwd, options: runtimeScopedThreadOptions(.default)))
        } catch {
            if shouldFallbackFromInitialTurnsPage(error) {
                result = try await connection.send(try builder.threadResume(
                    threadID: sessionID,
                    cwd: cwd,
                    options: runtimeScopedThreadOptions(.default),
                    includeInitialTurnsPage: false
                ))
            } else if isNoRolloutFoundError(error) {
                // 刚 thread/start、还没跑过任何 turn 的新线程在上游没有 rollout 文件，thread/resume 会返回
                // -32600 "no rollout found"。这类线程已经在本连接上被 thread/start 绑定，resume 只是冗余；
                // 标记为已 resume 并放行，等首个 turn/start 落盘 rollout 后事件自然回流。否则空会话开屏即
                // 因 connectForEvents 抛错进入“WebSocket 断开，正在自动重连”的死循环。
                threadsResumedOnConnection.insert(sessionID)
                return
            } else {
                throw error
            }
        }
        if let thread = threadObject(from: result),
           let session = try? agentSession(
            from: thread,
            projects: (try? projectsFromCache()) ?? [],
            fallbackProject: nil
           ) {
            let recoveredTerminalTurn = storeAuthoritativeTurnsSnapshot(session, thread: thread)
            emit(.session(session))
            if let recoveredTerminalTurn {
                // 断线可能发生在最终 item/completed 与 turn/completed 之间。resume 返回的 turns
                // 是当前连接的权威快照；确认旧 active turn 已进入终态后，补回完成事件，让上层
                // 清理陈旧 activeTurnID 并继续发送本地排队消息。
                emit(.turnCompleted(
                    metadata(threadID: session.id, turnID: recoveredTerminalTurn.turnID)
                        .withTurnLifecycle(recoveredTerminalTurn.lifecycle)
                ))
            }
        }
        threadsResumedOnConnection.insert(sessionID)
    }

    func storeAuthoritativeTurnsSnapshot(
        _ session: AgentSession,
        thread: [String: CodexAppServerJSONValue]
    ) -> (turnID: TurnID, lifecycle: ConversationTurnLifecycle)? {
        let previouslyActiveTurnID = contextsBySessionID[session.id]?.activeTurnID
        let recoveredTerminalTurn = completedTurnConfirmedByAuthoritativeSnapshot(
            thread,
            previouslyActiveTurnID: previouslyActiveTurnID,
            currentActiveTurnID: session.activeTurnID
        )
        contextsBySessionID[session.id] = CodexAppServerSessionContext(
            session: session,
            cwd: session.dir,
            activeTurnID: session.activeTurnID
        )
        return recoveredTerminalTurn
    }

    func completedTurnConfirmedByAuthoritativeSnapshot(
        _ thread: [String: CodexAppServerJSONValue],
        previouslyActiveTurnID: TurnID?,
        currentActiveTurnID: TurnID?
    ) -> (turnID: TurnID, lifecycle: ConversationTurnLifecycle)? {
        guard currentActiveTurnID == nil,
              let previouslyActiveTurnID,
              let turns = thread["turns"]?.arrayValue?.compactMap(\.objectValue),
              let previousTurn = turns.last(where: { $0["id"]?.stringValue == previouslyActiveTurnID })
        else {
            return nil
        }
        let hasTerminalStatus = isTerminalHistoryStatus(previousTurn["status"])
        let hasCompletionTimestamp = firstDate(in: previousTurn, keys: ["completedAt", "completed_at"]) != nil
        guard hasTerminalStatus || hasCompletionTimestamp else {
            return nil
        }
        return (
            previouslyActiveTurnID,
            historyTurnLifecycle(
                previousTurn,
                isInProgress: false,
                completedAt: firstDate(in: previousTurn, keys: ["completedAt", "completed_at"])
            )
        )
    }

    func shouldFallbackFromInitialTurnsPage(_ error: Error) -> Bool {
        guard case CodexAppServerConnectionError.appServer(let appError) = error else {
            return false
        }
        let message = appError.message.lowercased()
        let reason = appError.data?.objectValue?["reason"]?.stringValue?.lowercased()
        return reason == "history_response_too_large"
            || message.contains("initialturnspage")
            || message.contains("unknown field")
            || message.contains("unsupported")
            || message.contains("not supported")
    }

    func refreshThreadGoalIfAvailable(
        sessionID: SessionID,
        builder: CodexAppServerRequestBuilder,
        connection: CodexAppServerConnection
    ) async {
        do {
            let result = try await connection.send(builder.threadGoalGet(threadID: sessionID))
            guard let goal = threadGoal(from: result) else {
                clearThreadGoalLocal(threadID: sessionID)
                emit(.goalCleared(metadata(threadID: sessionID, turnID: nil)))
                return
            }
            applyThreadGoal(goal)
            emit(.goalUpdated(goal, metadata(threadID: goal.threadID, turnID: nil)))
        } catch {
            // 目标能力在旧 app-server 上可能不可用；监听会话本身不应因此失败。
        }
    }

    func interruptActiveTurn(sessionID: SessionID) async throws {
        guard let turnID = contextsBySessionID[sessionID]?.activeTurnID else {
            throw CodexAppServerSessionRuntimeError.missingActiveTurn(sessionID)
        }
        let spec = CodexAppServerRequestBuilder(allowlistedProjects: try await projects()).turnInterrupt(threadID: sessionID, turnID: turnID)
        _ = try await sendRecoveringFromStaleInitialization(spec)
    }

    func respondToApproval(sessionID: SessionID? = nil, approvalID: String, decision: String) async throws {
        let lookupKeys = pendingApprovalLookupKeys(sessionID: sessionID, approvalID: approvalID)
        guard let request = lookupKeys.compactMap({ pendingApprovalRequestsByID[$0] }).first else {
            throw CodexAppServerSessionRuntimeError.approvalNotFound(approvalID)
        }
        let normalized = normalizeApprovalDecision(decision)
        let result = approvalResponse(method: request.method, params: request.params?.objectValue ?? [:], decision: normalized)
        try await ensureConnection().respond(to: request, result: result)
    }

    func respondToUserInput(sessionID: SessionID? = nil, requestID: String, answers: [String: [String]]) async throws {
        let lookupKeys = pendingUserInputLookupKeys(sessionID: sessionID, requestID: requestID)
        guard let request = lookupKeys.compactMap({ pendingUserInputRequestsByID[$0] }).first else {
            throw CodexAppServerSessionRuntimeError.userInputRequestNotFound(requestID)
        }
        try await ensureConnection().respond(to: request, result: userInputResponse(for: request, answers: answers))
    }

    static func gatewayURL(endpoint: String, sessionID: SessionID, runtimeProvider: String = "codex") throws -> URL {
        // WebSocket 也必须复用 HTTP Endpoint 策略；ATS 不会替应用阻止自行构造的公网 ws:// 地址。
        let validatedEndpoint = try EndpointTransportPolicy.validatedEndpoint(endpoint)
        guard var components = URLComponents(string: validatedEndpoint) else {
            throw AgentAPIError.invalidEndpoint
        }
        switch components.scheme {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            throw AgentAPIError.invalidEndpoint
        }
        components.path = "/api/app-server/ws"
        var queryItems = [URLQueryItem(name: "thread_id", value: sessionID)]
        let runtime = normalizedRuntimeProvider(runtimeProvider)
        if runtime != "codex" {
            queryItems.append(URLQueryItem(name: "runtime", value: runtime))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw AgentAPIError.invalidEndpoint
        }
        return url
    }

    static func normalizedRuntimeProvider(_ raw: String?) -> String {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch value {
        case "", "codex", "openai", "codex_app_server", "codex-app-server":
            return "codex"
        case "claude", "anthropic", "claude_code", "claude-code", "claude_code_bridge", "claude-code-bridge":
            return "claude"
        default:
            return value
        }
    }

    func detachEvents(sessionID: SessionID, token: UUID) {
        eventMailboxesBySessionID[sessionID]?.removeValue(forKey: token)
        if eventMailboxesBySessionID[sessionID]?.isEmpty == true {
            eventMailboxesBySessionID.removeValue(forKey: sessionID)
        }
    }

    func ensureConfig(forceRefresh: Bool = false) async throws -> CodexAppServerConfigResponse {
        if let config, !forceRefresh {
            return config
        }
        let next = try await configProvider()
        config = next
        return next
    }

    func ensureConnection() async throws -> CodexAppServerConnection {
        if let connection {
            if await connection.isReadyForRequests() {
                return connection
            }
            await retireConnection(connection)
        }
        if let connectionTask {
            return try await installPreparedConnectionIfNeeded(from: connectionTask)
        }
        let config = try await connectionConfig()
        guard runtimeGatewayAvailable(in: config) else {
            throw CodexAppServerSessionRuntimeError.gatewayUnavailable
        }
        let gatewayURL = try gatewayURL(from: config)
        let next = CodexAppServerConnection(transport: transportFactory(), requestTimeout: requestTimeout)
        let task = Task { [next, gatewayURL, token] in
            let notifications = await next.notifications()
            let serverRequests = await next.serverRequests()
            try await next.connect(url: gatewayURL, token: token)
            return CodexAppServerPreparedConnection(
                connection: next,
                notifications: notifications,
                serverRequests: serverRequests
            )
        }
        connectionTask = task
        do {
            return try await installPreparedConnectionIfNeeded(from: task)
        } catch {
            connectionTask = nil
            await next.disconnect()
            throw error
        }
    }

    func installPreparedConnectionIfNeeded(
        from task: Task<CodexAppServerPreparedConnection, Error>
    ) async throws -> CodexAppServerConnection {
        let prepared: CodexAppServerPreparedConnection
        do {
            prepared = try await task.value
            connectionTask = nil
        } catch {
            connectionTask = nil
            throw error
        }
        if let connection, await connection.isReadyForRequests() {
            return connection
        }
        installConnection(prepared)
        return prepared.connection
    }

    func connectionConfig() async throws -> CodexAppServerConfigResponse {
        let cached = try await ensureConfig()
        if runtimeGatewayAvailable(in: cached) {
            return cached
        }
        // 首次冷启动时 agentd 可能先返回项目列表，但 app-server gateway 仍在启动。
        // 这种不可用 config 不能长期缓存，否则 bootstrap 重试会一直复用旧状态，直到用户杀掉 APP。
        let fresh = try await ensureConfig(forceRefresh: true)
        if runtimeGatewayAvailable(in: fresh) {
            return fresh
        }
        throw CodexAppServerSessionRuntimeError.gatewayUnavailable
    }

    func installConnection(_ prepared: CodexAppServerPreparedConnection) {
        notificationPumpTask?.cancel()
        serverRequestPumpTask?.cancel()
        // 新连接还没在 app-server 上 resume 任何 thread，清空记录，逼迫下一次发送先补 resume。
        threadsResumedOnConnection.removeAll(keepingCapacity: true)
        connection = prepared.connection
        notificationPumpTask = Task { [weak self, notifications = prepared.notifications, installedConnection = prepared.connection] in
            for await notification in notifications {
                await self?.handle(notification)
            }
            guard !Task.isCancelled else {
                return
            }
            await self?.handleNotificationStreamEnded(for: installedConnection)
        }
        serverRequestPumpTask = Task { [weak self, serverRequests = prepared.serverRequests] in
            for await request in serverRequests {
                await self?.handle(request)
            }
        }
    }

    func handleNotificationStreamEnded(for endedConnection: CodexAppServerConnection) async {
        guard let current = connection, current === endedConnection else {
            return
        }

        // 底层 receive 失败会结束 notification stream。这里必须继续结束上层 AgentEvent stream，
        // 否则 SessionWebSocketClient 的 for-await 永远不退出，UI 会一直误认为连接仍是 connected。
        notificationPumpTask = nil
        serverRequestPumpTask?.cancel()
        serverRequestPumpTask = nil
        connection = nil
        threadsResumedOnConnection.removeAll(keepingCapacity: true)
        let affected = clearAllPendingServerRequests()
        for sessionID in affected.approvalSessionIDs {
            emitApprovalResolved(sessionID: sessionID)
        }
        for sessionID in affected.userInputSessionIDs {
            emitUserInputResolved(sessionID: sessionID, skipped: false)
        }
        finishAttachedEventStreams()
        await endedConnection.disconnect()
    }

    func finishAttachedEventStreams() {
        let mailboxes = eventMailboxesBySessionID.values.flatMap { $0.values }
        eventMailboxesBySessionID.removeAll(keepingCapacity: true)
        for mailbox in mailboxes {
            mailbox.finishFromProducer()
        }
    }

    func sendRecoveringFromStaleInitialization(
        _ request: CodexAppServerRequestSpec,
        timeout: TimeInterval? = nil
    ) async throws -> CodexAppServerJSONValue? {
        let firstConnection = try await ensureConnection()
        do {
            return try await firstConnection.send(request, timeout: timeout)
        } catch {
            if await recoverConnectionAfterStaleInitialization(firstConnection, error: error) {
                let secondConnection = try await ensureConnection()
                do {
                    return try await secondConnection.send(request, timeout: timeout)
                } catch {
                    await retireCurrentConnectionAfterRecoverableError(secondConnection, error: error)
                    throw error
                }
            }
            await retireCurrentConnectionAfterRecoverableError(firstConnection, error: error)
            throw error
        }
    }

    func recoverConnectionAfterStaleInitialization(_ stale: CodexAppServerConnection, error: Error) async -> Bool {
        guard isStaleInitializationError(error) else {
            return false
        }
        if let current = connection, current === stale {
            // app-server upstream 重启或 gateway 旧连接错位时会返回 -32600 Not initialized。
            // 这不是用户请求本身非法，丢弃当前连接并重新 initialize 后重试一次即可自愈。
            await retireConnection(stale)
        } else {
            // 并发发送/重连可能已经把 actor 里的 current connection 清空或替换；
            // stale 请求仍应允许重试一次，但不能误删另一条刚建立好的连接。
            await stale.disconnect()
        }
        return true
    }

    func retireConnection(_ stale: CodexAppServerConnection) async {
        guard let current = connection, current === stale else {
            // actor 在前面的 await 期间可能已经安装了新连接；旧请求只能关闭自己，不能清理新代次。
            await stale.disconnect()
            return
        }
        notificationPumpTask?.cancel()
        notificationPumpTask = nil
        serverRequestPumpTask?.cancel()
        serverRequestPumpTask = nil
        connection = nil
        threadsResumedOnConnection.removeAll(keepingCapacity: true)
        let affected = clearAllPendingServerRequests()
        for sessionID in affected.approvalSessionIDs {
            emitApprovalResolved(sessionID: sessionID)
        }
        for sessionID in affected.userInputSessionIDs {
            emitUserInputResolved(sessionID: sessionID, skipped: false)
        }
        // 主动淘汰不可用连接时也要结束上层订阅；否则被取消的 notification pump 不会再走
        // 异常结束 handler，SessionStore 仍可能把这条已失效连接看成 connected。
        finishAttachedEventStreams()
        await stale.disconnect()
    }

    func retireCurrentConnectionAfterRecoverableError(_ stale: CodexAppServerConnection, error: Error) async {
        guard isRecoverableConnectionError(error),
              let current = connection,
              current === stale else {
            return
        }
        // turn/start 失败后不要继续复用半断连接；重连会重新 thread/resume 并补拉历史。
        await retireConnection(stale)
    }

    func isRecoverableConnectionError(_ error: Error) -> Bool {
        guard let error = error as? CodexAppServerConnectionError else {
            return false
        }
        switch error {
        case .disconnected, .notInitialized, .timeout, .transport:
            return true
        case .appServer(let appServerError):
            return isStaleInitializationAppServerError(appServerError)
        case .duplicateRequestID, .decoding:
            return false
        }
    }

    func isStaleInitializationError(_ error: Error) -> Bool {
        guard let error = error as? CodexAppServerConnectionError else {
            return false
        }
        switch error {
        case .notInitialized:
            return true
        case .appServer(let appServerError):
            return isStaleInitializationAppServerError(appServerError)
        default:
            return false
        }
    }

    func isStaleInitializationAppServerError(_ error: CodexAppServerError) -> Bool {
        error.code == -32600
            && error.message.range(of: "not initialized", options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    // thread/resume 命中“no rollout found for thread id …”：线程已存在于 app-server，但还没有任何 turn
    // 落盘 rollout（新建空会话的典型状态）。不同 app-server 版本回的 code 不一致（实测 -32600，旧 mock 用
    // -32000），所以只认消息、不锁 code，避免漏判。仅用于 thread/resume 这类“绑定监听”路径的良性放行；
    // turn/start 自身回的 no rollout 仍按业务错误向上抛。
    func isNoRolloutFoundError(_ error: Error) -> Bool {
        guard let error = error as? CodexAppServerConnectionError,
              case .appServer(let appServerError) = error else {
            return false
        }
        return appServerError.message.range(of: "no rollout found", options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    func hasReadyConnectionForTesting() async -> Bool {
        guard let connection else {
            return false
        }
        return await connection.isReadyForRequests()
    }

    func gatewayURL(from config: CodexAppServerConfigResponse) throws -> URL {
        guard runtimeGatewayAvailable(in: config) else {
            throw CodexAppServerSessionRuntimeError.gatewayUnavailable
        }
        // config 只用于确认 gateway 能力；真实 URL 始终从当前连接代次的 endpoint 派生。
        // 这样 REST 与 WebSocket 不会因为反向代理返回了另一 Host 而分裂到不同链路。
        return try Self.gatewayURL(endpoint: endpoint, sessionID: "", runtimeProvider: runtimeProvider)
    }

    func runtimeGatewayAvailable(in config: CodexAppServerConfigResponse) -> Bool {
        if runtimeProvider == "codex" {
            return runtimeGatewayChannel(in: config)?.gatewayAvailable ?? config.runtime.gatewayAvailable
        }
        return runtimeGatewayChannel(in: config)?.gatewayAvailable == true
    }

    func runtimeGatewayChannel(in config: CodexAppServerConfigResponse) -> CodexAppServerChannelMetadata? {
        config.channels.first { channel in
            Self.normalizedRuntimeProvider(channel.runtimeID ?? channel.id) == runtimeProvider ||
                Self.normalizedRuntimeProvider(channel.provider) == runtimeProvider
        }
    }

    func handle(_ notification: CodexAppServerNotification) {
        recordLiveSignal(from: notification)
        updateContext(from: notification)
        let resolved = clearResolvedServerRequest(from: notification)
        if notification.method == "serverRequest/resolved",
           !resolved.approvalSessionIDs.isEmpty || !resolved.userInputSessionIDs.isEmpty {
            // resolved 通知本身不区分 approval 和 requestUserInput/MCP form。必须根据本地挂起表
            // 投影对应的 resolved 事件，否则 MCP 表单已回答后补充信息卡仍会留在 UI。
            for sessionID in resolved.approvalSessionIDs {
                emitApprovalResolved(sessionID: sessionID)
            }
            for sessionID in resolved.userInputSessionIDs {
                emitUserInputResolved(sessionID: sessionID, skipped: false)
            }
            return
        }
        if notification.method == "deprecationNotice",
           approvalSessionID(from: notification.params?.objectValue ?? [:]) == nil {
            // deprecationNotice 是连接级通知，官方协议不带 threadId。直接 emit 会被路由层丢弃，
            // 因此将它投递给当前连接已知会话，让用户真正看到升级提示。
            let params = notification.params?.objectValue ?? [:]
            let summary = params["summary"]?.stringValue ?? L10n.text("ui.app_server_protocol_capability_is_obsolete")
            let details = params["details"]?.stringValue
            let payload = AgentErrorPayload(
                message: [summary, details].compactMap { $0 }.joined(separator: "\n"),
                code: "deprecationNotice",
                retryable: false
            )
            for sessionID in contextsBySessionID.keys {
                emit(.warning(payload, metadata(threadID: sessionID, turnID: nil)))
            }
            return
        }
        guard let event = projector.project(notification) else {
            for sessionID in resolved.approvalSessionIDs {
                emitApprovalResolved(sessionID: sessionID)
            }
            for sessionID in resolved.userInputSessionIDs {
                emitUserInputResolved(sessionID: sessionID, skipped: false)
            }
            return
        }
        emit(event)
        let emittedSessionID = sessionID(from: event)
        for sessionID in resolved.approvalSessionIDs where sessionID != emittedSessionID {
            emitApprovalResolved(sessionID: sessionID)
        }
        for sessionID in resolved.userInputSessionIDs where sessionID != emittedSessionID {
            emitUserInputResolved(sessionID: sessionID, skipped: false)
        }
    }

    func handle(_ request: CodexAppServerServerRequest) {
        if isUserInputServerRequest(request) {
            handleUserInputRequest(request)
            return
        }
        if isStaleReplayedApproval(request) {
            // app-server 在 resume 时会把"仍未应答"的 server request 重新投递给新连接。如果这个审批属于
            // 一个本地权威状态已经空闲、且没有活跃 turn 的 thread，它必然是某个被放弃的旧 turn 残留下来的
            // 僵尸请求（原 turn 早已结束，永远不会再有 serverRequest/resolved）。直接回 decline 把它从
            // app-server 的挂起表里释放，避免每次重连又被重放，也就不会再在输入框上方堆出过期审批卡。
            releaseStaleApprovalRequest(request)
            return
        }
        rememberPendingApprovalRequest(request)
        guard let event = projector.project(request) else {
            return
        }
        emit(event)
    }

    func handleUserInputRequest(_ request: CodexAppServerServerRequest) {
        let sessionID = approvalSessionID(for: request)
        if let sessionID, userInputPromptsEnabledBySessionID[sessionID] == false {
            autoResolveUserInputRequest(request, sessionID: sessionID)
            return
        }
        rememberPendingUserInputRequest(request)
        guard let event = projector.project(request) else {
            return
        }
        emit(event)
    }

    func autoResolveUserInputRequest(_ request: CodexAppServerServerRequest, sessionID: SessionID?) {
        removePendingUserInputRequest(request)
        guard let connection else {
            return
        }
        Task { [connection, sessionID] in
            do {
                try await connection.respond(to: request, result: self.userInputResponse(for: request, answers: [:]))
                if let sessionID {
                    self.emitUserInputResolved(sessionID: sessionID, skipped: true)
                }
            } catch {}
        }
    }

    func isStaleReplayedApproval(_ request: CodexAppServerServerRequest) -> Bool {
        if request.method == "mcpServer/elicitation/request" {
            // MCP elicitation 可以是与 turn 无关的独立请求，turnId 在官方协议中本来就可为 null。
            // 不能因 thread 当前 idle 就把真实 URL 确认当成过期审批自动拒绝。
            return false
        }
        guard isApprovalLikeServerRequest(request),
              let sessionID = approvalSessionID(for: request),
              let context = contextsBySessionID[sessionID] else {
            // 不认识的 thread 或拿不到本地会话状态时，保守地照常弹卡，避免误杀真实审批。
            return false
        }
        if sessionsStartingTurn.contains(sessionID) {
            // 正在 startTurn 的挂起窗口内：activeTurnID/状态都还没回填，这一刻到达的审批属于刚发起的
            // 新 turn，绝不能当成过期重放。
            return false
        }
        let requestTurnID = approvalTurnID(for: request)
        if let requestTurnID, turnsStartedByThisRuntime.contains(requestTurnID) {
            // 本端这条 runtime 亲自发起的 turn 的审批一定是 live 的，必须展示（即使已经挂了很久）。
            return false
        }
        // app-server 已切到新的 active turn，但仍重放旧 turn 的审批：本地 active turn 与审批 turnId 不同。
        if let requestTurnID,
           let activeTurnID = context.activeTurnID,
           context.session.status == "waiting_for_approval",
           requestTurnID != activeTurnID {
            return true
        }

        // 正在执行的 turn（无论谁发起）本地状态都会是 running/waiting 且记着 activeTurnID；
        // 只有 app-server 自己把该 thread 报成空闲、且本地没有活跃 turn 时，才判定为过期重放。
        return context.activeTurnID == nil && isInactiveThreadStatus(context.session.status)
    }

    func isInactiveThreadStatus(_ status: String) -> Bool {
        switch status {
        case "running", "waiting_for_approval", "waiting_for_input":
            return false
        default:
            return true
        }
    }
}
