import Foundation

enum CodexAppServerSessionRuntimeError: LocalizedError {
    case invalidGatewayURL
    case gatewayUnavailable
    case projectNotFound(String)
    case projectRequired
    case sessionNotFound(SessionID)
    case missingActiveTurn(SessionID)
    case approvalNotFound(String)
    case userInputRequestNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidGatewayURL:
            return "app-server gateway URL 无效"
        case .gatewayUnavailable:
            return "agentd 未启用 app-server gateway，请先配置 loopback app-server WebSocket upstream"
        case .projectNotFound(let projectID):
            return "项目不存在或未加入 allowlist：\(projectID)"
        case .projectRequired:
            return "direct 模式必须先选择 allowlist 项目"
        case .sessionNotFound(let sessionID):
            return "app-server thread 不存在：\(sessionID)"
        case .missingActiveTurn(let sessionID):
            return "当前会话没有可中断的 active turn：\(sessionID)"
        case .approvalNotFound(let approvalID):
            return "审批请求已失效：\(approvalID)"
        case .userInputRequestNotFound(let requestID):
            return "补充信息请求已失效：\(requestID)"
        }
    }
}

private struct CodexAppServerSessionContext {
    var session: AgentSession
    var cwd: String
    var activeTurnID: TurnID?
}

private struct CodexAppServerPreparedConnection {
    let connection: CodexAppServerConnection
    let notifications: AsyncStream<CodexAppServerNotification>
    let serverRequests: AsyncStream<CodexAppServerServerRequest>
}

private struct CodexAppServerResolvedServerRequests {
    var approvalSessionIDs: [SessionID] = []
    var userInputSessionIDs: [SessionID] = []
}

enum CodexAppServerBufferedEventReplayPolicy {
    case all
    case stateOnly
}

actor CodexAppServerSessionRuntime {
    private let endpoint: String
    private let token: String
    private let runtimeProvider: String
    private let transportFactory: () -> CodexAppServerTransport
    private let configProvider: () async throws -> CodexAppServerConfigResponse
    private var config: CodexAppServerConfigResponse?
    private var connection: CodexAppServerConnection?
    private var connectionTask: Task<CodexAppServerPreparedConnection, Error>?
    private var notificationPumpTask: Task<Void, Never>?
    private var serverRequestPumpTask: Task<Void, Never>?
    private var projector = CodexAppServerEventProjector()
    private var contextsBySessionID: [SessionID: CodexAppServerSessionContext] = [:]
    // app-server 只向「在当前 gateway 连接上 resume/start 过」的 thread 推送 turn 事件；记录本连接已
    // 经绑定的 thread，断线重连后这个集合随新连接清空，确保再次发送时会先补一次 thread/resume。
    private var threadsResumedOnConnection: Set<SessionID> = []
    private var bufferedEventsBySessionID: [SessionID: [AgentEvent]] = [:]
    private var eventContinuationsBySessionID: [SessionID: AsyncStream<AgentEvent>.Continuation] = [:]
    private var pendingApprovalRequestsByID: [String: CodexAppServerServerRequest] = [:]
    private var pendingUserInputRequestsByID: [String: CodexAppServerServerRequest] = [:]
    private var userInputPromptsEnabledBySessionID: [SessionID: Bool] = [:]
    private var accountRateLimit: RateLimitSummary?
    private var rateLimitRefreshTask: Task<RateLimitSummary?, Never>?
    private var lastRateLimitRefreshAt: Date?
    // 正在 startTurn 中的 thread：turn/start 请求挂起期间，actor 会重入处理 server-request，
    // 此时本地还没记上 activeTurnID、状态也可能仍是空闲。这一窗口内到达的审批一定属于刚发起的
    // 新 turn，不能被 isStaleReplayedApproval 误判成过期重放。
    private var sessionsStartingTurn: Set<SessionID> = []
    // 本端这条 runtime 亲自发起过的 turn。app-server 在 resume 时会重放“仍未应答”的审批；只有属于这些
    // turn 的审批才是当前用户真正在等待的，其余（Desktop 发起、或历史里没 terminal 化的旧审批）需要按
    // 过期处理。即使本端的审批挂了很久也不能误杀，所以单列出来优先放行。
    private var turnsStartedByThisRuntime: Set<TurnID> = []
    // thread/read 没有分页参数，一次会返回整段 thread。把上次整段读取缓存下来，翻看更早历史时直接
    // 从缓存切窗口，避免每次翻页都在 Tailscale 这类慢链路上重新拉一遍大会话（会很慢甚至超时）。
    private var threadHistoryCacheBySessionID: [SessionID: [CodexHistoryMessage]] = [:]
    private var threadAuthoritativeCompletedTurnItemsBySessionID: [SessionID: [TurnID: Set<AgentItemID>]] = [:]
    private var threadTurnsListUnavailable = false
    private var turnStartTasksBySessionID: [SessionID: (token: UUID, task: Task<TurnID?, Error>)] = [:]
    // thread/list 在远程/VPS 中转链路上可能要扫本机 Codex 历史并传回较大的 JSON。
    // 只给列表请求放宽超时，避免影响 turn/start 等交互命令的失败反馈速度。
    private let threadListRequestTimeout: TimeInterval = 60
    private let requestTimeout: TimeInterval
    private var rateLimitRequestTimeout: TimeInterval {
        min(requestTimeout, 5)
    }
    // 每个 thread 最近一次收到上游实时通知的时间。thread/list、thread/read 偶发把正在执行的
    // turn 误读成 idle/notLoaded；刚收到过实时信号的 thread 在这个时间窗内不接受 history 降级。
    private var lastLiveSignalAtBySessionID: [SessionID: Date] = [:]
    private let historyDowngradeGraceInterval: TimeInterval = 15

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
        // Skills/MCP 浏览是 agentd 控制面的只读发现能力，不走 app-server JSON-RPC。
        try await AgentAPIClient(endpoint: endpoint, token: token).capabilities(path: path)
    }

    func transcribeVoice(filename: String, contentType: String, audioData: Data, language: String?, prompt: String?) async throws -> VoiceTranscriptionResponse {
        // 语音转写属于 agentd 控制面：移动端只上传音频，API Key 和模型配置都留在 agentd。
        try await AgentAPIClient(endpoint: endpoint, token: token).transcribeVoice(
            filename: filename,
            contentType: contentType,
            audioData: audioData,
            language: language,
            prompt: prompt
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

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        let projects = try await projects()
        guard let projectID else {
            throw CodexAppServerSessionRuntimeError.projectRequired
        }
        guard let project = projects.first(where: { $0.id == projectID }) else {
            throw CodexAppServerSessionRuntimeError.projectNotFound(projectID)
        }
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: projects)
        let spec = try builder.threadList(cwd: project.path, limit: limit, cursor: cursor)

        let result = try await sendRecoveringFromStaleInitialization(spec, timeout: threadListRequestTimeout)
        let page = threadListPage(from: result, projects: projects, fallbackProject: project)
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

    func sessionsPage(workspace: AgentWorkspace, cursor: String?, limit: Int?) async throws -> SessionsPage {
        let baseProjects = try await projects()
        let projects = projectsIncludingWorkspace(baseProjects, workspace: workspace)
        let workspaceProject = workspace.project
        let listCWD = threadListCWD(for: workspace, projects: baseProjects)
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: projects)
        let spec = try builder.threadList(cwd: listCWD, limit: limit, cursor: cursor)

        let result = try await sendRecoveringFromStaleInitialization(spec, timeout: threadListRequestTimeout)
        let page = threadListPage(from: result, projects: projects, fallbackProject: workspaceProject)
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

        let result = try await sendRecoveringFromStaleInitialization(spec)
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
    private static let bulkReadTimeout: TimeInterval = 60
    private static let threadTurnsCursorPrefix = "turns:"
    private static let economyHistoryNotice = "此会话包含较大的图片或工具输出，已使用省流模式加载。"

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

    private func messagesPageFromFullThreadRead(
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
            contextsBySessionID[sessionID] = CodexAppServerSessionContext(
                session: session,
                cwd: session.dir,
                activeTurnID: session.activeTurnID
            )
            context = session.context
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

    private func messagesPageFromTurnPages(
        sessionID: SessionID,
        before: String?,
        limit: Int?,
        loadMode: HistoryMessagesPage.LoadMode,
        projects: [AgentProject]
    ) async throws -> HistoryMessagesPage {
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: projects)
        let cursor = Self.decodeThreadTurnsCursor(before)
        let metadata = try await threadMetadataForHistoryPage(
            sessionID: sessionID,
            builder: builder,
            projects: projects,
            shouldRefresh: before == nil || contextsBySessionID[sessionID] == nil
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
        var thread = metadata ?? historyThreadShell(sessionID: sessionID, projects: projects)
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

    private func threadMetadataForHistoryPage(
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

    private func contextForHistoryThread(
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

    private func historyThreadShell(
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

    private func shouldUseThreadTurnsList(config: CodexAppServerConfigResponse) -> Bool {
        !threadTurnsListUnavailable && config.policy.allowedMethods.contains("thread/turns/list")
    }

    private func shouldFallbackFromThreadTurnsList(_ error: Error) -> Bool {
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

    private static func threadTurnPageLimit(forMessageLimit limit: Int?, loadMode: HistoryMessagesPage.LoadMode) -> Int {
        let requestedMessages = max(1, limit ?? 120)
        switch loadMode {
        case .economy:
            // 核心逻辑：一条 turn 可能包含 base64 图片或超长工具输出。
            // 控制 turn 页大小，比降低 WebSocket message size 更温和，不会制造重连风暴。
            return max(5, min(20, (requestedMessages + 3) / 4))
        case .full:
            // full 手动加载仍要服从 Go gateway 的硬上限，避免按钮在公网模式下被 50 limit 拒绝。
            return max(10, min(50, (requestedMessages + 1) / 2))
        }
    }

    private static func threadTurnItemsView(loadMode: HistoryMessagesPage.LoadMode) -> String {
        switch loadMode {
        case .economy:
            return "summary"
        case .full:
            return "full"
        }
    }

    private static func authoritativeCompletedTurnItems(
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

    private static func historyNotice(
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

    private static func encodeThreadTurnsCursor(_ cursor: String) -> String {
        threadTurnsCursorPrefix + Data(cursor.utf8).base64EncodedString()
    }

    private static func decodeThreadTurnsCursor(_ cursor: String?) -> String? {
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
    ) -> AsyncStream<AgentEvent> {
        var continuation: AsyncStream<AgentEvent>.Continuation?
        // 这里承接的是已经投影好的 thread 事件；正常连接完整保序交付，切回会话的 backlog
        // 可降级为状态级回放，避免历史输出在消息区重新直播一遍。
        let stream = AsyncStream<AgentEvent>(bufferingPolicy: .unbounded) {
            continuation = $0
        }
        if let continuation {
            eventContinuationsBySessionID[sessionID] = continuation
            for event in bufferedEvents(sessionID: sessionID, replayPolicy: replayPolicy) {
                continuation.yield(event)
            }
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.detachEvents(sessionID: sessionID)
                }
            }
        }
        return stream
    }

    private func bufferedEvents(
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
        case .messageCompleted,
             .processItemCompleted:
            // thread/read 快照不含 commandExecution 等过程 item；completed 内容事件必须补播，
            // 否则离开期间完成的命令卡会永久丢失。排序与去重由 ConversationStore 兜底。
            return true
        case .assistantDelta,
             .logDelta,
             .diffUpdated:
            return false
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
    private func performStartTurn(sessionID: SessionID, payload: CodexAppServerTurnPayload, clientMessageID: ClientMessageID?) async throws -> TurnID? {
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

    private func clearTurnStartTask(sessionID: SessionID, token: UUID) {
        guard turnStartTasksBySessionID[sessionID]?.token == token else {
            return
        }
        turnStartTasksBySessionID.removeValue(forKey: sessionID)
    }

    // thread/start、thread/resume 的 options 必须按本 runtime 的通道策略先降级再发送：
    // Claude 通道不接受 dangerFullAccess，.default 草稿直接上桥会被 gateway 拒绝，
    // 会话恢复就会陷入确定性失败的重连循环。runtime 连接的 gateway 由自身 runtimeProvider
    // 决定，所以这里强制以 actor 的 runtime 为准，而不是相信 payload 里的残留值。
    private func runtimeScopedThreadOptions(_ options: CodexAppServerTurnOptions) -> CodexAppServerTurnOptions {
        var scoped = options
        scoped.runtimeProvider = runtimeProvider
        return scoped.sanitizedForRuntimePolicy()
    }

    // 直连发送路径下，thread 可能只在 thread/list 或 thread/start 里出现过，但没有在当前 gateway
    // 连接上执行过 thread/resume。真实 app-server 只有 resume 后才稳定建立 live listener；
    // 否则 turn/start 虽然被接受，iPad 也可能收不到 turn/started、delta 和 completed，界面就会一直等待。
    private func ensureThreadResumedOnConnection(
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
            if isNoRolloutFoundError(error) {
                // 刚 thread/start、还没跑过任何 turn 的新线程在上游没有 rollout 文件，thread/resume 会返回
                // -32600 "no rollout found"。这类线程已经在本连接上被 thread/start 绑定，resume 只是冗余；
                // 标记为已 resume 并放行，等首个 turn/start 落盘 rollout 后事件自然回流。否则空会话开屏即
                // 因 connectForEvents 抛错进入“WebSocket 断开，正在自动重连”的死循环。
                threadsResumedOnConnection.insert(sessionID)
                return
            }
            throw error
        }
        if let thread = threadObject(from: result),
           let session = try? agentSession(
            from: thread,
            projects: (try? projectsFromCache()) ?? [],
            fallbackProject: nil
           ) {
            contextsBySessionID[session.id] = CodexAppServerSessionContext(
                session: session,
                cwd: session.dir,
                activeTurnID: session.activeTurnID
            )
            emit(.session(session))
        }
        threadsResumedOnConnection.insert(sessionID)
    }

    private func refreshThreadGoalIfAvailable(
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
        try await ensureConnection().respond(to: request, result: userInputResponse(answers: answers))
    }

    static func gatewayURL(endpoint: String, sessionID: SessionID, runtimeProvider: String = "codex") throws -> URL {
        guard var components = URLComponents(string: AgentAPIClient.normalizedEndpoint(endpoint)) else {
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

    private func detachEvents(sessionID: SessionID) {
        eventContinuationsBySessionID.removeValue(forKey: sessionID)
    }

    private func ensureConfig(forceRefresh: Bool = false) async throws -> CodexAppServerConfigResponse {
        if let config, !forceRefresh {
            return config
        }
        let next = try await configProvider()
        config = next
        return next
    }

    private func ensureConnection() async throws -> CodexAppServerConnection {
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

    private func installPreparedConnectionIfNeeded(
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

    private func connectionConfig() async throws -> CodexAppServerConfigResponse {
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

    private func installConnection(_ prepared: CodexAppServerPreparedConnection) {
        notificationPumpTask?.cancel()
        serverRequestPumpTask?.cancel()
        // 新连接还没在 app-server 上 resume 任何 thread，清空记录，逼迫下一次发送先补 resume。
        threadsResumedOnConnection.removeAll(keepingCapacity: true)
        connection = prepared.connection
        notificationPumpTask = Task { [weak self, notifications = prepared.notifications] in
            for await notification in notifications {
                await self?.handle(notification)
            }
        }
        serverRequestPumpTask = Task { [weak self, serverRequests = prepared.serverRequests] in
            for await request in serverRequests {
                await self?.handle(request)
            }
        }
    }

    private func sendRecoveringFromStaleInitialization(
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

    private func recoverConnectionAfterStaleInitialization(_ stale: CodexAppServerConnection, error: Error) async -> Bool {
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

    private func retireConnection(_ stale: CodexAppServerConnection) async {
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
        await stale.disconnect()
    }

    private func retireCurrentConnectionAfterRecoverableError(_ stale: CodexAppServerConnection, error: Error) async {
        guard isRecoverableConnectionError(error),
              let current = connection,
              current === stale else {
            return
        }
        // turn/start 失败后不要继续复用半断连接；重连会重新 thread/resume 并补拉历史。
        await retireConnection(stale)
    }

    private func isRecoverableConnectionError(_ error: Error) -> Bool {
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

    private func isStaleInitializationError(_ error: Error) -> Bool {
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

    private func isStaleInitializationAppServerError(_ error: CodexAppServerError) -> Bool {
        error.code == -32600
            && error.message.range(of: "not initialized", options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    // thread/resume 命中“no rollout found for thread id …”：线程已存在于 app-server，但还没有任何 turn
    // 落盘 rollout（新建空会话的典型状态）。不同 app-server 版本回的 code 不一致（实测 -32600，旧 mock 用
    // -32000），所以只认消息、不锁 code，避免漏判。仅用于 thread/resume 这类“绑定监听”路径的良性放行；
    // turn/start 自身回的 no rollout 仍按业务错误向上抛。
    private func isNoRolloutFoundError(_ error: Error) -> Bool {
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

    private func gatewayURL(from config: CodexAppServerConfigResponse) throws -> URL {
        if let channel = runtimeGatewayChannel(in: config),
           channel.gatewayAvailable,
           let url = URL(string: channel.gatewayWSURL),
           !channel.gatewayWSURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return url
        }
        if runtimeProvider != "codex" {
            throw CodexAppServerSessionRuntimeError.gatewayUnavailable
        }
        if let url = URL(string: config.gatewayWSURL), !config.gatewayWSURL.isEmpty {
            return url
        }
        guard let url = URL(string: try Self.gatewayURL(endpoint: endpoint, sessionID: "", runtimeProvider: runtimeProvider).absoluteString) else {
            throw CodexAppServerSessionRuntimeError.invalidGatewayURL
        }
        return url
    }

    private func runtimeGatewayAvailable(in config: CodexAppServerConfigResponse) -> Bool {
        if runtimeProvider == "codex" {
            return runtimeGatewayChannel(in: config)?.gatewayAvailable ?? config.runtime.gatewayAvailable
        }
        return runtimeGatewayChannel(in: config)?.gatewayAvailable == true
    }

    private func runtimeGatewayChannel(in config: CodexAppServerConfigResponse) -> CodexAppServerChannelMetadata? {
        config.channels.first { channel in
            Self.normalizedRuntimeProvider(channel.runtimeID ?? channel.id) == runtimeProvider ||
                Self.normalizedRuntimeProvider(channel.provider) == runtimeProvider
        }
    }

    private func handle(_ notification: CodexAppServerNotification) {
        recordLiveSignal(from: notification)
        updateContext(from: notification)
        let resolved = clearResolvedServerRequest(from: notification)
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

    private func handle(_ request: CodexAppServerServerRequest) {
        if isUserInputServerRequest(request.method) {
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

    private func handleUserInputRequest(_ request: CodexAppServerServerRequest) {
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

    private func autoResolveUserInputRequest(_ request: CodexAppServerServerRequest, sessionID: SessionID?) {
        removePendingUserInputRequest(request)
        guard let connection else {
            return
        }
        Task { [connection, sessionID] in
            do {
                try await connection.respond(to: request, result: self.userInputResponse(answers: [:]))
                if let sessionID {
                    self.emitUserInputResolved(sessionID: sessionID, skipped: true)
                }
            } catch {}
        }
    }

    private func isStaleReplayedApproval(_ request: CodexAppServerServerRequest) -> Bool {
        guard isApprovalLikeServerRequest(request.method),
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

    private func isInactiveThreadStatus(_ status: String) -> Bool {
        switch status {
        case "running", "waiting_for_approval", "waiting_for_input":
            return false
        default:
            return true
        }
    }

    private func releaseStaleApprovalRequest(_ request: CodexAppServerServerRequest) {
        removePendingApprovalRequest(request)
        guard let connection else {
            return
        }
        let sessionID = approvalSessionID(for: request)
        let params = request.params?.objectValue ?? [:]
        let result = approvalResponse(
            method: request.method,
            params: params,
            decision: staleReleaseDecision(from: params)
        )
        Task { [connection, sessionID] in
            // 释放失败（连接已断或 app-server 已自行清理）无所谓：下次 resume 仍会重新走这套判断。
            do {
                try await connection.respond(to: request, result: result)
                if let sessionID {
                    self.emitApprovalResolved(sessionID: sessionID)
                }
            } catch {}
        }
    }

    // 释放旧审批要用 app-server 真正支持的“放弃”决策才能把请求 terminal 化，否则它会一直挂在挂起表里、
    // 每次 resume 又被重放。命令/文件审批的 availableDecisions 通常是 ["accept", "cancel"]，没有 decline，
    // 所以优先选 cancel/reject；只有在请求没带 availableDecisions 时（如旧 mock）才退回 decline。
    private func staleReleaseDecision(from params: [String: CodexAppServerJSONValue]) -> String {
        let available = (params["availableDecisions"]?.arrayValue ?? []).compactMap { $0.stringValue?.lowercased() }
        for candidate in ["cancel", "reject", "deny", "decline"] where available.contains(candidate) {
            return candidate
        }
        return "decline"
    }

    // 只有仍在活动的通知才算实时信号；表示回合/线程结束或权威状态变化的通知不能算，
    // 否则会把合法的 history 降级也挡掉。
    private func recordLiveSignal(from notification: CodexAppServerNotification) {
        switch notification.method {
        case "turn/completed", "thread/closed", "thread/status/changed":
            return
        default:
            break
        }
        let params = notification.params?.objectValue ?? [:]
        guard let threadID = params["threadId"]?.stringValue
            ?? params["thread"]?.objectValue?["id"]?.stringValue else {
            return
        }
        lastLiveSignalAtBySessionID[threadID] = Date()
    }

    private func hasRecentLiveSignal(sessionID: SessionID) -> Bool {
        guard let at = lastLiveSignalAtBySessionID[sessionID] else {
            return false
        }
        return Date().timeIntervalSince(at) < historyDowngradeGraceInterval
    }

    private func emit(_ event: AgentEvent) {
        let sessionID = sessionID(from: event)
        guard let sessionID else {
            return
        }
        if let continuation = eventContinuationsBySessionID[sessionID] {
            continuation.yield(event)
        } else {
            bufferedEventsBySessionID[sessionID, default: []].append(event)
        }
    }

    private func sessionID(from event: AgentEvent) -> SessionID? {
        switch event {
        case .session(let session):
            return session.id
        case .sessionRow(let row, _):
            return row.id
        case .sessionStatus(_, let metadata),
             .sessionContext(_, let metadata),
             .goalCleared(let metadata),
             .turnStarted(let metadata),
             .assistantDelta(_, let metadata),
             .messageCompleted(_, let metadata),
             .processItemCompleted(_, _, let metadata),
             .logDelta(_, let metadata),
             .diffUpdated(_, let metadata),
             .approvalRequest(_, let metadata),
             .approvalResolved(let metadata),
             .userInputRequest(_, let metadata),
             .userInputResolved(let metadata, _),
             .turnCompleted(let metadata),
             .warning(_, let metadata):
            return metadata.sessionID
        case .goalUpdated(let goal, let metadata):
            return metadata.sessionID ?? goal.threadID
        case .error, .unknown:
            return nil
        }
    }

    private func updateContext(from notification: CodexAppServerNotification) {
        let params = notification.params?.objectValue ?? [:]
        switch notification.method {
        case "thread/started":
            guard let thread = params["thread"]?.objectValue,
                  let session = try? agentSession(from: thread, projects: (try? projectsFromCache()) ?? [], fallbackProject: nil, forceRunning: true) else {
                return
            }
            contextsBySessionID[session.id] = CodexAppServerSessionContext(session: session, cwd: session.dir, activeTurnID: session.activeTurnID)
            emit(.session(session))
        case "thread/status/changed":
            guard let threadID = params["threadId"]?.stringValue,
                  let statusValue = params["status"] else {
                return
            }
            let status = sessionStatus(from: statusValue, forceRunning: false)
            _ = withUpdatedSession(threadID) { item in
                item.status = status
            }
            emit(.sessionStatus(status, metadata(threadID: threadID, turnID: nil)))
            emit(.sessionContext(statusContext(threadID: threadID, statusValue: statusValue), metadata(threadID: threadID, turnID: nil)))
        case "thread/closed":
            guard let threadID = params["threadId"]?.stringValue else {
                return
            }
            _ = withUpdatedSession(threadID) { item in
                item.status = "closed"
                item.activeTurnID = nil
            }
            emit(.sessionStatus("closed", metadata(threadID: threadID, turnID: nil)))
            emit(.sessionContext(
                SessionContextSnapshot(
                    sessionID: threadID,
                    threadID: threadID,
                    status: SessionContextStatus(type: "idle"),
                    updatedAt: Date()
                ),
                metadata(threadID: threadID, turnID: nil)
            ))
        case "thread/goal/updated":
            guard let goal = threadGoal(from: .object(params)) else {
                return
            }
            applyThreadGoal(goal)
        case "thread/goal/cleared":
            guard let threadID = params["threadId"]?.stringValue else {
                return
            }
            clearThreadGoalLocal(threadID: threadID)
        case "turn/started":
            guard let threadID = params["threadId"]?.stringValue,
                  let turnID = params["turn"]?.objectValue?["id"]?.stringValue else {
                return
            }
            _ = withUpdatedSession(threadID) { item in
                item.status = "running"
                item.activeTurnID = turnID
            }
            emit(.sessionContext(
                SessionContextSnapshot(
                    sessionID: threadID,
                    threadID: threadID,
                    status: SessionContextStatus(type: "active"),
                    updatedAt: Date()
                ),
                metadata(threadID: threadID, turnID: turnID)
            ))
        case "turn/completed":
            guard let threadID = params["threadId"]?.stringValue else {
                return
            }
            _ = withUpdatedSession(threadID) { item in
                item.activeTurnID = nil
                item.status = "running"
            }
            emit(.sessionContext(
                SessionContextSnapshot(
                    sessionID: threadID,
                    threadID: threadID,
                    status: SessionContextStatus(type: "active"),
                    updatedAt: Date()
                ),
                metadata(threadID: threadID, turnID: nil)
            ))
        default:
            backfillActiveTurnFromLiveNotification(method: notification.method, params: params)
            break
        }
    }

    private func backfillActiveTurnFromLiveNotification(
        method: String,
        params: [String: CodexAppServerJSONValue]
    ) {
        guard method != "turn/completed",
              let threadID = params["threadId"]?.stringValue,
              let turnID = params["turnId"]?.stringValue,
              !turnID.isEmpty else {
            return
        }
        guard let context = contextsBySessionID[threadID],
              context.activeTurnID != turnID || context.session.status != "running" else {
            return
        }
        _ = withUpdatedSession(threadID) { item in
            // 重连后可能先收到 delta/item completed，错过 turn/started。这里同步 runtime 自己的
            // activeTurnID 缓存，避免 UI 已允许“引导当前回复”但 steerTurn 在发送层误判 missingActiveTurn。
            item.status = "running"
            item.activeTurnID = turnID
        }
    }

    private func projectsFromCache() throws -> [AgentProject] {
        guard let config else {
            return []
        }
        return config.projects
    }

    private func withUpdatedSession(_ sessionID: SessionID, update: (inout AgentSession) -> Void) -> AgentSession? {
        guard var context = contextsBySessionID[sessionID] else {
            return nil
        }
        var session = context.session
        update(&session)
        context.session = session
        context.activeTurnID = session.activeTurnID
        context.cwd = session.dir
        contextsBySessionID[sessionID] = context
        emit(.session(session))
        return session
    }

    @discardableResult
    private func applyThreadGoal(_ goal: ThreadGoal) -> AgentSession? {
        withUpdatedSession(goal.threadID) { item in
            item.goal = goal
        }
    }

    @discardableResult
    private func clearThreadGoalLocal(threadID: SessionID) -> AgentSession? {
        withUpdatedSession(threadID) { item in
            item.goal = nil
        }
    }

    private func threadListPage(
        from result: CodexAppServerJSONValue?,
        projects: [AgentProject],
        fallbackProject: AgentProject?
    ) -> SessionsPage {
        let object = result?.objectValue ?? [:]
        let sessions = (object["data"]?.arrayValue ?? [])
            .compactMap(\.objectValue)
            .compactMap { try? agentSession(from: $0, projects: projects, fallbackProject: fallbackProject) }
        let nextCursor = object["nextCursor"]?.stringValue
        return SessionsPage(sessions: sessions, nextCursor: nextCursor, hasMore: nextCursor != nil)
    }

    private func scheduleRateLimitRefreshIfAvailable() {
        guard rateLimitRefreshTask == nil else {
            return
        }
        if let lastRateLimitRefreshAt,
           Date().timeIntervalSince(lastRateLimitRefreshAt) < 15 {
            return
        }
        // 额度读取只是列表展示增强，不能阻塞 thread/list 首屏；后台完成后用 session 事件刷新 UI。
        rateLimitRefreshTask = Task { [self] in
            let summary = await performRateLimitRefreshIfAvailable()
            finishScheduledRateLimitRefresh()
            return summary
        }
    }

    private func finishScheduledRateLimitRefresh() {
        rateLimitRefreshTask = nil
    }

    private func refreshRateLimitIfAvailable(force: Bool = false) async -> RateLimitSummary? {
        if !force, let rateLimitRefreshTask {
            return await rateLimitRefreshTask.value
        }
        if force {
            rateLimitRefreshTask?.cancel()
            rateLimitRefreshTask = nil
        }
        return await performRateLimitRefreshIfAvailable()
    }

    private func performRateLimitRefreshIfAvailable() async -> RateLimitSummary? {
        guard let config = try? await ensureConfig(),
              config.policy.allowedMethods.contains("account/rateLimits/read")
        else {
            return accountRateLimit
        }
        do {
            let result = try await sendRecoveringFromStaleInitialization(
                CodexAppServerRequestBuilder(allowlistedProjects: config.projects).accountRateLimitsRead(),
                timeout: rateLimitRequestTimeout
            )
            guard let summary = rateLimitSummary(fromPayload: result) else {
                return accountRateLimit
            }
            applyAccountRateLimit(summary)
            lastRateLimitRefreshAt = Date()
            return summary
        } catch {
            // 额度读取只是展示增强，不应拖垮会话列表或发送链路。
            return accountRateLimit
        }
    }

    private func refreshRateLimitAfterQuotaError(_ error: Error) async {
        guard CodexQuotaNotice.isQuotaError(error.localizedDescription) else {
            return
        }
        _ = await refreshRateLimitIfAvailable()
    }

    private func applyAccountRateLimit(_ summary: RateLimitSummary) {
        accountRateLimit = summary
        for sessionID in Array(contextsBySessionID.keys) {
            if let session = withUpdatedSession(sessionID, update: { item in
                item.rateLimit = summary
            }) {
                emit(.session(session))
            }
        }
    }

    private func threadObject(from result: CodexAppServerJSONValue?) -> [String: CodexAppServerJSONValue]? {
        result?["thread"]?.objectValue
    }

    private func threadGoal(from result: CodexAppServerJSONValue?) -> ThreadGoal? {
        if let object = result?["goal"]?.objectValue {
            return ThreadGoal(object: object)
        }
        guard let object = result?.objectValue else {
            return nil
        }
        return ThreadGoal(object: object)
    }

    private func agentSession(
        from thread: [String: CodexAppServerJSONValue],
        projects: [AgentProject],
        fallbackProject: AgentProject?,
        forceRunning: Bool = false
    ) throws -> AgentSession {
        guard let id = thread["id"]?.stringValue else {
            throw AgentAPIError.invalidResponse
        }
        let cwd = thread["cwd"]?.stringValue ?? fallbackProject?.path ?? ""
        let project = projectFor(cwd: cwd, projects: projects) ?? fallbackProject
        let projectID = project?.id ?? fallbackProject?.id ?? cwd
        let projectName = project?.name ?? fallbackProject?.name ?? cwd
        let status = sessionStatus(from: thread["status"], forceRunning: forceRunning)
        let preview = thread["preview"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = thread["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? preview?.split(separator: "\n").first.map(String.init)
            ?? "Thread \(id.prefix(8))"
        let cached = contextsBySessionID[id]?.session
        // thread/list 可能不带 turns，此时沿用本地 activeTurnID；但 thread/read/resume 一旦带回
        // turns，就以服务端 turns 为准。即使 turns 里没有 inProgress，也要清掉旧缓存，避免引导发到旧 turn。
        let remoteActiveTurnID = activeTurnID(from: thread)
        let activeTurnID: TurnID?
        if let remoteActiveTurnID {
            activeTurnID = remoteActiveTurnID
        } else {
            activeTurnID = cached?.activeTurnID
        }
        // 列表/历史读偶发把正在执行的 turn 读成 history。本地记着进行中的 turn（activeTurnID 非空）、
        // 或刚在时间窗内收到过该 thread 的实时通知时，才在这一瞬间保留运行态，避免侧栏角标抖动；
        // 没有活跃迹象的残留态（例如被放弃的审批等待）必须允许权威 history 把它降级，
        // 否则 stale 审批态会一直挂着清不掉。
        let shouldKeepCachedStatus = status == "history"
            && (activeTurnID != nil || hasRecentLiveSignal(sessionID: id))
        let effectiveStatus = shouldKeepCachedStatus ? (cached?.status ?? status) : status
        let goal = thread["goal"]?.objectValue.flatMap { ThreadGoal(object: $0) } ?? cached?.goal
        let rateLimit = rateLimitSummary(fromSnapshot: thread["rateLimit"]?.objectValue)
            ?? rateLimitSummary(fromSnapshot: thread["rate_limit"]?.objectValue)
            ?? cached?.rateLimit
            ?? accountRateLimit
        let context = sessionContext(
            from: thread,
            sessionID: id,
            cwd: cwd,
            status: effectiveStatus,
            statusValue: forceRunning ? nil : thread["status"],
            project: project ?? fallbackProject,
            goal: goal
        )
        return AgentSession(
            id: id,
            projectID: projectID,
            project: projectName,
            dir: cwd,
            title: title.isEmpty ? "未命名会话" : title,
            status: effectiveStatus,
            source: runtimeProvider,
            runtimeProvider: runtimeProvider,
            resumeID: id,
            createdAt: date(from: thread["createdAt"]),
            updatedAt: date(from: thread["updatedAt"]),
            preview: preview,
            activeTurnID: activeTurnID,
            lastSeq: nil,
            revision: 0,
            usage: cached?.usage,
            rateLimit: rateLimit,
            goal: goal,
            context: context
        )
    }

    private func sessionContext(
        from thread: [String: CodexAppServerJSONValue],
        sessionID: SessionID,
        cwd: String,
        status: String,
        statusValue: CodexAppServerJSONValue?,
        project: AgentProject?,
        goal: ThreadGoal?
    ) -> SessionContextSnapshot {
        let threadID = thread["id"]?.stringValue ?? sessionID
        return SessionContextSnapshot(
            sessionID: sessionID,
            threadID: threadID,
            status: contextStatus(from: statusValue, fallbackStatus: status),
            environment: SessionContextEnvironment(
                id: "local",
                kind: "local",
                label: "本地",
                cwd: cwd,
                provider: runtimeProvider == "codex" ? nonEmpty(thread["modelProvider"]?.stringValue, "openai") : nonEmpty(thread["modelProvider"]?.stringValue, "anthropic"),
                runtimeProvider: runtimeProvider
            ),
            git: gitInfo(from: thread["gitInfo"]?.objectValue),
            goal: goal,
            tasks: contextTasks(from: thread),
            sources: contextSources(from: thread, project: project),
            subagents: contextSubagents(from: thread, status: status),
            updatedAt: Date()
        )
    }

    private func projectFor(cwd: String, projects: [AgentProject]) -> AgentProject? {
        let path = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        return projects
            .filter { project in
                let projectPath = project.path.trimmingCharacters(in: .whitespacesAndNewlines)
                return path == projectPath || path.hasPrefix(projectPath + "/")
            }
            .max { lhs, rhs in
                lhs.path.split(separator: "/").count < rhs.path.split(separator: "/").count
            }
    }

    private func projectsIncludingWorkspace(_ projects: [AgentProject], workspace: AgentWorkspace) -> [AgentProject] {
        var next = projects.filter { $0.id != workspace.id && $0.path != workspace.path }
        next.append(workspace.project)
        return next
    }

    private func threadListCWD(for workspace: AgentWorkspace, projects: [AgentProject]) -> String {
        let rootProjectID = workspace.rootProjectID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rootProjectID.isEmpty,
              let rootProject = projects.first(where: { $0.id == rootProjectID }),
              let workspacePath = standardizedPath(workspace.path),
              let rootPath = standardizedPath(rootProject.path),
              path(workspacePath, isEqualToOrInside: rootPath)
        else {
            return workspace.path
        }
        // 项目内子路径打开时沿用 root project 拉历史；否则 app-server 会按子目录精确 cwd 返回空列表。
        // managed worktree / browse workspace 通常不在 rootPath 下，会保留自己的真实路径隔离历史。
        return rootProject.path
    }

    private func path(_ path: String, isEqualToOrInside rootPath: String) -> Bool {
        path == rootPath || path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
    }

    private func standardizedPath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    private func projectsIncludingSessionContext(_ projects: [AgentProject], context: CodexAppServerSessionContext) -> [AgentProject] {
        projectsIncludingWorkspace(projects, workspace: AgentWorkspace(
            id: context.session.projectID,
            name: context.session.project,
            path: context.cwd
        ))
    }

    private func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return ""
    }

    private func firstString(in object: [String: CodexAppServerJSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func rateLimitSummary(fromPayload value: CodexAppServerJSONValue?) -> RateLimitSummary? {
        guard let object = value?.objectValue else {
            return nil
        }
        if let byLimitID = object["rateLimitsByLimitId"]?.objectValue ?? object["rate_limits_by_limit_id"]?.objectValue {
            if let codex = byLimitID["codex"]?.objectValue,
               let summary = rateLimitSummary(fromSnapshot: codex) {
                return summary
            }
            for item in byLimitID.values {
                if let summary = rateLimitSummary(fromSnapshot: item.objectValue) {
                    return summary
                }
            }
        }
        if let rateLimits = object["rateLimits"]?.objectValue ?? object["rate_limits"]?.objectValue {
            return rateLimitSummary(fromSnapshot: rateLimits)
        }
        return rateLimitSummary(fromSnapshot: object)
    }

    private func rateLimitSummary(fromSnapshot snapshot: [String: CodexAppServerJSONValue]?) -> RateLimitSummary? {
        guard let snapshot else {
            return nil
        }
        let primary = snapshot["primary"]?.objectValue
        let secondary = snapshot["secondary"]?.objectValue
        let credits = snapshot["credits"]?.objectValue
        let summary = RateLimitSummary(
            limitID: firstString(in: snapshot, keys: ["limitId", "limit_id"]),
            limitName: firstString(in: snapshot, keys: ["limitName", "limit_name"]),
            planType: firstString(in: snapshot, keys: ["planType", "plan_type"]),
            reachedType: firstString(in: snapshot, keys: ["rateLimitReachedType", "reachedType", "reached_type"]),
            primaryUsedPercent: firstDouble(in: primary, keys: ["usedPercent", "used_percent"]),
            secondaryUsedPercent: firstDouble(in: secondary, keys: ["usedPercent", "used_percent"]),
            primaryResetsAt: firstInt64(in: primary, keys: ["resetsAt", "resets_at"]),
            secondaryResetsAt: firstInt64(in: secondary, keys: ["resetsAt", "resets_at"]),
            hasCredits: firstBool(in: credits, keys: ["hasCredits", "has_credits"]),
            creditsUnlimited: firstBool(in: credits, keys: ["unlimited", "credits_unlimited"]),
            creditBalance: firstString(in: credits ?? [:], keys: ["balance", "credit_balance"])
        )
        if summary.limitID == nil,
           summary.limitName == nil,
           summary.planType == nil,
           summary.reachedType == nil,
           summary.primaryUsedPercent == nil,
           summary.secondaryUsedPercent == nil,
           summary.hasCredits == nil,
           summary.creditBalance == nil {
            return nil
        }
        return summary
    }

    private func firstDouble(in object: [String: CodexAppServerJSONValue]?, keys: [String]) -> Double? {
        guard let object else {
            return nil
        }
        for key in keys {
            guard let value = object[key] else {
                continue
            }
            switch value {
            case .double(let number):
                return number
            case .int(let number):
                return Double(number)
            case .string(let raw):
                if let number = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return number
                }
            default:
                continue
            }
        }
        return nil
    }

    private func firstInt64(in object: [String: CodexAppServerJSONValue]?, keys: [String]) -> Int64? {
        guard let object else {
            return nil
        }
        for key in keys {
            guard let value = object[key] else {
                continue
            }
            switch value {
            case .int(let number):
                return number
            case .double(let number):
                return Int64(number)
            case .string(let raw):
                if let number = Int64(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return number
                }
            default:
                continue
            }
        }
        return nil
    }

    private func firstBool(in object: [String: CodexAppServerJSONValue]?, keys: [String]) -> Bool? {
        guard let object else {
            return nil
        }
        for key in keys {
            guard let value = object[key] else {
                continue
            }
            if let bool = value.boolValue {
                return bool
            }
            if let raw = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                if raw == "true" {
                    return true
                }
                if raw == "false" {
                    return false
                }
            }
        }
        return nil
    }

    private func sessionStatus(from value: CodexAppServerJSONValue?, forceRunning: Bool) -> String {
        if forceRunning {
            return "running"
        }
        guard let value else {
            return "history"
        }
        if let raw = value.stringValue {
            switch raw {
            case "notLoaded", "idle":
                return "history"
            default:
                return raw
            }
        }
        guard let object = value.objectValue else {
            return "history"
        }
        let type = object["type"]?.stringValue ?? ""
        switch type {
        case "notLoaded":
            return "history"
        case "idle":
            // thread/list 里的 idle 只表示 app-server 线程可恢复，不代表 iPad 已经附着到
            // 当前执行上下文。把历史 idle 当 running 会绕过 thread/resume，导致部分历史会话
            // 的实时通知落不到当前订阅里，只能靠手动刷新从 thread/read 补回来。
            return "history"
        case "systemError":
            return "failed"
        case "active":
            let flags = object["activeFlags"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if flags.contains("waitingOnApproval") {
                return "waiting_for_approval"
            }
            if flags.contains("waitingOnUserInput") {
                return "waiting_for_input"
            }
            return "running"
        default:
            return "history"
        }
    }

    private func statusContext(threadID: String, statusValue: CodexAppServerJSONValue) -> SessionContextSnapshot {
        SessionContextSnapshot(
            sessionID: threadID,
            threadID: threadID,
            status: contextStatus(from: statusValue, fallbackStatus: sessionStatus(from: statusValue, forceRunning: false)),
            updatedAt: Date()
        )
    }

    private func contextStatus(from value: CodexAppServerJSONValue?, fallbackStatus: String) -> SessionContextStatus {
        guard let value else {
            return SessionContextStatus(type: contextStatusType(from: fallbackStatus))
        }
        if let raw = value.stringValue {
            return SessionContextStatus(type: raw == "notLoaded" ? "notLoaded" : raw)
        }
        guard let object = value.objectValue else {
            return SessionContextStatus(type: contextStatusType(from: fallbackStatus))
        }
        let type = object["type"]?.stringValue ?? contextStatusType(from: fallbackStatus)
        let activeFlags = object["activeFlags"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return SessionContextStatus(type: type, activeFlags: activeFlags)
    }

    private func contextStatusType(from status: String) -> String {
        switch status {
        case "running", "waiting_for_approval", "waiting_for_input":
            return "active"
        case "failed":
            return "systemError"
        case "closed", "idle":
            return "idle"
        default:
            return "notLoaded"
        }
    }

    private func gitInfo(from object: [String: CodexAppServerJSONValue]?) -> SessionContextGitInfo? {
        guard let object else {
            return nil
        }
        let info = SessionContextGitInfo(
            sha: object["sha"]?.stringValue,
            branch: object["branch"]?.stringValue,
            originURL: object["originUrl"]?.stringValue ?? object["origin_url"]?.stringValue
        )
        if [info.sha, info.branch, info.originURL].allSatisfy({ ($0 ?? "").isEmpty }) {
            return nil
        }
        return info
    }

    private func contextSources(
        from thread: [String: CodexAppServerJSONValue],
        project: AgentProject?
    ) -> [SessionContextSource] {
        var sources: [SessionContextSource] = []
        if let label = sourceLabel(from: thread["source"]) {
            sources.append(SessionContextSource(id: "session_source", kind: "session", label: label, subtitle: "原始来源"))
        }
        if let threadSource = nonEmpty(thread["threadSource"]?.stringValue) {
            sources.append(SessionContextSource(id: "thread_source", kind: "thread", label: threadSource, subtitle: "线程来源"))
        }
        if let forkedFrom = nonEmpty(thread["forkedFromId"]?.stringValue) {
            sources.append(SessionContextSource(id: "forked_from", kind: "fork", label: String(forkedFrom.prefix(32)), subtitle: "Fork 来源"))
        }
        if sources.isEmpty, let project {
            sources.append(SessionContextSource(id: "project", kind: "project", label: project.name, subtitle: project.path))
        }
        return sources
    }

    private func sourceLabel(from value: CodexAppServerJSONValue?) -> String? {
        if let raw = nonEmpty(value?.stringValue) {
            return raw
        }
        guard let object = value?.objectValue else {
            return nil
        }
        if let custom = nonEmpty(object["custom"]?.stringValue) {
            return custom
        }
        if let subAgent = nonEmpty(object["subAgent"]?.stringValue) {
            return "subAgent \(subAgent)"
        }
        return nil
    }

    private func contextSubagents(
        from thread: [String: CodexAppServerJSONValue],
        status: String
    ) -> [SessionContextSubagent] {
        var subagents: [SessionContextSubagent] = []
        if let parentThreadID = nonEmpty(thread["parentThreadId"]?.stringValue) {
            subagents.append(
                SessionContextSubagent(
                    id: thread["id"]?.stringValue ?? UUID().uuidString,
                    parentThreadID: parentThreadID,
                    nickname: nonEmpty(thread["agentNickname"]?.stringValue),
                    role: nonEmpty(thread["agentRole"]?.stringValue),
                    status: status
                )
            )
        }
        guard let threadID = nonEmpty(thread["id"]?.stringValue) else {
            return subagents
        }
        let turns = thread["turns"]?.arrayValue?.compactMap(\.objectValue) ?? []
        for turn in turns.reversed() {
            let items = turn["items"]?.arrayValue?.compactMap(\.objectValue) ?? []
            for item in items.reversed() where item["type"]?.stringValue == "collabAgentToolCall" {
                let id = nonEmpty(
                    item["childThreadId"]?.stringValue,
                    item["agentThreadId"]?.stringValue,
                    item["subagentThreadId"]?.stringValue,
                    item["threadId"]?.stringValue,
                    item["id"]?.stringValue
                ) ?? UUID().uuidString
                subagents.append(
                    SessionContextSubagent(
                        id: id,
                        parentThreadID: threadID,
                        nickname: nonEmpty(item["agentNickname"]?.stringValue, item["nickname"]?.stringValue, item["tool"]?.stringValue),
                        role: nonEmpty(item["agentRole"]?.stringValue, item["role"]?.stringValue),
                        status: nonEmpty(item["status"]?.stringValue, turn["status"]?.stringValue, status)
                    )
                )
                if subagents.count >= 8 {
                    return subagents
                }
            }
        }
        return subagents
    }

    private func contextTasks(from thread: [String: CodexAppServerJSONValue]) -> [SessionContextTask] {
        let turns = thread["turns"]?.arrayValue?.compactMap(\.objectValue) ?? []
        var tasks: [SessionContextTask] = []
        for turn in turns.reversed() {
            let items = turn["items"]?.arrayValue?.compactMap(\.objectValue) ?? []
            for item in items.reversed() {
                guard let task = contextTask(from: item, turn: turn) else {
                    continue
                }
                tasks.append(task)
                if tasks.count >= 8 {
                    return tasks
                }
            }
        }
        return tasks
    }

    private func contextTask(
        from item: [String: CodexAppServerJSONValue],
        turn: [String: CodexAppServerJSONValue]
    ) -> SessionContextTask? {
        let id = item["id"]?.stringValue ?? turn["id"]?.stringValue ?? UUID().uuidString
        let status = item["status"]?.stringValue ?? turn["status"]?.stringValue
        switch item["type"]?.stringValue {
        case "commandExecution":
            let title = nonEmpty(item["command"]?.stringValue, item["processId"]?.stringValue, "命令执行") ?? "命令执行"
            let subtitle = nonEmpty(item["cwd"]?.stringValue, commandActionSummary(from: item["commandActions"]?.arrayValue))
            return SessionContextTask(id: id, kind: "command", title: String(title.prefix(80)), subtitle: subtitle, status: status)
        case "fileChange":
            let changes = item["changes"]?.arrayValue?.compactMap(\.objectValue) ?? []
            let title = changes.isEmpty ? "文件变更" : "文件变更 x\(changes.count)"
            return SessionContextTask(id: id, kind: "file_change", title: title, subtitle: fileChangeSummary(from: changes), status: status)
        case "mcpToolCall":
            let title = nonEmpty(item["tool"]?.stringValue, item["name"]?.stringValue, "工具调用") ?? "工具调用"
            let subtitle = nonEmpty(item["server"]?.stringValue, item["namespace"]?.stringValue, item["pluginId"]?.stringValue)
            return SessionContextTask(id: id, kind: "mcp_tool", title: title, subtitle: subtitle, status: status)
        case "dynamicToolCall":
            let title = nonEmpty(item["tool"]?.stringValue, item["name"]?.stringValue, "动态工具") ?? "动态工具"
            let subtitle = nonEmpty(item["pluginId"]?.stringValue, item["namespace"]?.stringValue, "dynamic tool")
            return SessionContextTask(id: id, kind: "dynamic_tool", title: title, subtitle: subtitle, status: status)
        case "collabAgentToolCall":
            let title = nonEmpty(item["agentNickname"]?.stringValue, item["nickname"]?.stringValue, item["tool"]?.stringValue, "子 Agent") ?? "子 Agent"
            let subtitle = nonEmpty(item["agentRole"]?.stringValue, item["role"]?.stringValue)
            return SessionContextTask(id: id, kind: "subagent", title: title, subtitle: subtitle, status: status)
        case "webSearch":
            let query = nonEmpty(item["query"]?.stringValue, item["action"]?.stringValue)
            let title = query.map { "网络搜索：\($0)" } ?? "网络搜索"
            return SessionContextTask(id: id, kind: "web_search", title: title, subtitle: nil, status: status)
        default:
            return nil
        }
    }

    private func commandActionSummary(from actions: [CodexAppServerJSONValue]?) -> String? {
        for action in actions?.compactMap(\.objectValue) ?? [] {
            if let value = nonEmpty(action["name"]?.stringValue, action["path"]?.stringValue) {
                return value
            }
            if let query = nonEmpty(action["query"]?.stringValue) {
                return query
            }
        }
        return nil
    }

    private func fileChangeSummary(from changes: [[String: CodexAppServerJSONValue]]) -> String? {
        guard !changes.isEmpty else {
            return nil
        }
        var parts = changes.prefix(3).compactMap { change in
            nonEmpty(change["path"]?.stringValue, change["kind"]?.stringValue)
        }
        if changes.count > parts.count {
            parts.append("+\(changes.count - parts.count)")
        }
        return parts.joined(separator: ", ")
    }

    private func activeTurnID(from thread: [String: CodexAppServerJSONValue]) -> TurnID?? {
        guard let turns = thread["turns"]?.arrayValue?.compactMap(\.objectValue) else {
            return nil
        }
        let activeTurnID = turns.last { turn in
            turn["status"]?.stringValue == "inProgress"
        }?["id"]?.stringValue
        return .some(activeTurnID)
    }

    private func historyMessages(
        from thread: [String: CodexAppServerJSONValue],
        sessionID: SessionID,
        snapshotReadAt: Date
    ) -> [CodexHistoryMessage] {
        let turns = thread["turns"]?.arrayValue?.compactMap(\.objectValue) ?? []
        return historyMessages(
            fromTurns: turns,
            sessionID: sessionID,
            threadCreatedAt: firstDate(in: thread, keys: ["createdAt", "created_at"]),
            threadUpdatedAt: firstDate(in: thread, keys: ["updatedAt", "updated_at"]),
            threadIsActive: isActiveHistoryThread(thread),
            snapshotReadAt: snapshotReadAt
        )
    }

    private func historyMessages(
        fromTurns turns: [[String: CodexAppServerJSONValue]],
        sessionID: SessionID,
        threadCreatedAt: Date? = nil,
        threadUpdatedAt: Date? = nil,
        threadIsActive: Bool = false,
        snapshotReadAt: Date
    ) -> [CodexHistoryMessage] {
        var messages: [CodexHistoryMessage] = []
        messages.reserveCapacity(turns.reduce(0) { count, turn in
            count + (turn["items"]?.arrayValue?.count ?? 0)
        })
        var lastResolvedAt = threadUpdatedAt ?? threadCreatedAt

        for (turnIndex, turn) in turns.enumerated() {
            let turnID = turn["id"]?.stringValue
            let startedAt = firstDate(in: turn, keys: ["startedAt", "started_at", "createdAt", "created_at", "timestamp"])
            let completedAt = firstDate(in: turn, keys: ["completedAt", "completed_at", "updatedAt", "updated_at", "finishedAt", "finished_at"])
            let turnIsInProgress = isInProgressHistoryTurn(
                turn,
                isLastTurn: turnIndex == turns.index(before: turns.endIndex),
                threadIsActive: threadIsActive,
                completedAt: completedAt
            )
            let items = turn["items"]?.arrayValue?.compactMap(\.objectValue) ?? []
            var hasVisibleUserMessageInTurn = false
            for (itemIndex, item) in items.enumerated() {
                guard var message = historyMessage(
                    from: item,
                    sessionID: sessionID,
                    turnID: turnID,
                    timelineOrdinal: historyTimelineOrdinal(turnIndex: turnIndex, itemIndex: itemIndex),
                    isInjectedUserMessage: hasVisibleUserMessageInTurn,
                    startedAt: startedAt,
                    completedAt: completedAt,
                    estimatedAt: estimatedHistoryItemDate(startedAt: startedAt, completedAt: completedAt, itemIndex: itemIndex, itemCount: items.count),
                    turnIsInProgress: turnIsInProgress,
                    snapshotReadAt: snapshotReadAt
                ) else {
                    continue
                }
                if message.role == "user" {
                    hasVisibleUserMessageInTurn = true
                }
                if message.createdAt == nil {
                    // 历史消息缺少 item/turn 级时间时不能兜底成当前加载时间；用上游 thread
                    // 时间或前一条已解析时间维持稳定排序，同时显式标记为估算。
                    let fallback = lastResolvedAt ?? threadUpdatedAt ?? threadCreatedAt ?? Self.stableHistoryFallbackDate(index: messages.count)
                    message = message.withTimestampFallback(createdAt: fallback)
                }
                if let resolvedAt = message.updatedAt ?? message.createdAt {
                    lastResolvedAt = resolvedAt
                }
                messages.append(message)
            }
        }
        return messages
    }

    private func historyMessage(
        from item: [String: CodexAppServerJSONValue],
        sessionID: SessionID,
        turnID: TurnID?,
        timelineOrdinal: Int64,
        isInjectedUserMessage: Bool,
        startedAt: Date?,
        completedAt: Date?,
        estimatedAt: Date?,
        turnIsInProgress: Bool,
        snapshotReadAt: Date
    ) -> CodexHistoryMessage? {
        let type = item["type"]?.stringValue
        let itemID = item["id"]?.stringValue ?? UUID().uuidString
        let messageID = appServerHistoryMessageID(turnID: turnID, itemID: itemID)
        let itemCreatedAt = firstDate(in: item, keys: ["createdAt", "created_at", "startedAt", "started_at", "timestamp"])
        let itemCompletedAt = firstDate(in: item, keys: ["completedAt", "completed_at", "updatedAt", "updated_at", "finishedAt", "finished_at", "timestamp"])
        let processCreatedAt = itemCreatedAt ?? estimatedAt ?? startedAt ?? itemCompletedAt ?? completedAt
        // running thread/read 快照常缺 item 级 completedAt，但内容已是最新输出；
        // 用读取时间写 updatedAt，让观察模式显示最近活动，同时不改 createdAt 的排序语义。
        let liveSnapshotUpdatedAt = turnIsInProgress && itemCompletedAt == nil && !isTerminalHistoryStatus(item["status"]) ? snapshotReadAt : nil
        let processTimestampIsFallback = itemCreatedAt == nil && itemCompletedAt == nil && estimatedAt != nil
        switch type {
        case "userMessage":
            let inputs = userMessageInputs(from: item)
            let text = userMessageText(from: inputs).trimmingCharacters(in: .whitespacesAndNewlines)
            let hasImageInput = containsImageInput(inputs)
            guard !text.isEmpty || hasImageInput else {
                return nil
            }
            guard text.isEmpty || isVisibleUserHistoryMessage(text) else {
                return nil
            }
            let turnPayload = hasImageInput ? CodexAppServerTurnPayload(input: inputs) : nil
            let content = text.isEmpty ? (turnPayload?.previewText ?? "") : text
            guard !content.isEmpty else {
                return nil
            }
            let createdAt = itemCreatedAt ?? estimatedAt ?? startedAt ?? itemCompletedAt ?? completedAt
            return CodexHistoryMessage(
                id: messageID,
                role: "user",
                content: content,
                turnPayload: turnPayload,
                createdAt: createdAt,
                clientMessageID: item["clientId"]?.stringValue,
                turnID: turnID,
                itemID: itemID,
                timelineOrdinal: timelineOrdinal,
                userDelivery: isInjectedUserMessage ? .injected : nil,
                isTimestampFallback: itemCreatedAt == nil && itemCompletedAt == nil && estimatedAt != nil
            )
        case "agentMessage":
            let text = item["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                return nil
            }
            if item["phase"]?.stringValue == "commentary" {
                return CodexHistoryMessage(id: messageID, role: "system", kind: .reasoningSummary, content: text, createdAt: processCreatedAt, updatedAt: liveSnapshotUpdatedAt, turnID: turnID, itemID: itemID, timelineOrdinal: timelineOrdinal, isTimestampFallback: processTimestampIsFallback)
            }
            let completed = itemCompletedAt ?? completedAt
            return CodexHistoryMessage(id: messageID, role: "assistant", content: text, createdAt: completed ?? itemCreatedAt ?? estimatedAt ?? startedAt, updatedAt: completed ?? liveSnapshotUpdatedAt, turnID: turnID, itemID: itemID, timelineOrdinal: timelineOrdinal, isTimestampFallback: completed == nil && itemCreatedAt == nil && estimatedAt != nil)
        case "plan":
            guard let payload = ConversationActivityPayload(item: item) else {
                return nil
            }
            let content = payload.summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                return nil
            }
            return CodexHistoryMessage(id: messageID, role: "system", kind: payload.messageKind, content: content, activityPayload: payload, createdAt: processCreatedAt, updatedAt: liveSnapshotUpdatedAt, turnID: turnID, itemID: itemID, timelineOrdinal: timelineOrdinal, isTimestampFallback: processTimestampIsFallback)
        case "reasoning":
            guard let payload = ConversationActivityPayload(item: item) else {
                return nil
            }
            let content = payload.summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                return nil
            }
            return CodexHistoryMessage(id: messageID, role: "system", kind: payload.messageKind, content: content, activityPayload: payload, createdAt: processCreatedAt, updatedAt: liveSnapshotUpdatedAt, turnID: turnID, itemID: itemID, timelineOrdinal: timelineOrdinal, isTimestampFallback: processTimestampIsFallback)
        case "commandExecution":
            guard let payload = ConversationActivityPayload(item: item) else {
                return nil
            }
            return CodexHistoryMessage(id: messageID, role: "system", kind: payload.messageKind, content: payload.summaryText, activityPayload: payload, createdAt: processCreatedAt, updatedAt: liveSnapshotUpdatedAt, turnID: turnID, itemID: itemID, timelineOrdinal: timelineOrdinal, isTimestampFallback: processTimestampIsFallback)
        case "fileChange":
            guard let payload = ConversationActivityPayload(item: item) else {
                return nil
            }
            return CodexHistoryMessage(id: messageID, role: "system", kind: payload.messageKind, content: payload.summaryText, activityPayload: payload, createdAt: processCreatedAt, updatedAt: liveSnapshotUpdatedAt, turnID: turnID, itemID: itemID, timelineOrdinal: timelineOrdinal, isTimestampFallback: processTimestampIsFallback)
        case "mcpToolCall", "dynamicToolCall", "collabAgentToolCall", "webSearch":
            guard let payload = ConversationActivityPayload(item: item) else {
                return nil
            }
            return CodexHistoryMessage(id: messageID, role: "system", kind: payload.messageKind, content: payload.summaryText, activityPayload: payload, createdAt: processCreatedAt, updatedAt: liveSnapshotUpdatedAt, turnID: turnID, itemID: itemID, timelineOrdinal: timelineOrdinal, isTimestampFallback: processTimestampIsFallback)
        default:
            return nil
        }
    }

    private func historyTimelineOrdinal(turnIndex: Int, itemIndex: Int) -> Int64 {
        Int64(turnIndex) * 1_000_000 + Int64(itemIndex)
    }

    private func isActiveHistoryThread(_ thread: [String: CodexAppServerJSONValue]) -> Bool {
        isActiveHistoryStatus(thread["status"])
    }

    private func isInProgressHistoryTurn(
        _ turn: [String: CodexAppServerJSONValue],
        isLastTurn: Bool,
        threadIsActive: Bool,
        completedAt: Date?
    ) -> Bool {
        if isActiveHistoryStatus(turn["status"]) {
            return true
        }
        guard completedAt == nil else {
            return false
        }
        // thread/read 的 running turn 可能只在 thread.status 标 active，turn 自己不带 status；
        // 只有最后一个未完成 turn 继承线程活跃态，避免老 turn 的缺失时间被误标成当前读取时间。
        return threadIsActive && isLastTurn
    }

    private func isActiveHistoryStatus(_ value: CodexAppServerJSONValue?) -> Bool {
        let raw = value?.stringValue
            ?? value?.objectValue?["type"]?.stringValue
            ?? value?.objectValue?["status"]?.stringValue
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "active", "running", "inprogress", "in_progress", "waiting_for_approval", "waiting_for_input":
            return true
        default:
            return false
        }
    }

    private func isTerminalHistoryStatus(_ value: CodexAppServerJSONValue?) -> Bool {
        let raw = value?.stringValue
            ?? value?.objectValue?["type"]?.stringValue
            ?? value?.objectValue?["status"]?.stringValue
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "completed", "complete", "succeeded", "success", "failed", "failure", "cancelled", "canceled":
            return true
        default:
            return false
        }
    }

    private func estimatedHistoryItemDate(startedAt: Date?, completedAt: Date?, itemIndex: Int, itemCount: Int) -> Date? {
        guard let startedAt else {
            return completedAt
        }
        guard let completedAt, completedAt > startedAt, itemCount > 1 else {
            return startedAt.addingTimeInterval(Double(itemIndex) * 0.001)
        }
        let progress = Double(itemIndex) / Double(max(1, itemCount - 1))
        return startedAt.addingTimeInterval(completedAt.timeIntervalSince(startedAt) * progress)
    }

    private func isVisibleUserHistoryMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        let hiddenPrefixes = [
            "<subagent_notification>",
            "<turn_aborted>",
            "<environment_context>",
            "<codex_internal_context>"
        ]
        return !hiddenPrefixes.contains { trimmed.hasPrefix($0) }
    }

    private func appServerHistoryMessageID(turnID: TurnID?, itemID: AgentItemID) -> MessageID {
        guard let turnID, !turnID.isEmpty else {
            return itemID
        }
        return "appserver:\(turnID):\(itemID)"
    }

    private func userMessageInputs(from item: [String: CodexAppServerJSONValue]) -> [CodexAppServerUserInput] {
        let content = item["content"]?.arrayValue ?? []
        return content.compactMap { value in
            guard let object = value.objectValue,
                  let type = object["type"]?.stringValue
            else {
                return nil
            }
            switch type {
            case "text":
                guard let text = object["text"]?.stringValue else {
                    return nil
                }
                return .text(text, textElements: object["text_elements"]?.arrayValue ?? [])
            case "image":
                guard let url = object["url"]?.stringValue else {
                    return nil
                }
                return .image(url: url, detail: userMessageImageDetail(from: object))
            case "localImage", "local_image":
                guard let path = object["path"]?.stringValue else {
                    return nil
                }
                return .localImage(path: path, detail: userMessageImageDetail(from: object))
            case "skill":
                guard let name = object["name"]?.stringValue,
                      let path = object["path"]?.stringValue
                else {
                    return nil
                }
                return .skill(name: name, path: path)
            case "mention":
                guard let name = object["name"]?.stringValue,
                      let path = object["path"]?.stringValue
                else {
                    return nil
                }
                return .mention(name: name, path: path)
            default:
                return nil
            }
        }
    }

    private func userMessageText(from inputs: [CodexAppServerUserInput]) -> String {
        inputs.compactMap { input in
            if case .text(let text, _) = input {
                return text
            }
            return nil
        }
        .joined(separator: "\n")
    }

    private func containsImageInput(_ inputs: [CodexAppServerUserInput]) -> Bool {
        inputs.contains { input in
            switch input {
            case .image, .localImage:
                return true
            case .text, .skill, .mention:
                return false
            }
        }
    }

    private func userMessageImageDetail(from object: [String: CodexAppServerJSONValue]) -> CodexAppServerImageDetail? {
        guard let raw = object["detail"]?.stringValue else {
            return nil
        }
        return CodexAppServerImageDetail(rawValue: raw)
    }

    private func approvalID(for request: CodexAppServerServerRequest) -> String? {
        let params = request.params?.objectValue ?? [:]
        return params["approvalId"]?.stringValue
            ?? params["itemId"]?.stringValue
            ?? params["item_id"]?.stringValue
            ?? params["callId"]?.stringValue
            ?? request.id.description
    }

    private func userInputRequestID(for request: CodexAppServerServerRequest) -> String? {
        let params = request.params?.objectValue ?? [:]
        return params["itemId"]?.stringValue
            ?? params["item_id"]?.stringValue
            ?? params["requestId"]?.stringValue
            ?? params["request_id"]?.stringValue
            ?? request.id.description
    }

    private func rememberPendingApprovalRequest(_ request: CodexAppServerServerRequest) {
        guard isApprovalLikeServerRequest(request.method) else {
            return
        }
        for key in pendingApprovalStorageKeys(for: request) {
            pendingApprovalRequestsByID[key] = request
        }
    }

    private func removePendingApprovalRequest(_ request: CodexAppServerServerRequest) {
        for key in pendingApprovalStorageKeys(for: request) {
            pendingApprovalRequestsByID.removeValue(forKey: key)
        }
    }

    private func rememberPendingUserInputRequest(_ request: CodexAppServerServerRequest) {
        guard isUserInputServerRequest(request.method) else {
            return
        }
        for key in pendingUserInputStorageKeys(for: request) {
            pendingUserInputRequestsByID[key] = request
        }
    }

    private func removePendingUserInputRequest(_ request: CodexAppServerServerRequest) {
        for key in pendingUserInputStorageKeys(for: request) {
            pendingUserInputRequestsByID.removeValue(forKey: key)
        }
    }

    private func clearResolvedServerRequest(from notification: CodexAppServerNotification) -> CodexAppServerResolvedServerRequests {
        guard notification.method == "serverRequest/resolved" else {
            return CodexAppServerResolvedServerRequests()
        }
        let params = notification.params?.objectValue ?? [:]
        let sessionID = approvalSessionID(from: params)
        let ids = uniqueStrings([
            params["requestId"]?.stringValue,
            params["request_id"]?.stringValue,
            params["id"]?.stringValue,
            params["approvalId"]?.stringValue,
            params["itemId"]?.stringValue,
            params["item_id"]?.stringValue
        ].compactMap { $0 })

        var resolved = CodexAppServerResolvedServerRequests()
        for id in ids {
            for key in pendingApprovalLookupKeys(sessionID: sessionID, approvalID: id) {
                if let request = pendingApprovalRequestsByID.removeValue(forKey: key) {
                    if let affected = approvalSessionID(for: request), !resolved.approvalSessionIDs.contains(affected) {
                        resolved.approvalSessionIDs.append(affected)
                    }
                    removePendingApprovalRequest(request)
                }
            }
            for key in pendingUserInputLookupKeys(sessionID: sessionID, requestID: id) {
                if let request = pendingUserInputRequestsByID.removeValue(forKey: key) {
                    if let affected = approvalSessionID(for: request), !resolved.userInputSessionIDs.contains(affected) {
                        resolved.userInputSessionIDs.append(affected)
                    }
                    removePendingUserInputRequest(request)
                }
            }
        }
        if let sessionID,
           !resolved.approvalSessionIDs.contains(sessionID),
           !resolved.userInputSessionIDs.contains(sessionID) {
            resolved.approvalSessionIDs.append(sessionID)
        }
        return resolved
    }

    private func clearAllPendingServerRequests() -> CodexAppServerResolvedServerRequests {
        let approvalSessionIDs = uniqueStrings(pendingApprovalRequestsByID.values.compactMap { request in
            approvalSessionID(for: request)
        })
        let userInputSessionIDs = uniqueStrings(pendingUserInputRequestsByID.values.compactMap { request in
            approvalSessionID(for: request)
        })
        pendingApprovalRequestsByID.removeAll(keepingCapacity: false)
        pendingUserInputRequestsByID.removeAll(keepingCapacity: false)
        return CodexAppServerResolvedServerRequests(approvalSessionIDs: approvalSessionIDs, userInputSessionIDs: userInputSessionIDs)
    }

    private func emitApprovalResolved(sessionID: SessionID) {
        emit(.approvalResolved(AgentEventMetadata(
            seq: nil,
            sessionID: sessionID,
            turnID: nil,
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: Date()
        )))
    }

    private func emitUserInputResolved(sessionID: SessionID, skipped: Bool) {
        emit(.userInputResolved(AgentEventMetadata(
            seq: nil,
            sessionID: sessionID,
            turnID: nil,
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: Date()
        ), skipped: skipped))
    }

    private func pendingApprovalStorageKeys(for request: CodexAppServerServerRequest) -> [String] {
        let sessionID = approvalSessionID(for: request)
        let ids = uniqueStrings([approvalID(for: request), request.id.description].compactMap { $0 })
        return ids.flatMap { id in
            pendingApprovalLookupKeys(sessionID: sessionID, approvalID: id)
        }
    }

    private func pendingApprovalLookupKeys(sessionID: SessionID?, approvalID: String) -> [String] {
        uniqueStrings([
            pendingApprovalScopedKey(sessionID: sessionID, approvalID: approvalID),
            approvalID
        ].compactMap { $0 })
    }

    private func pendingApprovalScopedKey(sessionID: SessionID?, approvalID: String) -> String? {
        guard let sessionID, !sessionID.isEmpty else {
            return nil
        }
        return "\(sessionID)#\(approvalID)"
    }

    private func pendingUserInputStorageKeys(for request: CodexAppServerServerRequest) -> [String] {
        let sessionID = approvalSessionID(for: request)
        let ids = uniqueStrings([userInputRequestID(for: request), request.id.description].compactMap { $0 })
        return ids.flatMap { id in
            pendingUserInputLookupKeys(sessionID: sessionID, requestID: id)
        }
    }

    private func pendingUserInputLookupKeys(sessionID: SessionID?, requestID: String) -> [String] {
        uniqueStrings([
            pendingUserInputScopedKey(sessionID: sessionID, requestID: requestID),
            requestID
        ].compactMap { $0 })
    }

    private func pendingUserInputScopedKey(sessionID: SessionID?, requestID: String) -> String? {
        guard let sessionID, !sessionID.isEmpty else {
            return nil
        }
        return "\(sessionID)#\(requestID)"
    }

    private func approvalSessionID(for request: CodexAppServerServerRequest) -> SessionID? {
        approvalSessionID(from: request.params?.objectValue ?? [:])
    }

    private func approvalTurnID(for request: CodexAppServerServerRequest) -> TurnID? {
        let params = request.params?.objectValue ?? [:]
        return params["turnId"]?.stringValue
            ?? params["turnID"]?.stringValue
            ?? params["turn_id"]?.stringValue
    }

    private func approvalSessionID(from params: [String: CodexAppServerJSONValue]) -> SessionID? {
        params["threadId"]?.stringValue
            ?? params["conversationId"]?.stringValue
            ?? params["sessionId"]?.stringValue
            ?? params["session_id"]?.stringValue
    }

    private func isApprovalLikeServerRequest(_ method: String) -> Bool {
        let lower = method.lowercased()
        return lower.contains("approval")
    }

    private func isUserInputServerRequest(_ method: String) -> Bool {
        method == "item/tool/requestUserInput"
    }

    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private func approvalResponse(
        method: String,
        params: [String: CodexAppServerJSONValue],
        decision: String
    ) -> CodexAppServerJSONValue {
        if method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" {
            return .object(["decision": .string(decision)])
        }
        if method == "item/permissions/requestApproval" {
            return .object([
                // iPad 端只确认继续/拒绝当前请求，不授予 app-server 额外 permission 范围。
                "permissions": .object([:]),
                "scope": .string("turn"),
                "strictAutoReview": .bool(true)
            ])
        }
        if method == "mcpServer/elicitation/request" {
            return .object([
                "action": .string(decision == "accept" ? "accept" : decision == "cancel" ? "cancel" : "decline"),
                "content": .null,
                "_meta": .null
            ])
        }
        return .object(["decision": .string(decision)])
    }

    private func userInputResponse(answers: [String: [String]]) -> CodexAppServerJSONValue {
        .object([
            "answers": .object(answers.mapValues { values in
                .object([
                    "answers": .array(values.map { .string($0) })
                ])
            })
        ])
    }

    private func normalizeApprovalDecision(_ decision: String) -> String {
        switch decision.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "accept", "approve", "approved", "yes":
            return "accept"
        case "acceptforsession", "accept_for_session":
            return "acceptForSession"
        case "cancel":
            return "cancel"
        default:
            return "decline"
        }
    }

    private func metadata(threadID: String, turnID: String?) -> AgentEventMetadata {
        AgentEventMetadata(
            seq: nil,
            sessionID: threadID,
            turnID: turnID,
            itemID: nil,
            messageID: nil,
            clientMessageID: nil,
            revision: nil,
            createdAt: nil
        )
    }

    private func date(from value: CodexAppServerJSONValue?) -> Date? {
        guard let value else {
            return nil
        }
        switch value {
        case .int(let int):
            return Self.date(fromNumericTimestamp: Double(int))
        case .double(let double):
            return Self.date(fromNumericTimestamp: double)
        case .string(let raw):
            return Self.date(from: raw)
        default:
            return nil
        }
    }

    private func firstDate(in object: [String: CodexAppServerJSONValue], keys: [String]) -> Date? {
        for key in keys {
            if let parsed = date(from: object[key]) {
                return parsed
            }
        }
        return nil
    }

    private static func date(from text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Double(trimmed) {
            return date(fromNumericTimestamp: number)
        }
        // app-server 历史在不同版本里可能返回 ISO8601 字符串；解析失败不能兜底成当前时间。
        return iso8601Fractional.date(from: trimmed) ?? iso8601.date(from: trimmed)
    }

    private static func date(fromNumericTimestamp value: Double) -> Date? {
        guard value.isFinite, value > 0 else {
            return nil
        }
        // app-server / JSON 桥接历史上出现过秒和毫秒两种数字形态，按数量级兼容。
        let seconds = value > 10_000_000_000 ? value / 1_000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    private static func stableHistoryFallbackDate(index: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(max(0, index)) / 1_000)
    }

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private func nonEmpty(_ values: String?...) -> String? {
        for value in values {
            let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty {
                return text
            }
        }
        return nil
    }
}

final class CodexAppServerSessionAPIClient: SessionStoreAPIClient {
    private let runtime: CodexAppServerSessionRuntime

    init(runtime: CodexAppServerSessionRuntime) {
        self.runtime = runtime
    }

    func projects() async throws -> [AgentProject] {
        try await runtime.projects()
    }

    func modelOptions() async throws -> [CodexAppServerModelOption] {
        try await runtime.modelOptions()
    }

    func capabilities(path: String?) async throws -> CapabilityListResponse {
        try await runtime.capabilities(path: path)
    }

    func resolveWorkspace(path: String) async throws -> AgentWorkspace {
        try await runtime.resolveWorkspace(path: path)
    }

    func createWorktree(path: String, name: String?, base: String?, branch: String?) async throws -> WorktreeCreateResponse {
        try await runtime.createWorktree(path: path, name: name, base: base, branch: branch)
    }

    func worktreeBranches(path: String) async throws -> WorktreeBranchListResponse {
        try await runtime.worktreeBranches(path: path)
    }

    func listWorktrees() async throws -> [WorktreeListItem] {
        try await runtime.listWorktrees()
    }

    func deleteWorktree(path: String, force: Bool) async throws -> WorktreeDeleteResponse {
        try await runtime.deleteWorktree(path: path, force: force)
    }

    func pruneMissingWorktrees() async throws -> WorktreePruneResponse {
        try await runtime.pruneMissingWorktrees()
    }

    func listDirectories(path: String) async throws -> DirectoryListResponse {
        try await runtime.listDirectories(path: path)
    }

    func readFile(path: String) async throws -> FileReadResponse {
        try await runtime.readFile(path: path)
    }

    func readHistoryMedia(id: String) async throws -> FileReadResponse {
        try await runtime.readHistoryMedia(id: id)
    }

    func commandActions(path: String) async throws -> [AgentCommandAction] {
        try await runtime.commandActions(path: path)
    }

    func runCommandAction(path: String, id: String, confirmed: Bool) async throws -> CommandActionRunResponse {
        try await runtime.runCommandAction(path: path, id: id, confirmed: confirmed)
    }

    func gitStatus(path: String) async throws -> GitStatusResponse {
        try await runtime.gitStatus(path: path)
    }

    func gitAction(path: String, action: GitActionKind, files: [String]) async throws -> GitStatusResponse {
        try await runtime.gitAction(path: path, action: action, files: files)
    }

    func gitPatchAction(path: String, action: GitActionKind, patch: String) async throws -> GitStatusResponse {
        try await runtime.gitPatchAction(path: path, action: action, patch: patch)
    }

    func gitCommit(path: String, message: String) async throws -> GitStatusResponse {
        try await runtime.gitCommit(path: path, message: message)
    }

    func gitPush(path: String, remote: String?) async throws -> GitPushResponse {
        try await runtime.gitPush(path: path, remote: remote)
    }

    func gitCreatePullRequest(path: String, title: String, body: String, draft: Bool) async throws -> GitPullRequestResponse {
        try await runtime.gitCreatePullRequest(path: path, title: title, body: body, draft: draft)
    }

    func gitPullRequestStatus(path: String) async throws -> GitPullRequestStatusResponse {
        try await runtime.gitPullRequestStatus(path: path)
    }

    func transcribeVoice(filename: String, contentType: String, audioData: Data, language: String?, prompt: String?) async throws -> VoiceTranscriptionResponse {
        try await runtime.transcribeVoice(
            filename: filename,
            contentType: contentType,
            audioData: audioData,
            language: language,
            prompt: prompt
        )
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        try await sessionsPage(projectID: projectID, cursor: cursor, limit: limit).sessions
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        try await runtime.sessionsPage(projectID: projectID, cursor: cursor, limit: limit)
    }

    func sessionsPage(workspace: AgentWorkspace, cursor: String?, limit: Int?) async throws -> SessionsPage {
        try await runtime.sessionsPage(workspace: workspace, cursor: cursor, limit: limit)
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        try await runtime.session(id: id, afterSeq: afterSeq)
    }

    func threadGoal(threadID: String) async throws -> ThreadGoal? {
        try await runtime.threadGoal(threadID: threadID)
    }

    func setThreadGoal(threadID: String, objective: String?, status: ThreadGoalStatus?, tokenBudget: Int64?) async throws -> ThreadGoal {
        try await runtime.setThreadGoal(threadID: threadID, objective: objective, status: status, tokenBudget: tokenBudget)
    }

    func clearThreadGoal(threadID: String) async throws {
        try await runtime.clearThreadGoal(threadID: threadID)
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        try await runtime.createSession(payload)
    }

    func stopSession(id: String) async throws {
        try await runtime.stopSession(id: id)
    }

    func setSessionArchived(id: String, archived: Bool) async throws {
        try await runtime.setSessionArchived(id: id, archived: archived)
    }

    func forkSession(threadID: String, workspace: AgentWorkspace) async throws -> AgentSession {
        try await runtime.forkSession(threadID: threadID, workspace: workspace)
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        try await messagesPage(sessionID: sessionID, before: before, limit: limit).messages
    }

    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage {
        try await messagesPage(sessionID: sessionID, before: before, limit: limit, loadMode: .full)
    }

    func messagesPage(
        sessionID: String,
        before: String?,
        limit: Int?,
        loadMode: HistoryMessagesPage.LoadMode
    ) async throws -> HistoryMessagesPage {
        try await runtime.messagesPage(sessionID: sessionID, before: before, limit: limit, loadMode: loadMode)
    }
}

final class AppServerRuntimeRouteStore {
    private var lock = NSLock()
    private var runtimeBySessionID: [SessionID: String] = [:]

    func remember(_ session: AgentSession) {
        remember(session.runtimeProvider ?? session.source, for: session.id)
    }

    func remember(_ sessions: [AgentSession]) {
        for session in sessions {
            remember(session)
        }
    }

    func remember(_ runtimeProvider: String?, for sessionID: SessionID) {
        let runtime = CodexAppServerSessionRuntime.normalizedRuntimeProvider(runtimeProvider)
        lock.lock()
        runtimeBySessionID[sessionID] = runtime.isEmpty ? "codex" : runtime
        lock.unlock()
    }

    func runtimeProvider(for sessionID: SessionID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return runtimeBySessionID[sessionID]
    }

    func remove(sessionID: SessionID) {
        lock.lock()
        runtimeBySessionID.removeValue(forKey: sessionID)
        lock.unlock()
    }
}

final class AppServerRuntimeBundle {
    let codex: CodexAppServerSessionRuntime
    let claude: CodexAppServerSessionRuntime
    let routes = AppServerRuntimeRouteStore()

    init(endpoint: String, token: String) {
        codex = CodexAppServerSessionRuntime(endpoint: endpoint, token: token, runtimeProvider: "codex")
        claude = CodexAppServerSessionRuntime(endpoint: endpoint, token: token, runtimeProvider: "claude")
    }

    init(codexRuntime: CodexAppServerSessionRuntime, claudeRuntime: CodexAppServerSessionRuntime) {
        codex = codexRuntime
        claude = claudeRuntime
    }

    func runtime(for provider: String?) -> CodexAppServerSessionRuntime {
        CodexAppServerSessionRuntime.normalizedRuntimeProvider(provider) == "claude" ? claude : codex
    }

    func runtime(forSessionID sessionID: SessionID) -> CodexAppServerSessionRuntime {
        runtime(for: routes.runtimeProvider(for: sessionID))
    }
}

private struct MultiRuntimeSessionsCursor: Codable {
    var codex: String?
    var claude: String?
    var codexBuffer: [AgentSession] = []
    var claudeBuffer: [AgentSession] = []

    static func decode(_ raw: String?) -> MultiRuntimeSessionsCursor {
        guard let raw,
              let data = Data(base64Encoded: raw),
              let decoded = try? Self.decoder.decode(MultiRuntimeSessionsCursor.self, from: data) else {
            return MultiRuntimeSessionsCursor(codex: raw, claude: nil)
        }
        return decoded
    }

    func encodedIfNeeded() -> String? {
        guard codex != nil || claude != nil || !codexBuffer.isEmpty || !claudeBuffer.isEmpty else {
            return nil
        }
        guard let data = try? Self.encoder.encode(self) else {
            return nil
        }
        return data.base64EncodedString()
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

final class MultiRuntimeSessionAPIClient: SessionStoreAPIClient {
    private let bundle: AppServerRuntimeBundle
    private let codexClient: CodexAppServerSessionAPIClient

    init(bundle: AppServerRuntimeBundle) {
        self.bundle = bundle
        self.codexClient = CodexAppServerSessionAPIClient(runtime: bundle.codex)
    }

    convenience init(codexRuntime: CodexAppServerSessionRuntime, claudeRuntime: CodexAppServerSessionRuntime) {
        self.init(bundle: AppServerRuntimeBundle(codexRuntime: codexRuntime, claudeRuntime: claudeRuntime))
    }

    func projects() async throws -> [AgentProject] { try await codexClient.projects() }
    func capabilities(path: String?) async throws -> CapabilityListResponse { try await codexClient.capabilities(path: path) }
    func resolveWorkspace(path: String) async throws -> AgentWorkspace { try await codexClient.resolveWorkspace(path: path) }
    func createWorktree(path: String, name: String?, base: String?, branch: String?) async throws -> WorktreeCreateResponse { try await codexClient.createWorktree(path: path, name: name, base: base, branch: branch) }
    func worktreeBranches(path: String) async throws -> WorktreeBranchListResponse { try await codexClient.worktreeBranches(path: path) }
    func listWorktrees() async throws -> [WorktreeListItem] { try await codexClient.listWorktrees() }
    func deleteWorktree(path: String, force: Bool) async throws -> WorktreeDeleteResponse { try await codexClient.deleteWorktree(path: path, force: force) }
    func pruneMissingWorktrees() async throws -> WorktreePruneResponse { try await codexClient.pruneMissingWorktrees() }
    func listDirectories(path: String) async throws -> DirectoryListResponse { try await codexClient.listDirectories(path: path) }
    func readFile(path: String) async throws -> FileReadResponse { try await codexClient.readFile(path: path) }
    func readHistoryMedia(id: String) async throws -> FileReadResponse { try await codexClient.readHistoryMedia(id: id) }
    func commandActions(path: String) async throws -> [AgentCommandAction] { try await codexClient.commandActions(path: path) }
    func runCommandAction(path: String, id: String, confirmed: Bool) async throws -> CommandActionRunResponse { try await codexClient.runCommandAction(path: path, id: id, confirmed: confirmed) }
    func gitStatus(path: String) async throws -> GitStatusResponse { try await codexClient.gitStatus(path: path) }
    func gitAction(path: String, action: GitActionKind, files: [String]) async throws -> GitStatusResponse { try await codexClient.gitAction(path: path, action: action, files: files) }
    func gitPatchAction(path: String, action: GitActionKind, patch: String) async throws -> GitStatusResponse { try await codexClient.gitPatchAction(path: path, action: action, patch: patch) }
    func gitCommit(path: String, message: String) async throws -> GitStatusResponse { try await codexClient.gitCommit(path: path, message: message) }
    func gitPush(path: String, remote: String?) async throws -> GitPushResponse { try await codexClient.gitPush(path: path, remote: remote) }
    func gitCreatePullRequest(path: String, title: String, body: String, draft: Bool) async throws -> GitPullRequestResponse { try await codexClient.gitCreatePullRequest(path: path, title: title, body: body, draft: draft) }
    func gitPullRequestStatus(path: String) async throws -> GitPullRequestStatusResponse { try await codexClient.gitPullRequestStatus(path: path) }
    func transcribeVoice(filename: String, contentType: String, audioData: Data, language: String?, prompt: String?) async throws -> VoiceTranscriptionResponse {
        try await codexClient.transcribeVoice(filename: filename, contentType: contentType, audioData: audioData, language: language, prompt: prompt)
    }

    func modelOptions() async throws -> [CodexAppServerModelOption] {
        var options = try await bundle.codex.modelOptions()
        if try await bundle.codex.channelAvailable(runtimeProvider: "claude") {
            do {
                options.append(contentsOf: try await bundle.claude.modelOptions())
            } catch {
                // Claude 是 experimental runtime；模型列表失败不能拖垮 Codex 主路径。
                // config/channel metadata 会继续暴露 bridge 状态，菜单这里优先保持可用。
                print("Claude model/list unavailable: \(error.localizedDescription)")
            }
        }
        var seen: Set<String> = []
        return options.filter { option in
            guard !seen.contains(option.id) else { return false }
            seen.insert(option.id)
            return true
        }
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        try await sessionsPage(projectID: projectID, cursor: cursor, limit: limit).sessions
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        let decoded = MultiRuntimeSessionsCursor.decode(cursor)
        let codexPage = try await page(runtime: bundle.codex, projectID: projectID, cursor: decoded.codex, limit: limit, buffer: decoded.codexBuffer)
        let claudeAvailable = try await bundle.codex.channelAvailable(runtimeProvider: "claude")
        let claudePage = claudeAvailable
            ? try await page(runtime: bundle.claude, projectID: projectID, cursor: decoded.claude, limit: limit, buffer: decoded.claudeBuffer)
            : preservedPage(cursor: decoded.claude, buffer: decoded.claudeBuffer)
        return mergedPage(codex: codexPage, claude: claudePage, limit: limit)
    }

    func sessionsPage(workspace: AgentWorkspace, cursor: String?, limit: Int?) async throws -> SessionsPage {
        let decoded = MultiRuntimeSessionsCursor.decode(cursor)
        let codexPage = try await page(runtime: bundle.codex, workspace: workspace, cursor: decoded.codex, limit: limit, buffer: decoded.codexBuffer)
        let claudeAvailable = try await bundle.codex.channelAvailable(runtimeProvider: "claude")
        let claudePage = claudeAvailable
            ? try await page(runtime: bundle.claude, workspace: workspace, cursor: decoded.claude, limit: limit, buffer: decoded.claudeBuffer)
            : preservedPage(cursor: decoded.claude, buffer: decoded.claudeBuffer)
        return mergedPage(codex: codexPage, claude: claudePage, limit: limit)
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        let response = try await bundle.runtime(forSessionID: id).session(id: id, afterSeq: afterSeq)
        bundle.routes.remember(response.session)
        return response
    }

    func threadGoal(threadID: String) async throws -> ThreadGoal? {
        try await bundle.runtime(forSessionID: threadID).threadGoal(threadID: threadID)
    }

    func setThreadGoal(threadID: String, objective: String?, status: ThreadGoalStatus?, tokenBudget: Int64?) async throws -> ThreadGoal {
        try await bundle.runtime(forSessionID: threadID).setThreadGoal(threadID: threadID, objective: objective, status: status, tokenBudget: tokenBudget)
    }

    func clearThreadGoal(threadID: String) async throws {
        try await bundle.runtime(forSessionID: threadID).clearThreadGoal(threadID: threadID)
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        let runtime = bundle.runtime(for: payload.turnOptions.runtimeProvider)
        let response = try await runtime.createSession(payload)
        bundle.routes.remember(response.session)
        return response
    }

    func forkSession(threadID: String, workspace: AgentWorkspace) async throws -> AgentSession {
        let session = try await bundle.runtime(forSessionID: threadID).forkSession(threadID: threadID, workspace: workspace)
        bundle.routes.remember(session)
        return session
    }

    func stopSession(id: String) async throws {
        try await bundle.runtime(forSessionID: id).stopSession(id: id)
    }

    func setSessionArchived(id: String, archived: Bool) async throws {
        try await bundle.runtime(forSessionID: id).setSessionArchived(id: id, archived: archived)
        if archived {
            bundle.routes.remove(sessionID: id)
        }
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        try await messagesPage(sessionID: sessionID, before: before, limit: limit).messages
    }

    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage {
        try await bundle.runtime(forSessionID: sessionID).messagesPage(sessionID: sessionID, before: before, limit: limit)
    }

    private struct RuntimePage {
        var sessions: [AgentSession]
        var nextCursor: String?
    }

    private func page(runtime: CodexAppServerSessionRuntime, projectID: String?, cursor: String?, limit: Int?, buffer: [AgentSession]) async throws -> RuntimePage {
        if !buffer.isEmpty {
            return RuntimePage(sessions: buffer, nextCursor: cursor)
        }
        let page = try await runtime.sessionsPage(projectID: projectID, cursor: cursor, limit: limit)
        return RuntimePage(sessions: page.sessions, nextCursor: page.hasMore ? page.nextCursor : nil)
    }

    private func page(runtime: CodexAppServerSessionRuntime, workspace: AgentWorkspace, cursor: String?, limit: Int?, buffer: [AgentSession]) async throws -> RuntimePage {
        if !buffer.isEmpty {
            return RuntimePage(sessions: buffer, nextCursor: cursor)
        }
        let page = try await runtime.sessionsPage(workspace: workspace, cursor: cursor, limit: limit)
        return RuntimePage(sessions: page.sessions, nextCursor: page.hasMore ? page.nextCursor : nil)
    }

    private func preservedPage(cursor: String?, buffer: [AgentSession]) -> RuntimePage {
        RuntimePage(sessions: buffer, nextCursor: cursor)
    }

    private func mergedPage(codex: RuntimePage, claude: RuntimePage, limit: Int?) -> SessionsPage {
        var sessions = codex.sessions + claude.sessions
        bundle.routes.remember(sessions)
        sessions.sort { lhs, rhs in
            switch (lhs.updatedAt, rhs.updatedAt) {
            case let (l?, r?):
                return l > r
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.id < rhs.id
            }
        }
        let bounded: [AgentSession]
        if let limit, limit > 0, sessions.count > limit {
            bounded = Array(sessions.prefix(limit))
        } else {
            bounded = sessions
        }
        let emittedIDs = Set(bounded.map(\.id))
        let next = MultiRuntimeSessionsCursor(
            codex: codex.nextCursor,
            claude: claude.nextCursor,
            codexBuffer: codex.sessions.filter { !emittedIDs.contains($0.id) },
            claudeBuffer: claude.sessions.filter { !emittedIDs.contains($0.id) }
        )
        return SessionsPage(sessions: bounded, nextCursor: next.encodedIfNeeded(), hasMore: next.encodedIfNeeded() != nil)
    }
}

typealias CodexAppServerRuntimeRoutingSessionAPIClient = MultiRuntimeSessionAPIClient

final class MultiRuntimeSessionWebSocketClient: SessionWebSocketClient {
    var onEvent: ((AgentEvent) -> Void)?
    var onStatus: ((WebSocketStatus) -> Void)?
    var onSendAccepted: ((ClientMessageID?) -> Void)?
    var onSendFailure: ((ClientMessageID?, String) -> Void)?
    var onApprovalDecisionFailure: ((String, String) -> Void)?
    var onUserInputResponseFailure: ((String, String) -> Void)?
    var onControlFailure: ((String) -> Void)?

    private let bundle: AppServerRuntimeBundle
    private var activeClient: CodexAppServerSessionWebSocketClient?

    init(bundle: AppServerRuntimeBundle) {
        self.bundle = bundle
    }

    func connect(sessionID: SessionID) {
        connect(sessionID: sessionID, replayBufferedEvents: true)
    }

    func connect(sessionID: SessionID, replayBufferedEvents: Bool) {
        let client = CodexAppServerSessionWebSocketClient(runtime: bundle.runtime(forSessionID: sessionID))
        activeClient?.disconnect()
        activeClient = client
        wireHandlers(to: client)
        client.connect(sessionID: sessionID, replayBufferedEvents: replayBufferedEvents)
    }

    func disconnect() {
        activeClient?.disconnect()
        activeClient = nil
    }

    @discardableResult
    func sendInput(_ text: String, clientMessageID: ClientMessageID?) -> Bool {
        activeClient?.sendInput(text, clientMessageID: clientMessageID) ?? false
    }

    @discardableResult
    func sendTurn(_ payload: CodexAppServerTurnPayload, clientMessageID: ClientMessageID?) -> Bool {
        activeClient?.sendTurn(payload, clientMessageID: clientMessageID) ?? false
    }

    @discardableResult
    func sendGuidance(_ payload: CodexAppServerTurnPayload, clientMessageID: ClientMessageID?, expectedTurnID: TurnID) -> Bool {
        activeClient?.sendGuidance(payload, clientMessageID: clientMessageID, expectedTurnID: expectedTurnID) ?? false
    }

    @discardableResult
    func sendCtrlC() -> Bool {
        activeClient?.sendCtrlC() ?? false
    }

    @discardableResult
    func sendApprovalDecision(approvalID: String, decision: String, message: String?) -> Bool {
        activeClient?.sendApprovalDecision(approvalID: approvalID, decision: decision, message: message) ?? false
    }

    @discardableResult
    func sendUserInputResponse(requestID: String, answers: [String: [String]]) -> Bool {
        activeClient?.sendUserInputResponse(requestID: requestID, answers: answers) ?? false
    }

    private func wireHandlers(to client: CodexAppServerSessionWebSocketClient) {
        client.onStatus = { [weak self] status in
            self?.onStatus?(status)
        }
        client.onEvent = { [weak self] event in
            self?.rememberRoute(from: event)
            self?.onEvent?(event)
        }
        client.onSendAccepted = { [weak self] clientMessageID in
            self?.onSendAccepted?(clientMessageID)
        }
        client.onSendFailure = { [weak self] clientMessageID, message in
            self?.onSendFailure?(clientMessageID, message)
        }
        client.onApprovalDecisionFailure = { [weak self] approvalID, message in
            self?.onApprovalDecisionFailure?(approvalID, message)
        }
        client.onUserInputResponseFailure = { [weak self] requestID, message in
            self?.onUserInputResponseFailure?(requestID, message)
        }
        client.onControlFailure = { [weak self] message in
            self?.onControlFailure?(message)
        }
    }

    private func rememberRoute(from event: AgentEvent) {
        switch event {
        case .session(let session):
            bundle.routes.remember(session)
        case .sessionRow(let row, _):
            bundle.routes.remember(row.runtimeProvider ?? row.source, for: row.id)
        default:
            break
        }
    }
}

final class CodexAppServerSessionWebSocketClient: SessionWebSocketClient {
    var onEvent: ((AgentEvent) -> Void)?
    var onStatus: ((WebSocketStatus) -> Void)?
    var onSendAccepted: ((ClientMessageID?) -> Void)?
    var onSendFailure: ((ClientMessageID?, String) -> Void)?
    var onApprovalDecisionFailure: ((String, String) -> Void)?
    var onUserInputResponseFailure: ((String, String) -> Void)?
    var onControlFailure: ((String) -> Void)?

    private let runtime: CodexAppServerSessionRuntime
    private var sessionID: SessionID?
    private var eventPumpTask: Task<Void, Never>?

    init(runtime: CodexAppServerSessionRuntime) {
        self.runtime = runtime
    }

    func connect(sessionID threadID: SessionID) {
        connect(sessionID: threadID, replayBufferedEvents: true)
    }

    func connect(sessionID threadID: SessionID, replayBufferedEvents: Bool) {
        sessionID = threadID
        onStatus?(.connecting)
        eventPumpTask?.cancel()
        let statusHandler = onStatus
        let eventHandler = onEvent
        let replayPolicy: CodexAppServerBufferedEventReplayPolicy = replayBufferedEvents ? .all : .stateOnly
        eventPumpTask = Task { [runtime] in
            do {
                try await runtime.connectForEvents(sessionID: threadID)
                let events = await runtime.attachEvents(sessionID: threadID, replayPolicy: replayPolicy)
                await MainActor.run {
                    statusHandler?(.connected)
                }
                for await event in events {
                    await MainActor.run {
                        eventHandler?(event)
                    }
                }
                await MainActor.run {
                    statusHandler?(.disconnected)
                }
            } catch {
                await MainActor.run {
                    statusHandler?(.failed(error.localizedDescription))
                }
            }
        }
    }

    func disconnect() {
        eventPumpTask?.cancel()
        eventPumpTask = nil
        onStatus?(.disconnected)
    }

    @discardableResult
    func sendInput(_ text: String, clientMessageID: ClientMessageID?) -> Bool {
        var prompt = text
        if prompt.hasSuffix("\r") {
            prompt.removeLast()
        }
        return sendTurn(CodexAppServerTurnPayload(prompt: prompt), clientMessageID: clientMessageID)
    }

    @discardableResult
    func sendTurn(_ payload: CodexAppServerTurnPayload, clientMessageID: ClientMessageID?) -> Bool {
        guard let sessionID else {
            onSendFailure?(clientMessageID, "direct WebSocket 未连接")
            return false
        }
        guard !payload.isEmpty else {
            return true
        }
        let acceptedHandler = onSendAccepted
        let failureHandler = onSendFailure
        Task { [runtime] in
            do {
                _ = try await runtime.startTurn(sessionID: sessionID, payload: payload, clientMessageID: clientMessageID)
                await MainActor.run {
                    acceptedHandler?(clientMessageID)
                }
            } catch {
                await MainActor.run {
                    failureHandler?(clientMessageID, error.localizedDescription)
                }
            }
        }
        return true
    }

    @discardableResult
    func sendGuidance(_ payload: CodexAppServerTurnPayload, clientMessageID: ClientMessageID?, expectedTurnID: TurnID) -> Bool {
        guard let sessionID else {
            onSendFailure?(clientMessageID, "direct WebSocket 未连接")
            return false
        }
        guard !payload.isEmpty else {
            return true
        }
        let acceptedHandler = onSendAccepted
        let failureHandler = onSendFailure
        Task { [runtime, sessionID] in
            do {
                try await runtime.steerTurn(
                    sessionID: sessionID,
                    payload: payload,
                    clientMessageID: clientMessageID,
                    expectedTurnID: expectedTurnID
                )
                await MainActor.run {
                    acceptedHandler?(clientMessageID)
                }
            } catch {
                await MainActor.run {
                    failureHandler?(clientMessageID, error.localizedDescription)
                }
            }
        }
        return true
    }

    @discardableResult
    func sendCtrlC() -> Bool {
        guard let sessionID else {
            onControlFailure?("direct WebSocket 未连接")
            return false
        }
        let failureHandler = onControlFailure
        Task { [runtime] in
            do {
                try await runtime.interruptActiveTurn(sessionID: sessionID)
            } catch {
                await MainActor.run {
                    failureHandler?(error.localizedDescription)
                }
            }
        }
        return true
    }

    @discardableResult
    func sendApprovalDecision(approvalID: String, decision: String, message: String?) -> Bool {
        guard let sessionID else {
            onApprovalDecisionFailure?(approvalID, "direct WebSocket 未连接")
            return false
        }
        let failureHandler = onApprovalDecisionFailure
        Task { [runtime, sessionID] in
            do {
                try await runtime.respondToApproval(sessionID: sessionID, approvalID: approvalID, decision: decision)
            } catch {
                await MainActor.run {
                    failureHandler?(approvalID, error.localizedDescription)
                }
            }
        }
        return true
    }

    @discardableResult
    func sendUserInputResponse(requestID: String, answers: [String: [String]]) -> Bool {
        guard let sessionID else {
            onUserInputResponseFailure?(requestID, "direct WebSocket 未连接")
            return false
        }
        let failureHandler = onUserInputResponseFailure
        Task { [runtime, sessionID] in
            do {
                try await runtime.respondToUserInput(sessionID: sessionID, requestID: requestID, answers: answers)
            } catch {
                await MainActor.run {
                    failureHandler?(requestID, error.localizedDescription)
                }
            }
        }
        return true
    }
}
