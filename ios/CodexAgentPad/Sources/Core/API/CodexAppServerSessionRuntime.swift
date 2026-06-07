import Foundation

enum CodexAppServerSessionRuntimeError: LocalizedError {
    case invalidGatewayURL
    case gatewayUnavailable
    case projectNotFound(String)
    case projectRequired
    case sessionNotFound(SessionID)
    case missingActiveTurn(SessionID)
    case approvalNotFound(String)

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

actor CodexAppServerSessionRuntime {
    private let endpoint: String
    private let token: String
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

    init(
        endpoint: String,
        token: String,
        transportFactory: @escaping () -> CodexAppServerTransport = { URLSessionCodexAppServerTransport() },
        configProvider: (() async throws -> CodexAppServerConfigResponse)? = nil
    ) {
        let normalizedEndpoint = AgentAPIClient.normalizedEndpoint(endpoint)
        self.endpoint = normalizedEndpoint
        self.token = token
        self.transportFactory = transportFactory
        self.configProvider = configProvider ?? {
            try await AgentAPIClient(endpoint: normalizedEndpoint, token: token).appServerConfig()
        }
    }

    deinit {
        connectionTask?.cancel()
        notificationPumpTask?.cancel()
        serverRequestPumpTask?.cancel()
    }

    func projects() async throws -> [AgentProject] {
        try await ensureConfig().projects
    }

    func modelOptions() async throws -> [CodexAppServerModelOption] {
        let result = try await ensureConnection().send(
            CodexAppServerRequestBuilder(allowlistedProjects: try await projects()).modelList()
        )
        return CodexAppServerModelOption.parseListResult(result)
    }

    func validateDirectGateway() async throws {
        let config = try await ensureConfig(forceRefresh: true)
        guard config.runtime.gatewayAvailable, !config.gatewayWSURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexAppServerSessionRuntimeError.gatewayUnavailable
        }
        let gatewayURL = try gatewayURL(from: config)
        let probe = CodexAppServerConnection(transport: transportFactory())
        try await probe.connect(url: gatewayURL, token: token)
        await probe.disconnect()
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

        let result = try await ensureConnection().send(spec)
        let page = threadListPage(from: result, projects: projects, fallbackProject: project)
        for session in page.sessions {
            contextsBySessionID[session.id] = CodexAppServerSessionContext(
                session: session,
                cwd: session.dir,
                activeTurnID: session.activeTurnID
            )
        }
        return page
    }

    func session(id: SessionID, afterSeq: EventSequence?) async throws -> SessionResponse {
        let result = try await ensureConnection().send(CodexAppServerRequestBuilder(allowlistedProjects: try await projects()).threadRead(threadID: id, includeTurns: false))
        guard let thread = threadObject(from: result) else {
            throw CodexAppServerSessionRuntimeError.sessionNotFound(id)
        }
        let session = try agentSession(from: thread, projects: try await projects(), fallbackProject: nil)
        contextsBySessionID[id] = CodexAppServerSessionContext(
            session: session,
            cwd: session.dir,
            activeTurnID: session.activeTurnID
        )
        return SessionResponse(session: session, recentOutput: nil, lastSeq: session.lastSeq)
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        let projects = try await projects()
        guard let project = projects.first(where: { $0.id == payload.projectID }) else {
            throw CodexAppServerSessionRuntimeError.projectNotFound(payload.projectID)
        }
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: projects)
        let spec: CodexAppServerRequestSpec
        if payload.resumeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            spec = try builder.threadStart(projectID: payload.projectID, options: payload.turnOptions)
        } else {
            spec = try builder.threadResume(threadID: payload.resumeID, projectID: payload.projectID, options: payload.turnOptions)
        }

        let result = try await ensureConnection().send(spec)
        guard let thread = threadObject(from: result) else {
            throw AgentAPIError.invalidResponse
        }
        var session = try agentSession(from: thread, projects: projects, fallbackProject: project, forceRunning: true)
        let cwd = session.dir
        contextsBySessionID[session.id] = CodexAppServerSessionContext(session: session, cwd: cwd, activeTurnID: session.activeTurnID)
        // thread/start 与 thread/resume 都已经把 thread 绑定到当前连接，记录下来避免随后的 turn/start 再重复 resume。
        threadsResumedOnConnection.insert(session.id)

        let turnPayload = CodexAppServerTurnPayload(input: payload.input, options: payload.turnOptions)
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
            wsURL: try Self.gatewayURL(endpoint: endpoint, sessionID: session.id).absoluteString
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
        _ = try await ensureConnection().send(spec)
        _ = withUpdatedSession(id) { item in
            item.status = "closed"
            item.activeTurnID = nil
        }
    }

    // thread/read 是整段历史的批量拉取，慢链路（Tailscale）下比交互式请求耗时得多；给它一个更宽的
    // 超时，避免大会话首屏因为 20s 的默认请求超时而直接报错。
    private static let bulkReadTimeout: TimeInterval = 60

    func messagesPage(sessionID: SessionID, before: String?, limit: Int?) async throws -> HistoryMessagesPage {
        // 翻看更早历史：老 turn 不会变，直接用上次整段读取的缓存切窗口，不再重复拉整段 thread。
        if before != nil, let cached = threadHistoryCacheBySessionID[sessionID] {
            return Self.paginateHistory(cached, before: before, limit: limit)
        }
        let result = try await ensureConnection().send(
            CodexAppServerRequestBuilder(allowlistedProjects: try await projects()).threadRead(threadID: sessionID, includeTurns: true),
            timeout: Self.bulkReadTimeout
        )
        guard let thread = threadObject(from: result) else {
            throw CodexAppServerSessionRuntimeError.sessionNotFound(sessionID)
        }
        let messages = historyMessages(from: thread, sessionID: sessionID)
        threadHistoryCacheBySessionID[sessionID] = messages
        return Self.paginateHistory(messages, before: before, limit: limit)
    }

    // thread/read 一次性返回整段 thread 历史；分页只能在客户端做。按消息稳定 id 切窗口，并回填
    // previousCursor / hasMoreBefore，否则长会话只会拿到最近一窗，最早的消息既被 suffix 截掉、又因为
    // 没有 cursor 而永远翻不回去（直连取代旧 REST 兼容链路后这条路是唯一来源）。
    static func paginateHistory(
        _ messages: [CodexHistoryMessage],
        before: String?,
        limit: Int?
    ) -> HistoryMessagesPage {
        let upperBound: Int
        if let before {
            guard let index = messages.firstIndex(where: { $0.id == before }) else {
                // 游标对应的消息已不在历史里（极少见），关闭分页，避免反复请求同一页。
                return HistoryMessagesPage(messages: [], previousCursor: nil, hasMoreBefore: false)
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
            hasMoreBefore: hasMoreBefore
        )
    }

    func attachEvents(sessionID: SessionID) -> AsyncStream<AgentEvent> {
        var continuation: AsyncStream<AgentEvent>.Continuation?
        let stream = AsyncStream<AgentEvent>(bufferingPolicy: .bufferingNewest(512)) {
            continuation = $0
        }
        if let continuation {
            eventContinuationsBySessionID[sessionID] = continuation
            for event in bufferedEventsBySessionID.removeValue(forKey: sessionID) ?? [] {
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

    func connectForEvents(sessionID: SessionID) async throws {
        let connection = try await ensureConnection()
        if contextsBySessionID[sessionID] == nil {
            _ = try await session(id: sessionID, afterSeq: nil)
        }
        guard let context = contextsBySessionID[sessionID] else {
            throw CodexAppServerSessionRuntimeError.sessionNotFound(sessionID)
        }
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: try await projects())
        // 官方 app-server 客户端选择历史 thread 时会使用 thread/resume 建立 live listener；thread/read/list 只能做
        // hydration。移动端打开会话也要先绑定当前连接，否则历史里的 pending approval 和后续 turn 事件
        // 可能不会回流到 iPad。
        try await ensureThreadResumedOnConnection(sessionID: sessionID, cwd: context.cwd, builder: builder, connection: connection)
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
        guard let context = contextsBySessionID[sessionID] else {
            throw CodexAppServerSessionRuntimeError.sessionNotFound(sessionID)
        }
        guard !payload.isEmpty else {
            return nil
        }
        sessionsStartingTurn.insert(sessionID)
        defer {
            sessionsStartingTurn.remove(sessionID)
        }
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: try await projects())
        let connection = try await ensureConnection()
        try await ensureThreadResumedOnConnection(sessionID: sessionID, cwd: context.cwd, builder: builder, connection: connection)
        let result = try await connection.send(try builder.turnStart(
            threadID: sessionID,
            cwd: context.cwd,
            payload: payload,
            clientMessageID: clientMessageID
        ))
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

    // 直连发送路径下，目标 thread 可能只在 thread/list 里出现过，但没有在当前 gateway 连接上 resume。
    // app-server 不会向「没在本连接 resume/start 过」的 thread 推送 turn 事件，于是直接 turn/start 会
    // 看不到任何回复（也收不到 turn/completed，active turn 角标会一直挂着）。这里在首次 turn/start 前补
    // 一次按当前连接的 resume，事件才会回流；连接重连后集合清空，会自动重新补上。
    private func ensureThreadResumedOnConnection(
        sessionID: SessionID,
        cwd: String,
        builder: CodexAppServerRequestBuilder,
        connection: CodexAppServerConnection
    ) async throws {
        guard !threadsResumedOnConnection.contains(sessionID) else {
            return
        }
        let result = try await connection.send(try builder.threadResume(threadID: sessionID, cwd: cwd))
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

    func interruptActiveTurn(sessionID: SessionID) async throws {
        guard let turnID = contextsBySessionID[sessionID]?.activeTurnID else {
            throw CodexAppServerSessionRuntimeError.missingActiveTurn(sessionID)
        }
        let spec = CodexAppServerRequestBuilder(allowlistedProjects: try await projects()).turnInterrupt(threadID: sessionID, turnID: turnID)
        _ = try await ensureConnection().send(spec)
    }

    func respondToApproval(sessionID: SessionID? = nil, approvalID: String, decision: String) async throws {
        let lookupKeys = pendingApprovalLookupKeys(sessionID: sessionID, approvalID: approvalID)
        guard let request = lookupKeys.compactMap({ pendingApprovalRequestsByID[$0] }).first else {
            throw CodexAppServerSessionRuntimeError.approvalNotFound(approvalID)
        }
        removePendingApprovalRequest(request)
        let normalized = normalizeApprovalDecision(decision)
        let result = approvalResponse(method: request.method, params: request.params?.objectValue ?? [:], decision: normalized)
        try await ensureConnection().respond(to: request, result: result)
    }

    static func gatewayURL(endpoint: String, sessionID: SessionID) throws -> URL {
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
        components.queryItems = [URLQueryItem(name: "thread_id", value: sessionID)]
        guard let url = components.url else {
            throw AgentAPIError.invalidEndpoint
        }
        return url
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
        guard config.runtime.gatewayAvailable else {
            throw CodexAppServerSessionRuntimeError.gatewayUnavailable
        }
        let gatewayURL = try gatewayURL(from: config)
        let next = CodexAppServerConnection(transport: transportFactory())
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
        if cached.runtime.gatewayAvailable {
            return cached
        }
        // 首次冷启动时 agentd 可能先返回项目列表，但 app-server gateway 仍在启动。
        // 这种不可用 config 不能长期缓存，否则 bootstrap 重试会一直复用旧状态，直到用户杀掉 APP。
        return try await ensureConfig(forceRefresh: true)
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

    private func retireConnection(_ stale: CodexAppServerConnection) async {
        notificationPumpTask?.cancel()
        notificationPumpTask = nil
        serverRequestPumpTask?.cancel()
        serverRequestPumpTask = nil
        connection = nil
        threadsResumedOnConnection.removeAll(keepingCapacity: true)
        let affectedSessionIDs = clearAllPendingApprovalRequests()
        for sessionID in affectedSessionIDs {
            emitApprovalResolved(sessionID: sessionID)
        }
        await stale.disconnect()
    }

    func hasReadyConnectionForTesting() async -> Bool {
        guard let connection else {
            return false
        }
        return await connection.isReadyForRequests()
    }

    private func gatewayURL(from config: CodexAppServerConfigResponse) throws -> URL {
        if let url = URL(string: config.gatewayWSURL), !config.gatewayWSURL.isEmpty {
            return url
        }
        guard let url = URL(string: try Self.gatewayURL(endpoint: endpoint, sessionID: "").absoluteString) else {
            throw CodexAppServerSessionRuntimeError.invalidGatewayURL
        }
        return url
    }

    private func handle(_ notification: CodexAppServerNotification) {
        updateContext(from: notification)
        let affectedSessionIDs = clearResolvedServerRequest(from: notification)
        guard let event = projector.project(notification) else {
            for sessionID in affectedSessionIDs {
                emitApprovalResolved(sessionID: sessionID)
            }
            return
        }
        emit(event)
        let emittedSessionID = sessionID(from: event)
        for sessionID in affectedSessionIDs where sessionID != emittedSessionID {
            emitApprovalResolved(sessionID: sessionID)
        }
    }

    private func handle(_ request: CodexAppServerServerRequest) {
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
        // app-server 可能把 thread 卡在 waitingOnApproval，并把这条早被放弃的旧审批所在的 turn 仍然
        // 报成 active（activeTurnID 与审批 turnId 相同），于是下面按 turn 比对的判据全都命中不了。改用
        // 审批自带的 startedAtMs：不是本端发起、且早就挂在那里的审批，必然是历史 transcript 里没
        // terminal 化、被 thread/resume 反复重放的旧请求（现场就是一条 22 小时前、之后又被十几个 turn
        // 取代的提权审批），直接 fail-closed 释放，避免每次打开 thread 都凭空冒出旧审批卡。
        if let startedAtMs = approvalStartedAtMs(for: request),
           Date().timeIntervalSince1970 - startedAtMs / 1000 > Self.staleReplayedApprovalMaxAge {
            return true
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

    // 审批挂起超过这个时长就视为历史里没 terminal 化的旧请求。真正需要用户当下处理的审批一定是刚发生的；
    // 本端自己发起的 turn 不受这个阈值约束（见上面的 turnsStartedByThisRuntime 放行）。
    private static let staleReplayedApprovalMaxAge: TimeInterval = 10 * 60

    private func approvalStartedAtMs(for request: CodexAppServerServerRequest) -> Double? {
        let params = request.params?.objectValue ?? [:]
        for key in ["startedAtMs", "started_at_ms", "createdAtMs", "created_at_ms"] {
            if let value = params[key]?.intValue {
                return Double(value)
            }
        }
        return nil
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
             .turnStarted(let metadata),
             .assistantDelta(_, let metadata),
             .messageCompleted(_, let metadata),
             .logDelta(_, let metadata),
             .diffUpdated(_, let metadata),
             .approvalRequest(_, let metadata),
             .approvalResolved(let metadata),
             .turnCompleted(let metadata),
             .warning(_, let metadata):
            return metadata.sessionID
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
            break
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

    private func threadObject(from result: CodexAppServerJSONValue?) -> [String: CodexAppServerJSONValue]? {
        result?["thread"]?.objectValue
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
            ?? "Codex Thread \(id.prefix(8))"
        let cached = contextsBySessionID[id]?.session
        // thread/list 可能不带 turns，此时沿用本地 activeTurnID；但 thread/read/resume 一旦带回
        // turns，就让服务端最新的 inProgress turn 覆盖旧缓存。现场曾出现旧审批 turn 长期保持
        // inProgress，同时后面又有新的 inProgress turn；如果缓存优先，会把旧审批误当当前审批。
        let remoteActiveTurnID = activeTurnID(from: thread)
        let activeTurnID = remoteActiveTurnID ?? cached?.activeTurnID
        // 列表/历史读偶发把正在执行的 turn 读成 history。只有本地确实记着一个进行中的 turn（activeTurnID
        // 非空）时，才在这一瞬间保留运行态，避免侧栏角标抖动；没有活跃 turn 的残留态（例如被放弃的审批
        // 等待）必须允许权威 history 把它降级，否则 stale 审批态会一直挂着清不掉。
        let effectiveStatus = (cached?.activeTurnID != nil && status == "history") ? (cached?.status ?? status) : status
        let context = sessionContext(
            from: thread,
            sessionID: id,
            cwd: cwd,
            status: effectiveStatus,
            statusValue: forceRunning ? nil : thread["status"],
            project: project ?? fallbackProject
        )
        return AgentSession(
            id: id,
            projectID: projectID,
            project: projectName,
            dir: cwd,
            title: title.isEmpty ? "未命名会话" : title,
            status: effectiveStatus,
            source: "codex",
            resumeID: id,
            createdAt: date(from: thread["createdAt"]),
            updatedAt: date(from: thread["updatedAt"]),
            preview: preview,
            activeTurnID: activeTurnID,
            lastSeq: nil,
            revision: 0,
            context: context
        )
    }

    private func sessionContext(
        from thread: [String: CodexAppServerJSONValue],
        sessionID: SessionID,
        cwd: String,
        status: String,
        statusValue: CodexAppServerJSONValue?,
        project: AgentProject?
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
                provider: nonEmpty(thread["modelProvider"]?.stringValue, "openai")
            ),
            git: gitInfo(from: thread["gitInfo"]?.objectValue),
            tasks: contextTasks(from: thread),
            sources: contextSources(from: thread, project: project),
            subagents: contextSubagents(from: thread, status: status),
            updatedAt: Date()
        )
    }

    private func projectFor(cwd: String, projects: [AgentProject]) -> AgentProject? {
        projects.first { project in
            project.path == cwd
        }
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
            sources.append(SessionContextSource(id: "session_source", kind: "session", label: label, subtitle: "session source"))
        }
        if let threadSource = nonEmpty(thread["threadSource"]?.stringValue) {
            sources.append(SessionContextSource(id: "thread_source", kind: "thread", label: threadSource, subtitle: "thread source"))
        }
        if let forkedFrom = nonEmpty(thread["forkedFromId"]?.stringValue) {
            sources.append(SessionContextSource(id: "forked_from", kind: "fork", label: String(forkedFrom.prefix(32)), subtitle: "forked from"))
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
        guard let parentThreadID = nonEmpty(thread["parentThreadId"]?.stringValue) else {
            return []
        }
        return [
            SessionContextSubagent(
                id: thread["id"]?.stringValue ?? UUID().uuidString,
                parentThreadID: parentThreadID,
                nickname: nonEmpty(thread["agentNickname"]?.stringValue),
                role: nonEmpty(thread["agentRole"]?.stringValue),
                status: status
            )
        ]
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
        case "mcpToolCall", "dynamicToolCall":
            let title = nonEmpty(item["tool"]?.stringValue, item["name"]?.stringValue, "工具调用") ?? "工具调用"
            let subtitle = nonEmpty(item["server"]?.stringValue, item["namespace"]?.stringValue, item["pluginId"]?.stringValue)
            return SessionContextTask(id: id, kind: "tool", title: title, subtitle: subtitle, status: status)
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

    private func activeTurnID(from thread: [String: CodexAppServerJSONValue]) -> TurnID? {
        let turns = thread["turns"]?.arrayValue?.compactMap(\.objectValue) ?? []
        return turns.last { turn in
            turn["status"]?.stringValue == "inProgress"
        }?["id"]?.stringValue
    }

    private func historyMessages(from thread: [String: CodexAppServerJSONValue], sessionID: SessionID) -> [CodexHistoryMessage] {
        let turns = thread["turns"]?.arrayValue?.compactMap(\.objectValue) ?? []
        return turns.flatMap { turn -> [CodexHistoryMessage] in
            let turnID = turn["id"]?.stringValue
            let timestamp = date(from: turn["startedAt"])
            let items = turn["items"]?.arrayValue?.compactMap(\.objectValue) ?? []
            return items.compactMap { item in
                historyMessage(from: item, sessionID: sessionID, turnID: turnID, createdAt: timestamp)
            }
        }
    }

    private func historyMessage(
        from item: [String: CodexAppServerJSONValue],
        sessionID: SessionID,
        turnID: TurnID?,
        createdAt: Date?
    ) -> CodexHistoryMessage? {
        let type = item["type"]?.stringValue
        let itemID = item["id"]?.stringValue ?? UUID().uuidString
        let messageID = appServerHistoryMessageID(turnID: turnID, itemID: itemID)
        switch type {
        case "userMessage":
            let text = userMessageText(from: item).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return nil
            }
            return CodexHistoryMessage(
                id: messageID,
                role: "user",
                content: text,
                createdAt: createdAt,
                clientMessageID: item["clientId"]?.stringValue,
                turnID: turnID,
                itemID: itemID
            )
        case "agentMessage":
            let text = item["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                return nil
            }
            return CodexHistoryMessage(id: messageID, role: "assistant", content: text, createdAt: createdAt, turnID: turnID, itemID: itemID)
        case "plan":
            let text = item["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                return nil
            }
            return CodexHistoryMessage(id: messageID, role: "assistant", content: text, createdAt: createdAt, turnID: turnID, itemID: itemID)
        default:
            return nil
        }
    }

    private func appServerHistoryMessageID(turnID: TurnID?, itemID: AgentItemID) -> MessageID {
        guard let turnID, !turnID.isEmpty else {
            return itemID
        }
        return "appserver:\(turnID):\(itemID)"
    }

    private func userMessageText(from item: [String: CodexAppServerJSONValue]) -> String {
        let content = item["content"]?.arrayValue ?? []
        return content.compactMap { value in
            guard let object = value.objectValue, object["type"]?.stringValue == "text" else {
                return nil
            }
            return object["text"]?.stringValue
        }
        .joined(separator: "\n")
    }

    private func approvalID(for request: CodexAppServerServerRequest) -> String? {
        let params = request.params?.objectValue ?? [:]
        return params["approvalId"]?.stringValue
            ?? params["itemId"]?.stringValue
            ?? params["item_id"]?.stringValue
            ?? params["callId"]?.stringValue
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

    private func clearResolvedServerRequest(from notification: CodexAppServerNotification) -> [SessionID] {
        guard notification.method == "serverRequest/resolved" else {
            return []
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

        var affectedSessionIDs: [SessionID] = []
        for id in ids {
            for key in pendingApprovalLookupKeys(sessionID: sessionID, approvalID: id) {
                if let request = pendingApprovalRequestsByID.removeValue(forKey: key) {
                    if let affected = approvalSessionID(for: request), !affectedSessionIDs.contains(affected) {
                        affectedSessionIDs.append(affected)
                    }
                    removePendingApprovalRequest(request)
                }
            }
        }
        if let sessionID, !affectedSessionIDs.contains(sessionID) {
            affectedSessionIDs.append(sessionID)
        }
        return affectedSessionIDs
    }

    private func clearAllPendingApprovalRequests() -> [SessionID] {
        let affectedSessionIDs = uniqueStrings(pendingApprovalRequestsByID.values.compactMap { request in
            approvalSessionID(for: request)
        })
        pendingApprovalRequestsByID.removeAll(keepingCapacity: false)
        return affectedSessionIDs
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
        return lower.contains("approval") || lower.contains("requestuserinput")
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
                "permissions": decision == "accept" ? params["permissions"] ?? .object([:]) : .object([:]),
                "scope": .string("turn")
            ])
        }
        if method == "item/tool/requestUserInput" {
            // 当前 iPad UI 还没有动态表单；返回空答案比构造伪输入更安全。
            return .object(["answers": .object([:])])
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
            return Date(timeIntervalSince1970: TimeInterval(int))
        case .double(let double):
            return Date(timeIntervalSince1970: double)
        case .string(let raw):
            guard let double = Double(raw) else {
                return nil
            }
            return Date(timeIntervalSince1970: double)
        default:
            return nil
        }
    }

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

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        try await sessionsPage(projectID: projectID, cursor: cursor, limit: limit).sessions
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        try await runtime.sessionsPage(projectID: projectID, cursor: cursor, limit: limit)
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        try await runtime.session(id: id, afterSeq: afterSeq)
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        try await runtime.createSession(payload)
    }

    func stopSession(id: String) async throws {
        try await runtime.stopSession(id: id)
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        try await messagesPage(sessionID: sessionID, before: before, limit: limit).messages
    }

    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage {
        try await runtime.messagesPage(sessionID: sessionID, before: before, limit: limit)
    }
}

final class CodexAppServerSessionWebSocketClient: SessionWebSocketClient {
    var onEvent: ((AgentEvent) -> Void)?
    var onStatus: ((WebSocketStatus) -> Void)?
    var onSendFailure: ((ClientMessageID?, String) -> Void)?

    private let runtime: CodexAppServerSessionRuntime
    private var sessionID: SessionID?
    private var eventPumpTask: Task<Void, Never>?

    init(runtime: CodexAppServerSessionRuntime) {
        self.runtime = runtime
    }

    func connect(sessionID threadID: SessionID) {
        sessionID = threadID
        onStatus?(.connecting)
        eventPumpTask?.cancel()
        let statusHandler = onStatus
        let eventHandler = onEvent
        eventPumpTask = Task { [runtime] in
            do {
                try await runtime.connectForEvents(sessionID: threadID)
                let events = await runtime.attachEvents(sessionID: threadID)
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
        let failureHandler = onSendFailure
        Task { [runtime] in
            do {
                _ = try await runtime.startTurn(sessionID: sessionID, payload: payload, clientMessageID: clientMessageID)
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
            onSendFailure?(nil, "direct WebSocket 未连接")
            return false
        }
        let failureHandler = onSendFailure
        Task { [runtime] in
            do {
                try await runtime.interruptActiveTurn(sessionID: sessionID)
            } catch {
                await MainActor.run {
                    failureHandler?(nil, error.localizedDescription)
                }
            }
        }
        return true
    }

    @discardableResult
    func sendApprovalDecision(approvalID: String, decision: String, message: String?) -> Bool {
        guard let sessionID else {
            onSendFailure?(nil, "direct WebSocket 未连接")
            return false
        }
        let failureHandler = onSendFailure
        Task { [runtime, sessionID] in
            do {
                try await runtime.respondToApproval(sessionID: sessionID, approvalID: approvalID, decision: decision)
            } catch {
                await MainActor.run {
                    failureHandler?(nil, error.localizedDescription)
                }
            }
        }
        return true
    }
}
