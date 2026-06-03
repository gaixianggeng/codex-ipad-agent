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
    private var bufferedEventsBySessionID: [SessionID: [AgentEvent]] = [:]
    private var eventContinuationsBySessionID: [SessionID: AsyncStream<AgentEvent>.Continuation] = [:]
    private var pendingApprovalRequestsByID: [String: CodexAppServerServerRequest] = [:]

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

    func validateDirectGateway() async throws {
        let config = try await ensureConfig(forceRefresh: true)
        guard config.runtime.gatewayAvailable, !config.gatewayWSURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexAppServerSessionRuntimeError.gatewayUnavailable
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
            spec = try builder.threadStart(projectID: payload.projectID)
        } else {
            spec = try builder.threadResume(threadID: payload.resumeID, projectID: payload.projectID)
        }

        let result = try await ensureConnection().send(spec)
        guard let thread = threadObject(from: result) else {
            throw AgentAPIError.invalidResponse
        }
        var session = try agentSession(from: thread, projects: projects, fallbackProject: project, forceRunning: true)
        let cwd = session.dir
        contextsBySessionID[session.id] = CodexAppServerSessionContext(session: session, cwd: cwd, activeTurnID: session.activeTurnID)

        if !payload.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let turnID = try await startTurn(
                sessionID: session.id,
                prompt: payload.prompt,
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

    func messagesPage(sessionID: SessionID, before: String?, limit: Int?) async throws -> HistoryMessagesPage {
        let result = try await ensureConnection().send(CodexAppServerRequestBuilder(allowlistedProjects: try await projects()).threadRead(threadID: sessionID, includeTurns: true))
        guard let thread = threadObject(from: result) else {
            throw CodexAppServerSessionRuntimeError.sessionNotFound(sessionID)
        }
        let messages = historyMessages(from: thread, sessionID: sessionID)
        let bounded = limit.map { Array(messages.suffix(max(1, $0))) } ?? messages
        return HistoryMessagesPage(messages: bounded, previousCursor: nil, hasMoreBefore: false)
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
        _ = try await ensureConnection()
        if contextsBySessionID[sessionID] == nil {
            _ = try await session(id: sessionID, afterSeq: nil)
        }
    }

    @discardableResult
    func startTurn(sessionID: SessionID, prompt: String, clientMessageID: ClientMessageID?) async throws -> TurnID? {
        guard let context = contextsBySessionID[sessionID] else {
            throw CodexAppServerSessionRuntimeError.sessionNotFound(sessionID)
        }
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: try await projects())
        let result = try await ensureConnection().send(try builder.turnStart(
            threadID: sessionID,
            cwd: context.cwd,
            prompt: prompt,
            clientMessageID: clientMessageID
        ))
        let turnID = result?["turn"]?.objectValue?["id"]?.stringValue
        _ = withUpdatedSession(sessionID) { item in
            item.status = "running"
            item.activeTurnID = turnID
        }
        return turnID
    }

    func interruptActiveTurn(sessionID: SessionID) async throws {
        guard let turnID = contextsBySessionID[sessionID]?.activeTurnID else {
            throw CodexAppServerSessionRuntimeError.missingActiveTurn(sessionID)
        }
        let spec = CodexAppServerRequestBuilder(allowlistedProjects: try await projects()).turnInterrupt(threadID: sessionID, turnID: turnID)
        _ = try await ensureConnection().send(spec)
    }

    func respondToApproval(approvalID: String, decision: String) async throws {
        guard let request = pendingApprovalRequestsByID.removeValue(forKey: approvalID) else {
            throw CodexAppServerSessionRuntimeError.approvalNotFound(approvalID)
        }
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
        let config = try await ensureConfig()
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

    private func installConnection(_ prepared: CodexAppServerPreparedConnection) {
        notificationPumpTask?.cancel()
        serverRequestPumpTask?.cancel()
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
        pendingApprovalRequestsByID.removeAll(keepingCapacity: false)
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
        guard let event = projector.project(notification) else {
            return
        }
        emit(event)
    }

    private func handle(_ request: CodexAppServerServerRequest) {
        if let approvalID = approvalID(for: request) {
            pendingApprovalRequestsByID[approvalID] = request
            pendingApprovalRequestsByID[request.id.description] = request
        }
        guard let event = projector.project(request) else {
            return
        }
        emit(event)
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
             .turnCompleted(let metadata),
             .warning(_, let metadata),
             .output(_, let metadata):
            return metadata.sessionID
        case .exit, .error, .pong, .unknown:
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
        let activeTurnID = cached?.activeTurnID ?? activeTurnID(from: thread)
        let effectiveStatus = cached?.isRunning == true && status == "history" ? cached?.status ?? status : status
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
            return raw == "notLoaded" ? "history" : raw
        }
        guard let object = value.objectValue else {
            return "history"
        }
        let type = object["type"]?.stringValue ?? ""
        switch type {
        case "notLoaded":
            return "history"
        case "idle":
            return "running"
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
            ?? request.id.description
    }

    private func approvalResponse(
        method: String,
        params: [String: CodexAppServerJSONValue],
        decision: String
    ) -> CodexAppServerJSONValue {
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
    private let endpoint: String
    private let runtime: CodexAppServerSessionRuntime

    init(endpoint: String, runtime: CodexAppServerSessionRuntime) {
        self.endpoint = AgentAPIClient.normalizedEndpoint(endpoint)
        self.runtime = runtime
    }

    func projects() async throws -> [AgentProject] {
        try await runtime.projects()
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

    func websocketURL(sessionID: String) throws -> URL {
        try CodexAppServerSessionRuntime.gatewayURL(endpoint: endpoint, sessionID: sessionID)
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

    func connect(url: URL, token: String) {
        guard let threadID = Self.threadID(from: url) else {
            onStatus?(.failed("direct WebSocket URL 缺少 thread_id"))
            return
        }
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
        guard let sessionID else {
            onSendFailure?(clientMessageID, "direct WebSocket 未连接")
            return false
        }
        var prompt = text
        if prompt.hasSuffix("\r") {
            prompt.removeLast()
        }
        prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return true
        }
        let failureHandler = onSendFailure
        Task { [runtime] in
            do {
                _ = try await runtime.startTurn(sessionID: sessionID, prompt: prompt, clientMessageID: clientMessageID)
            } catch {
                await MainActor.run {
                    failureHandler?(clientMessageID, error.localizedDescription)
                }
            }
        }
        return true
    }

    @discardableResult
    func sendEnter() -> Bool {
        true
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
    func sendResize(cols: Int, rows: Int) -> Bool {
        true
    }

    @discardableResult
    func sendApprovalDecision(approvalID: String, decision: String, message: String?) -> Bool {
        let failureHandler = onSendFailure
        Task { [runtime] in
            do {
                try await runtime.respondToApproval(approvalID: approvalID, decision: decision)
            } catch {
                await MainActor.run {
                    failureHandler?(nil, error.localizedDescription)
                }
            }
        }
        return true
    }

    @discardableResult
    func ping() -> Bool {
        onEvent?(.pong)
        return true
    }

    private static func threadID(from url: URL) -> SessionID? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "thread_id" })?
            .value
    }
}
