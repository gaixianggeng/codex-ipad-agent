import Foundation

// 通知事件、上下文投影、历史消息转换和 server request 映射保持纯内部实现。
extension CodexAppServerSessionRuntime {
    func releaseStaleApprovalRequest(_ request: CodexAppServerServerRequest) {
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
    func staleReleaseDecision(from params: [String: CodexAppServerJSONValue]) -> String {
        let available = (params["availableDecisions"]?.arrayValue ?? []).compactMap { $0.stringValue?.lowercased() }
        for candidate in ["cancel", "reject", "deny", "decline"] where available.contains(candidate) {
            return candidate
        }
        return "decline"
    }

    // 只有仍在活动的通知才算实时信号；表示回合/线程结束或权威状态变化的通知不能算，
    // 否则会把合法的 history 降级也挡掉。
    func recordLiveSignal(from notification: CodexAppServerNotification) {
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

    func hasRecentLiveSignal(sessionID: SessionID) -> Bool {
        guard let at = lastLiveSignalAtBySessionID[sessionID] else {
            return false
        }
        return Date().timeIntervalSince(at) < historyDowngradeGraceInterval
    }

    func emit(_ event: AgentEvent) {
        let sessionID = sessionID(from: event)
        guard let sessionID else {
            return
        }
        if let continuations = eventContinuationsBySessionID[sessionID], !continuations.isEmpty {
            for continuation in continuations.values {
                continuation.yield(event)
            }
        } else {
            bufferedEventsBySessionID[sessionID, default: []].append(event)
        }
    }

    func sessionID(from event: AgentEvent) -> SessionID? {
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
        case .error(_, let metadata):
            return metadata.sessionID
        case .unknown:
            return nil
        }
    }

    func updateContext(from notification: CodexAppServerNotification) {
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

    func backfillActiveTurnFromLiveNotification(
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

    func projectsFromCache() throws -> [AgentProject] {
        guard let config else {
            return []
        }
        return config.projects
    }

    func withUpdatedSession(_ sessionID: SessionID, update: (inout AgentSession) -> Void) -> AgentSession? {
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
    func applyThreadGoal(_ goal: ThreadGoal) -> AgentSession? {
        withUpdatedSession(goal.threadID) { item in
            item.goal = goal
        }
    }

    @discardableResult
    func clearThreadGoalLocal(threadID: SessionID) -> AgentSession? {
        withUpdatedSession(threadID) { item in
            item.goal = nil
        }
    }

    func threadListPage(
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

    func threadSearchPage(
        from result: CodexAppServerJSONValue?,
        projects: [AgentProject]
    ) throws -> ThreadSearchPage {
        guard let object = result?.objectValue,
              let data = object["data"]?.arrayValue
        else {
            throw AgentAPIError.invalidResponse
        }

        var results: [ThreadSearchResult] = []
        results.reserveCapacity(data.count)
        for value in data {
            guard let row = value.objectValue,
                  let thread = row["thread"]?.objectValue,
                  let snippet = row["snippet"]?.stringValue
            else {
                throw AgentAPIError.invalidResponse
            }
            let cwd = thread["cwd"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // thread/search 的最终权限边界在 agentd gateway：它会按 projects/browse_roots 裁剪响应。
            // iOS 不发送 cwd，只拒绝不可能作为会话目录的空值/相对路径；合法 managed worktree
            // 未必已进入 config.projects，不能在这里误删 gateway 已授权的结果。
            guard !cwd.isEmpty, (cwd as NSString).isAbsolutePath else {
                continue
            }
            let session = try agentSession(from: thread, projects: projects, fallbackProject: nil)
            results.append(ThreadSearchResult(session: session, snippet: snippet))
        }
        return ThreadSearchPage(
            results: results,
            nextCursor: object["nextCursor"]?.stringValue,
            backwardsCursor: object["backwardsCursor"]?.stringValue
        )
    }

    func scheduleRateLimitRefreshIfAvailable() {
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

    func finishScheduledRateLimitRefresh() {
        rateLimitRefreshTask = nil
    }

    func refreshRateLimitIfAvailable(force: Bool = false) async -> RateLimitSummary? {
        if !force, let rateLimitRefreshTask {
            return await rateLimitRefreshTask.value
        }
        if force {
            rateLimitRefreshTask?.cancel()
            rateLimitRefreshTask = nil
        }
        return await performRateLimitRefreshIfAvailable()
    }

    func performRateLimitRefreshIfAvailable() async -> RateLimitSummary? {
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

    func refreshRateLimitAfterQuotaError(_ error: Error) async {
        // 瞬时 429 也值得刷新账号状态，但刷新动作本身不等于确认额度耗尽。
        guard CodexQuotaNotice.isRateLimitError(error.localizedDescription) else {
            return
        }
        _ = await refreshRateLimitIfAvailable()
    }

    func applyAccountRateLimit(_ summary: RateLimitSummary) {
        accountRateLimit = summary
        for sessionID in Array(contextsBySessionID.keys) {
            if let session = withUpdatedSession(sessionID, update: { item in
                item.rateLimit = summary
            }) {
                emit(.session(session))
            }
        }
    }

    func threadObject(from result: CodexAppServerJSONValue?) -> [String: CodexAppServerJSONValue]? {
        result?["thread"]?.objectValue
    }

    func threadGoal(from result: CodexAppServerJSONValue?) -> ThreadGoal? {
        if let object = result?["goal"]?.objectValue {
            return ThreadGoal(object: object)
        }
        guard let object = result?.objectValue else {
            return nil
        }
        return ThreadGoal(object: object)
    }

    func agentSession(
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
            title: title.isEmpty ? L10n.text("ui.unnamed_session") : title,
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

    func sessionContext(
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
                label: L10n.text("ui.local"),
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

    func projectFor(cwd: String, projects: [AgentProject]) -> AgentProject? {
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

    func projectsIncludingWorkspace(_ projects: [AgentProject], workspace: AgentWorkspace) -> [AgentProject] {
        var next = projects.filter { $0.id != workspace.id && $0.path != workspace.path }
        next.append(workspace.project)
        return next
    }

    func threadListCWD(for workspace: AgentWorkspace, projects: [AgentProject]) -> String {
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

    func path(_ path: String, isEqualToOrInside rootPath: String) -> Bool {
        path == rootPath || path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
    }

    func standardizedPath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    func projectsIncludingSessionContext(_ projects: [AgentProject], context: CodexAppServerSessionContext) -> [AgentProject] {
        projectsIncludingWorkspace(projects, workspace: AgentWorkspace(
            id: context.session.projectID,
            name: context.session.project,
            path: context.cwd
        ))
    }

    func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return ""
    }

    func firstString(in object: [String: CodexAppServerJSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    func rateLimitSummary(fromPayload value: CodexAppServerJSONValue?) -> RateLimitSummary? {
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

    func rateLimitSummary(fromSnapshot snapshot: [String: CodexAppServerJSONValue]?) -> RateLimitSummary? {
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
            primaryWindowDurationMins: firstInt64(
                in: primary,
                keys: ["windowDurationMins", "window_duration_mins"]
            ).flatMap { Int(exactly: $0) },
            secondaryWindowDurationMins: firstInt64(
                in: secondary,
                keys: ["windowDurationMins", "window_duration_mins"]
            ).flatMap { Int(exactly: $0) },
            hasCredits: firstBool(in: credits, keys: ["hasCredits", "has_credits"]),
            creditsUnlimited: firstBool(in: credits, keys: ["unlimited", "credits_unlimited"]),
            creditBalance: firstString(in: credits ?? [:], keys: ["balance", "credit_balance"]),
            availability: firstString(in: snapshot, keys: ["availability"]),
            unavailableReason: firstString(in: snapshot, keys: ["unavailableReason", "unavailable_reason"])
        )
        if summary.limitID == nil,
           summary.limitName == nil,
           summary.planType == nil,
           summary.reachedType == nil,
           summary.primaryUsedPercent == nil,
           summary.secondaryUsedPercent == nil,
           summary.primaryResetsAt == nil,
           summary.secondaryResetsAt == nil,
           summary.primaryWindowDurationMins == nil,
           summary.secondaryWindowDurationMins == nil,
           summary.hasCredits == nil,
           summary.creditBalance == nil,
           summary.availability == nil,
           summary.unavailableReason == nil {
            return nil
        }
        return summary
    }

    func firstDouble(in object: [String: CodexAppServerJSONValue]?, keys: [String]) -> Double? {
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

    func firstInt64(in object: [String: CodexAppServerJSONValue]?, keys: [String]) -> Int64? {
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

    func firstBool(in object: [String: CodexAppServerJSONValue]?, keys: [String]) -> Bool? {
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

    func sessionStatus(from value: CodexAppServerJSONValue?, forceRunning: Bool) -> String {
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

    func statusContext(threadID: String, statusValue: CodexAppServerJSONValue) -> SessionContextSnapshot {
        SessionContextSnapshot(
            sessionID: threadID,
            threadID: threadID,
            status: contextStatus(from: statusValue, fallbackStatus: sessionStatus(from: statusValue, forceRunning: false)),
            updatedAt: Date()
        )
    }

    func contextStatus(from value: CodexAppServerJSONValue?, fallbackStatus: String) -> SessionContextStatus {
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

    func contextStatusType(from status: String) -> String {
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

    func gitInfo(from object: [String: CodexAppServerJSONValue]?) -> SessionContextGitInfo? {
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

    func contextSources(
        from thread: [String: CodexAppServerJSONValue],
        project: AgentProject?
    ) -> [SessionContextSource] {
        var sources: [SessionContextSource] = []
        if let label = sourceLabel(from: thread["source"]) {
            sources.append(SessionContextSource(id: "session_source", kind: "session", label: label, subtitle: L10n.text("ui.original_source")))
        }
        if let threadSource = nonEmpty(thread["threadSource"]?.stringValue) {
            sources.append(SessionContextSource(id: "thread_source", kind: "thread", label: threadSource, subtitle: L10n.text("ui.thread_source")))
        }
        if let forkedFrom = nonEmpty(thread["forkedFromId"]?.stringValue) {
            sources.append(SessionContextSource(id: "forked_from", kind: "fork", label: String(forkedFrom.prefix(32)), subtitle: L10n.text("ui.fork_source")))
        }
        if sources.isEmpty, let project {
            sources.append(SessionContextSource(id: "project", kind: "project", label: project.name, subtitle: project.path))
        }
        return sources
    }

    func sourceLabel(from value: CodexAppServerJSONValue?) -> String? {
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

    func contextSubagents(
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

    func contextTasks(from thread: [String: CodexAppServerJSONValue]) -> [SessionContextTask] {
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

    func contextTask(
        from item: [String: CodexAppServerJSONValue],
        turn: [String: CodexAppServerJSONValue]
    ) -> SessionContextTask? {
        let id = item["id"]?.stringValue ?? turn["id"]?.stringValue ?? UUID().uuidString
        let status = item["status"]?.stringValue ?? turn["status"]?.stringValue
        switch item["type"]?.stringValue {
        case "commandExecution":
            let title = nonEmpty(item["command"]?.stringValue, item["processId"]?.stringValue, L10n.text("ui.command_execution")) ?? L10n.text("ui.command_execution")
            let subtitle = nonEmpty(item["cwd"]?.stringValue, commandActionSummary(from: item["commandActions"]?.arrayValue))
            return SessionContextTask(id: id, kind: "command", title: String(title.prefix(80)), subtitle: subtitle, status: status)
        case "fileChange":
            let changes = item["changes"]?.arrayValue?.compactMap(\.objectValue) ?? []
            let title = changes.isEmpty ? L10n.text("ui.file_changes") : L10n.plural("ui.files_changed_count", count: changes.count)
            return SessionContextTask(id: id, kind: "file_change", title: title, subtitle: fileChangeSummary(from: changes), status: status)
        case "mcpToolCall":
            let title = nonEmpty(item["tool"]?.stringValue, item["name"]?.stringValue, L10n.text("ui.tool_call")) ?? L10n.text("ui.tool_call")
            let subtitle = nonEmpty(item["server"]?.stringValue, item["namespace"]?.stringValue, item["pluginId"]?.stringValue)
            return SessionContextTask(
                id: id,
                kind: "mcp_tool",
                title: ConversationActivityPayload(item: item)?.displayTitle ?? title,
                subtitle: subtitle,
                status: status
            )
        case "dynamicToolCall":
            let title = nonEmpty(item["tool"]?.stringValue, item["name"]?.stringValue, L10n.text("ui.dynamic_tools")) ?? L10n.text("ui.dynamic_tools")
            let subtitle = nonEmpty(item["pluginId"]?.stringValue, item["namespace"]?.stringValue)
            return SessionContextTask(
                id: id,
                kind: "dynamic_tool",
                title: ConversationActivityPayload(item: item)?.displayTitle ?? title,
                subtitle: subtitle,
                status: status
            )
        case "collabAgentToolCall":
            let title = nonEmpty(item["agentNickname"]?.stringValue, item["nickname"]?.stringValue, item["tool"]?.stringValue, L10n.text("ui.sub_agent")) ?? L10n.text("ui.sub_agent")
            let subtitle = nonEmpty(item["agentRole"]?.stringValue, item["role"]?.stringValue)
            return SessionContextTask(id: id, kind: "subagent", title: title, subtitle: subtitle, status: status)
        case "webSearch":
            let query = nonEmpty(item["query"]?.stringValue, item["action"]?.stringValue)
            let title = query.map { L10n.format("ui.internet_search_value", $0) } ?? L10n.text("ui.web_search")
            return SessionContextTask(id: id, kind: "web_search", title: title, subtitle: nil, status: status)
        default:
            return nil
        }
    }

    func commandActionSummary(from actions: [CodexAppServerJSONValue]?) -> String? {
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

    func fileChangeSummary(from changes: [[String: CodexAppServerJSONValue]]) -> String? {
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

    func activeTurnID(from thread: [String: CodexAppServerJSONValue]) -> TurnID?? {
        guard let turns = thread["turns"]?.arrayValue?.compactMap(\.objectValue) else {
            return nil
        }
        let activeTurnID = turns.last { turn in
            isActiveHistoryStatus(turn["status"])
        }?["id"]?.stringValue
        return .some(activeTurnID)
    }

    func historyMessages(
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

    func historyMessages(
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
            let turnLifecycle = historyTurnLifecycle(
                turn,
                isInProgress: turnIsInProgress,
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
                message = message.withTurnLifecycle(turnLifecycle)
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

    func historyMessage(
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
        case "imageGeneration", "imageView":
            guard let content = ConversationImageItemProjection.markdownContent(from: item) else {
                return nil
            }
            let completed = itemCompletedAt ?? completedAt
            return CodexHistoryMessage(
                id: messageID,
                role: "assistant",
                content: content,
                createdAt: completed ?? itemCreatedAt ?? estimatedAt ?? startedAt,
                updatedAt: completed ?? liveSnapshotUpdatedAt,
                turnID: turnID,
                itemID: itemID,
                timelineOrdinal: timelineOrdinal,
                isTimestampFallback: completed == nil && itemCreatedAt == nil && estimatedAt != nil
            )
        case "agentMessage":
            let text = item["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                return nil
            }
            if item["phase"]?.stringValue == "commentary" {
                // commentary 是面向用户的阶段性正文，不是内部 reasoning。
                return CodexHistoryMessage(id: messageID, role: "assistant", kind: .commentary, content: text, createdAt: processCreatedAt, updatedAt: liveSnapshotUpdatedAt, turnID: turnID, itemID: itemID, timelineOrdinal: timelineOrdinal, isTimestampFallback: processTimestampIsFallback)
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

    func historyTimelineOrdinal(turnIndex: Int, itemIndex: Int) -> Int64 {
        Int64(turnIndex) * 1_000_000 + Int64(itemIndex)
    }

    func isActiveHistoryThread(_ thread: [String: CodexAppServerJSONValue]) -> Bool {
        isActiveHistoryStatus(thread["status"])
    }

    func isInProgressHistoryTurn(
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

    func isActiveHistoryStatus(_ value: CodexAppServerJSONValue?) -> Bool {
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

    func historyTurnLifecycle(
        _ turn: [String: CodexAppServerJSONValue],
        isInProgress: Bool,
        completedAt: Date?
    ) -> ConversationTurnLifecycle {
        if isInProgress {
            return .inProgress
        }
        let raw = turn["status"]?.stringValue
            ?? turn["status"]?.objectValue?["type"]?.stringValue
            ?? turn["status"]?.objectValue?["status"]?.stringValue
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "completed", "complete", "succeeded", "success":
            return .completed
        case "failed", "failure", "systemerror", "system_error":
            return .failed
        case "interrupted", "cancelled", "canceled", "aborted":
            return .interrupted
        default:
            return completedAt == nil ? .unknown : .completed
        }
    }

    func isTerminalHistoryStatus(_ value: CodexAppServerJSONValue?) -> Bool {
        let raw = value?.stringValue
            ?? value?.objectValue?["type"]?.stringValue
            ?? value?.objectValue?["status"]?.stringValue
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "completed", "complete", "succeeded", "success", "failed", "failure", "interrupted", "cancelled", "canceled", "aborted":
            return true
        default:
            return false
        }
    }

    func estimatedHistoryItemDate(startedAt: Date?, completedAt: Date?, itemIndex: Int, itemCount: Int) -> Date? {
        guard let startedAt else {
            return completedAt
        }
        guard let completedAt, completedAt > startedAt, itemCount > 1 else {
            return startedAt.addingTimeInterval(Double(itemIndex) * 0.001)
        }
        let progress = Double(itemIndex) / Double(max(1, itemCount - 1))
        return startedAt.addingTimeInterval(completedAt.timeIntervalSince(startedAt) * progress)
    }

    func isVisibleUserHistoryMessage(_ text: String) -> Bool {
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

    func appServerHistoryMessageID(turnID: TurnID?, itemID: AgentItemID) -> MessageID {
        guard let turnID, !turnID.isEmpty else {
            return itemID
        }
        return "appserver:\(turnID):\(itemID)"
    }

    func userMessageInputs(from item: [String: CodexAppServerJSONValue]) -> [CodexAppServerUserInput] {
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

    func userMessageText(from inputs: [CodexAppServerUserInput]) -> String {
        inputs.compactMap { input in
            if case .text(let text, _) = input {
                return text
            }
            return nil
        }
        .joined(separator: "\n")
    }

    func containsImageInput(_ inputs: [CodexAppServerUserInput]) -> Bool {
        inputs.contains { input in
            switch input {
            case .image, .localImage:
                return true
            case .text, .skill, .mention:
                return false
            }
        }
    }

    func userMessageImageDetail(from object: [String: CodexAppServerJSONValue]) -> CodexAppServerImageDetail? {
        guard let raw = object["detail"]?.stringValue else {
            return nil
        }
        return CodexAppServerImageDetail(rawValue: raw)
    }

    func approvalID(for request: CodexAppServerServerRequest) -> String? {
        let params = request.params?.objectValue ?? [:]
        return params["approvalId"]?.stringValue
            ?? params["itemId"]?.stringValue
            ?? params["item_id"]?.stringValue
            ?? params["callId"]?.stringValue
            ?? request.id.description
    }

    func userInputRequestID(for request: CodexAppServerServerRequest) -> String? {
        let params = request.params?.objectValue ?? [:]
        return params["itemId"]?.stringValue
            ?? params["item_id"]?.stringValue
            ?? params["requestId"]?.stringValue
            ?? params["request_id"]?.stringValue
            ?? request.id.description
    }

    func rememberPendingApprovalRequest(_ request: CodexAppServerServerRequest) {
        guard isApprovalLikeServerRequest(request) else {
            return
        }
        for key in pendingApprovalStorageKeys(for: request) {
            pendingApprovalRequestsByID[key] = request
        }
    }

    func removePendingApprovalRequest(_ request: CodexAppServerServerRequest) {
        for key in pendingApprovalStorageKeys(for: request) {
            pendingApprovalRequestsByID.removeValue(forKey: key)
        }
    }

    func rememberPendingUserInputRequest(_ request: CodexAppServerServerRequest) {
        guard isUserInputServerRequest(request) else {
            return
        }
        for key in pendingUserInputStorageKeys(for: request) {
            pendingUserInputRequestsByID[key] = request
        }
    }

    func removePendingUserInputRequest(_ request: CodexAppServerServerRequest) {
        for key in pendingUserInputStorageKeys(for: request) {
            pendingUserInputRequestsByID.removeValue(forKey: key)
        }
    }

    func clearResolvedServerRequest(from notification: CodexAppServerNotification) -> CodexAppServerResolvedServerRequests {
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

    func clearAllPendingServerRequests() -> CodexAppServerResolvedServerRequests {
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

    func emitApprovalResolved(sessionID: SessionID) {
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

    func emitUserInputResolved(sessionID: SessionID, skipped: Bool) {
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

    func pendingApprovalStorageKeys(for request: CodexAppServerServerRequest) -> [String] {
        let sessionID = approvalSessionID(for: request)
        let ids = uniqueStrings([approvalID(for: request), request.id.description].compactMap { $0 })
        return ids.flatMap { id in
            pendingApprovalLookupKeys(sessionID: sessionID, approvalID: id)
        }
    }

    func pendingApprovalLookupKeys(sessionID: SessionID?, approvalID: String) -> [String] {
        uniqueStrings([
            pendingApprovalScopedKey(sessionID: sessionID, approvalID: approvalID),
            approvalID
        ].compactMap { $0 })
    }

    func pendingApprovalScopedKey(sessionID: SessionID?, approvalID: String) -> String? {
        guard let sessionID, !sessionID.isEmpty else {
            return nil
        }
        return "\(sessionID)#\(approvalID)"
    }

    func pendingUserInputStorageKeys(for request: CodexAppServerServerRequest) -> [String] {
        let sessionID = approvalSessionID(for: request)
        let ids = uniqueStrings([userInputRequestID(for: request), request.id.description].compactMap { $0 })
        return ids.flatMap { id in
            pendingUserInputLookupKeys(sessionID: sessionID, requestID: id)
        }
    }

    func pendingUserInputLookupKeys(sessionID: SessionID?, requestID: String) -> [String] {
        uniqueStrings([
            pendingUserInputScopedKey(sessionID: sessionID, requestID: requestID),
            requestID
        ].compactMap { $0 })
    }

    func pendingUserInputScopedKey(sessionID: SessionID?, requestID: String) -> String? {
        guard let sessionID, !sessionID.isEmpty else {
            return nil
        }
        return "\(sessionID)#\(requestID)"
    }

    func approvalSessionID(for request: CodexAppServerServerRequest) -> SessionID? {
        approvalSessionID(from: request.params?.objectValue ?? [:])
    }

    func approvalTurnID(for request: CodexAppServerServerRequest) -> TurnID? {
        let params = request.params?.objectValue ?? [:]
        return params["turnId"]?.stringValue
            ?? params["turnID"]?.stringValue
            ?? params["turn_id"]?.stringValue
    }

    func approvalSessionID(from params: [String: CodexAppServerJSONValue]) -> SessionID? {
        params["threadId"]?.stringValue
            ?? params["conversationId"]?.stringValue
            ?? params["sessionId"]?.stringValue
            ?? params["session_id"]?.stringValue
    }

    func isApprovalLikeServerRequest(_ request: CodexAppServerServerRequest) -> Bool {
        let lower = request.method.lowercased()
        if lower.contains("approval") {
            return true
        }
        // URL 型 MCP elicitation 没有表单内容，复用明确的批准/拒绝交互更安全。
        return request.method == "mcpServer/elicitation/request"
            && request.params?.objectValue?["mode"]?.stringValue == "url"
    }

    func isUserInputServerRequest(_ request: CodexAppServerServerRequest) -> Bool {
        if request.method == "item/tool/requestUserInput" {
            return true
        }
        // form/openai-form 都投影到现有补充信息卡；未知 mode 也走此路径，
        // 用户没有填入时回 decline，不会误接受无法理解的 MCP 请求。
        return request.method == "mcpServer/elicitation/request"
            && request.params?.objectValue?["mode"]?.stringValue != "url"
    }

    func uniqueStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    func approvalResponse(
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

    func userInputResponse(
        for request: CodexAppServerServerRequest,
        answers: [String: [String]]
    ) -> CodexAppServerJSONValue {
        if request.method == "mcpServer/elicitation/request" {
            return mcpElicitationResponse(request: request, answers: answers)
        }
        return .object([
            "answers": .object(answers.mapValues { values in
                .object([
                    "answers": .array(values.map { .string($0) })
                ])
            })
        ])
    }

    func mcpElicitationResponse(
        request: CodexAppServerServerRequest,
        answers: [String: [String]]
    ) -> CodexAppServerJSONValue {
        guard !answers.isEmpty else {
            // 没有可验证的内容时 fail closed，避免对未知/unsupported schema 误回 accept。
            return .object([
                "action": .string("decline"),
                "content": .null,
                "_meta": .null
            ])
        }

        let schemaProperties = request.params?.objectValue?["requestedSchema"]?
            .objectValue?["properties"]?.objectValue ?? [:]
        let content = answers.reduce(into: [String: CodexAppServerJSONValue]()) { result, entry in
            guard !entry.value.isEmpty else {
                return
            }
            let propertySchema = schemaProperties[entry.key]?.objectValue ?? [:]
            result[entry.key] = mcpElicitationValue(from: entry.value, schema: propertySchema)
        }
        guard !content.isEmpty else {
            return .object(["action": .string("decline"), "content": .null, "_meta": .null])
        }
        return .object([
            "action": .string("accept"),
            "content": .object(content),
            "_meta": .null
        ])
    }

    func mcpElicitationValue(
        from answers: [String],
        schema: [String: CodexAppServerJSONValue]
    ) -> CodexAppServerJSONValue {
        let first = answers[0]
        switch schema["type"]?.stringValue {
        case "array":
            return .array(answers.map { .string($0) })
        case "boolean":
            let normalized = first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Upstream payload values are protocol data, not UI copy. Keep both known
            // Chinese spellings accepted regardless of the device display language.
            return .bool(["true", "1", "yes", "是", "允许"].contains(normalized))
        case "integer":
            return Int64(first).map(CodexAppServerJSONValue.int) ?? .string(first)
        case "number":
            return Double(first).map(CodexAppServerJSONValue.double) ?? .string(first)
        default:
            return .string(first)
        }
    }

    func normalizeApprovalDecision(_ decision: String) -> String {
        switch decision.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "accept", "approve", "approved", "yes":
            return "accept"
        case "acceptforsession", "accept_for_session":
            return "acceptForSession"
        case "acceptwithpermissionupdate", "accept_with_permission_update":
            return "acceptWithPermissionUpdate"
        case "cancel":
            return "cancel"
        default:
            return "decline"
        }
    }

    func metadata(threadID: String, turnID: String?) -> AgentEventMetadata {
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

    func date(from value: CodexAppServerJSONValue?) -> Date? {
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

    func firstDate(in object: [String: CodexAppServerJSONValue], keys: [String]) -> Date? {
        for key in keys {
            if let parsed = date(from: object[key]) {
                return parsed
            }
        }
        return nil
    }

    static func date(from text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Double(trimmed) {
            return date(fromNumericTimestamp: number)
        }
        // app-server 历史在不同版本里可能返回 ISO8601 字符串；解析失败不能兜底成当前时间。
        return iso8601Fractional.date(from: trimmed) ?? iso8601.date(from: trimmed)
    }

    static func date(fromNumericTimestamp value: Double) -> Date? {
        guard value.isFinite, value > 0 else {
            return nil
        }
        // app-server / JSON 桥接历史上出现过秒和毫秒两种数字形态，按数量级兼容。
        let seconds = value > 10_000_000_000 ? value / 1_000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    static func stableHistoryFallbackDate(index: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(max(0, index)) / 1_000)
    }

    static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    func nonEmpty(_ values: String?...) -> String? {
        for value in values {
            let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty {
                return text
            }
        }
        return nil
    }
}
