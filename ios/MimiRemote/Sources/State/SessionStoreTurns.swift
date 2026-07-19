import Foundation

// Runtime 使用量、连接配置、Turn、Goal、审批与队列发送共享同一协调边界。
extension SessionStore {
    func refreshCodexUsage() async {
        await refreshUsage(runtimeProvider: "codex")
    }

    func refreshClaudeUsage() async {
        await refreshUsage(runtimeProvider: "claude")
    }

    func refreshSelectedUsage() async {
        let runtimeProvider = selectedSession.map {
            Self.normalizedRuntimeProvider($0.runtimeProvider ?? $0.source)
        } ?? "codex"
        await refreshUsage(runtimeProvider: runtimeProvider)
    }

    func refreshUsage(runtimeProvider: String) async {
        do {
            let normalizedProvider = Self.normalizedRuntimeProvider(runtimeProvider)
            let summary = try await clientFactory().refreshRateLimit(runtimeProvider: normalizedProvider)
            guard let summary else {
                return
            }
            accountRateLimitsByRuntime[normalizedProvider] = summary
            if var session = selectedSession,
               Self.normalizedRuntimeProvider(session.runtimeProvider ?? session.source) == normalizedProvider {
                session.rateLimit = summary
                upsert(session)
            }
            // 账号接口是当前额度的权威结果。健康快照到达后，清理之前由瞬时
            // 429、过期错误文案等留下的额度告警，让输入框立即恢复可发送。
            if !summary.isExhausted,
               let errorMessage,
               CodexQuotaNotice.isRateLimitError(errorMessage) {
                setErrorMessage(nil)
            }
        } catch {
            setErrorMessage(error.localizedDescription)
        }
    }

    func refreshCurrentContext() async {
#if DEBUG
        guard !isDebugWorkbenchUISeedActive else {
            setStatusMessage(L10n.text("ui.debug_ui_sample_will_not_connect_to_the"))
            return
        }
#endif
        guard let session = selectedSession else {
            await refreshAll(autoAttach: false)
            return
        }
        await refreshSelectedSessionContent(session)
    }

    func loadFullHistoryForSelectedSession() async {
        guard let session = selectedSession else {
            return
        }
        await refreshSelectedSessionContent(session, successStatusMessage: L10n.text("ui.full_history_loaded"), reason: .manualFull)
    }

    func loadSummaryHistoryForSelectedSession() async {
        guard let session = selectedSession else {
            return
        }
        _ = await loadHistory(
            for: session,
            quiet: false,
            loadMode: .economy,
            force: true,
            reason: .summaryChoice,
            successStatusMessage: L10n.text("ui.thumbnail_history_loaded")
        )
    }

    func dismissSelectedHistorySavingsNotice() {
        if let selectedSessionID {
            historySavingsNoticesBySessionID.removeValue(forKey: selectedSessionID)
        }
    }

    func dismissErrorMessage() {
        setErrorMessage(nil)
    }

    func refreshAppServerModelOptions(force: Bool = false) async {
        if isRefreshingAppServerModels {
            return
        }

        isRefreshingAppServerModels = true
        defer { isRefreshingAppServerModels = false }
        var didRefreshRuntimeAvailability = false
        do {
            let client = try clientFactory()
            // Claude 卡片以 config.channels 的真实可用性为准，不能依赖 model/list 是否成功。
            // 即使模型列表处于 5 分钟缓存期，也要重新读取轻量 channel 元数据。
            isClaudeRuntimeChannelAvailable = (try? await client.runtimeChannelAvailable(runtimeProvider: "claude")) == true
            didRefreshRuntimeAvailability = true
            if !force,
               !appServerModelOptions.isEmpty,
               let appServerModelOptionsLastRefresh,
               Date().timeIntervalSince(appServerModelOptionsLastRefresh) < 300 {
                return
            }
            let options = try await client.modelOptions()
            appServerModelOptionsLastRefresh = Date()
            if !options.isEmpty || force {
                appServerModelOptions = options
            }
            if force {
                setStatusMessage(options.isEmpty ? L10n.text("ui.app_server_model_list_not_found_continue_using") : L10n.text("ui.model_list_refreshed"))
            }
        } catch {
            if !didRefreshRuntimeAvailability {
                isClaudeRuntimeChannelAvailable = false
            }
            appServerModelOptionsLastRefresh = Date()
            if force {
                setStatusMessage(L10n.text("ui.model_list_unavailable_continue_using_built_in_options"))
            }
        }
    }

    func payloadResolvingRequiredModel(_ payload: CodexAppServerTurnPayload) async -> CodexAppServerTurnPayload {
        var resolved = payload
        let lockedRuntimeProvider = selectedSessionRuntimeProviderForTurn()
        if let lockedRuntimeProvider {
            let requestedRuntimeProvider = Self.normalizedRuntimeProvider(resolved.options.runtimeProvider)
            if requestedRuntimeProvider != lockedRuntimeProvider {
                // 已有会话的 thread 授权只属于创建它的 runtime。历史 Codex/Claude 会话里如果残留了
                // 另一条渠道的模型选择，必须清掉并回到当前会话 runtime 的默认模型，避免 resume 到错误 gateway。
                resolved.options.runtimeProvider = Self.payloadRuntimeProvider(lockedRuntimeProvider)
                resolved.options.model = nil
                resolved.options.modelProvider = nil
            } else if resolved.options.runtimeProvider?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                resolved.options.runtimeProvider = Self.payloadRuntimeProvider(lockedRuntimeProvider)
            }
        }
        if let model = resolved.options.model?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            resolved.options = resolved.options.sanitizedForRuntimePolicy()
            return resolved
        }

        if appServerModelOptions.isEmpty {
            await refreshAppServerModelOptions()
        }
        let allOptions = appServerModelOptions.isEmpty ? CodexAppServerModelOption.builtInFallback : appServerModelOptions
        let targetRuntimeProvider = lockedRuntimeProvider ?? Self.explicitRuntimeProvider(resolved.options.runtimeProvider)
        let options = targetRuntimeProvider.map { runtimeProvider in
            allOptions.filter { Self.normalizedRuntimeProvider($0.runtimeProvider) == runtimeProvider }
        } ?? allOptions
        let candidateOptions: [CodexAppServerModelOption]
        if options.isEmpty, targetRuntimeProvider == "claude" {
            candidateOptions = CodexAppServerModelOption.builtInClaudeFallback
        } else if options.isEmpty, targetRuntimeProvider == "codex" {
            candidateOptions = CodexAppServerModelOption.builtInFallback
        } else {
            candidateOptions = options.isEmpty ? allOptions : options
        }
        guard let selected = candidateOptions.first(where: \.isDefault) ?? candidateOptions.first else {
            resolved.options = resolved.options.sanitizedForRuntimePolicy()
            return resolved
        }

        // app-server 的 turn/start 目前要求顶层 model 必填；模型来源必须优先使用
        // model/list 的账号默认值，只有列表不可用时才使用内置兜底，避免 iPad 硬编码旧模型踩 rollout。
        if resolved.options.runtimeProvider?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            resolved.options.runtimeProvider = Self.payloadRuntimeProvider(Self.normalizedRuntimeProvider(selected.runtimeProvider))
        }
        resolved.options.model = selected.model
        resolved.options.modelProvider = selected.provider
        resolved.options = resolved.options.sanitizedForRuntimePolicy()
        return resolved
    }

    func selectedSessionRuntimeProviderForTurn() -> String? {
        guard let session = selectedSession else {
            return nil
        }
        if session.source == "local", session.runtimeProvider == nil {
            return nil
        }
        return Self.normalizedRuntimeProvider(session.runtimeProvider ?? session.source)
    }

    static func explicitRuntimeProvider(_ rawValue: String?) -> String? {
        guard rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return normalizedRuntimeProvider(rawValue)
    }

    static func normalizedRuntimeProvider(_ rawValue: String?) -> String {
        CodexAppServerSessionRuntime.normalizedRuntimeProvider(rawValue)
    }

    func unsubscribeThreadInBackground(_ threadID: SessionID) {
        Task { [weak self] in
            guard let self else { return }
            // unsubscribe 只释放当前 app-server 连接的订阅，不中断后台运行中的 Turn。
            // 生命周期清理失败不应阻塞会话切换；断线后连接关闭仍会回收上游状态。
            _ = try? await self.clientFactory().unsubscribeThread(threadID: threadID)
        }
    }

    static func payloadRuntimeProvider(_ normalizedRuntimeProvider: String) -> String? {
        normalizedRuntimeProvider == "codex" ? nil : normalizedRuntimeProvider
    }

    func refreshCapabilities() async {
        if isRefreshingCapabilities {
            return
        }
        let path = selectedCommandActionPath?.trimmingCharacters(in: .whitespacesAndNewlines)

        isRefreshingCapabilities = true
        defer { isRefreshingCapabilities = false }
        do {
            let response = try await clientFactory().capabilities(path: path?.isEmpty == true ? nil : path)
            capabilityList = response
            capabilityErrorMessage = nil
        } catch {
            capabilityErrorMessage = error.localizedDescription
        }
    }

    func loadEarlierHistoryForSelectedSession() async {
        guard let session = selectedSession,
              let cursor = historyPreviousCursorBySessionID[session.id],
              canLoadEarlierHistory(sessionID: session.id),
              !loadingEarlierHistorySessionIDs.contains(session.id)
        else {
            return
        }
        loadingEarlierHistorySessionIDs.insert(session.id)
        setHistoryLoadProgress(sessionID: session.id, title: L10n.text("ui.load_older_messages"), fraction: 0.18)
        defer {
            loadingEarlierHistorySessionIDs.remove(session.id)
            clearHistoryLoadProgress(sessionID: session.id)
        }
        do {
            let client = try clientFactory()
            setHistoryLoadProgress(sessionID: session.id, title: L10n.text("ui.request_history_paging"), fraction: 0.42)
            let page = try await client.messagesPage(
                sessionID: session.id,
                before: cursor,
                limit: historyLoadedQualityBySessionID[session.id] == .summary ? economyHistoryPageLimit : fullHistoryPageLimit,
                loadMode: historyLoadedQualityBySessionID[session.id] == .summary ? .economy : .full
            )
            setHistoryLoadProgress(sessionID: session.id, title: L10n.text("ui.parse_historical_messages"), fraction: 0.76)
            ingestHistoryContext(page.context, fallbackSessionID: session.id)
            conversationStore.setHistory(
                page.messages,
                sessionID: session.id,
                authoritativeCompletedTurnItems: page.authoritativeCompletedTurnItems
            )
            setHistoryLoadProgress(sessionID: session.id, title: L10n.text("ui.update_interface"), fraction: 0.94)
            updateHistoryPageState(sessionID: session.id, page: page, preserveExistingCursorOnEmptyPage: false)
            setErrorMessage(nil)
        } catch {
            setErrorMessage(error.localizedDescription)
        }
    }

    func returnToSessionList() {
        let wasAlreadyOnList = selectedSessionID == nil
            && errorMessage == nil
            && connectedSessionID == nil
            && webSocket == nil
            && webSocketStatus == .disconnected
            && pendingApprovalDecisionIDsBySessionID.isEmpty
            && pendingUserInputResponseIDsBySessionID.isEmpty
            && pendingUserInputRequestsBySessionID.isEmpty
        guard !wasAlreadyOnList else {
            return
        }
        let previousSession = selectedSession
        setSelectedSessionID(nil)
        setErrorMessage(nil)
        disconnectWebSocket()
        if let previousSession, supportsCodexThreadManagement(previousSession) {
            if queuedRunningTurnsBySessionID[previousSession.id]?.isEmpty == false {
                ensureQueuedSessionMonitoring(sessionID: previousSession.id)
            } else {
                unsubscribeThreadInBackground(previousSession.id)
            }
        }
    }

    func resetConnectionForSettingsChange(clearData: Bool = false) {
        invalidatePreparedConnectionChange()
        connectionTermination = nil
        appLifecycleSuspendedSessionID = nil
        networkSuspendedSessionID = nil
        disconnectWebSocket()
        if clearData {
            if !appStore.isConfigured, let profileID = currentQueuedTurnProfileID {
                do {
                    try queuedTurnStore.remove(profileID: profileID)
                    queuedTurnStorageErrorMessage = nil
                } catch {
                    reportQueuedTurnStorageError(error)
                }
            }
            clearConnectionData()
        }
        setErrorMessage(nil)
        setStatusMessage(nil)
    }

    @discardableResult
    func applyConnectionSettings(
        endpoint: String,
        token: String
    ) async throws -> Bool {
        try await performPreparedConnectionChange {
            try await appStore.prepareConnectionSettings(
                endpoint: endpoint,
                token: token
            )
        }
    }

    @discardableResult
    func addConnectionProfile(
        endpoint: String,
        token: String,
        displayName: String
    ) async throws -> Bool {
        try await performPreparedConnectionChange {
            try await appStore.prepareNewConnectionProfile(
                endpoint: endpoint,
                token: token,
                displayName: displayName
            )
        }
    }

    @discardableResult
    func switchConnectionProfile(id: String) async throws -> Bool {
        // 切换前完整验证目标 Mac；只有验证和 Keychain/元数据提交都成功，
        // commitPreparedConnection 才会退役旧 WebSocket 并清理旧 Mac 的会话数据。
        try await performPreparedConnectionChange {
            try await appStore.prepareConnectionProfileSwitch(id: id)
        }
    }

    func deleteConnectionProfile(id: String) throws {
        try appStore.deleteConnectionProfile(id: id)
        do {
            try queuedTurnStore.remove(profileID: id)
            queuedTurnStorageErrorMessage = nil
        } catch {
            // 档案凭据已经按 AppStore 的事务边界删除；本地队列清理失败不回滚凭据，
            // 只显式提示残留，避免界面误以为 Mac 连接仍然存在。
            reportQueuedTurnStorageError(error)
        }
    }

    @discardableResult
    func applyPairingURL(_ url: URL) async throws -> Bool {
        try await performPreparedConnectionChange {
            try await appStore.preparePairingURL(url)
        }
    }

    @discardableResult
    func addConnectionProfile(pairingURL url: URL, displayName: String) async throws -> Bool {
        try await performPreparedConnectionChange {
            try await appStore.prepareNewPairingURL(url, displayName: displayName)
        }
    }

    /// 串行化所有“验证新凭据后提交”的入口。该方法保持 internal 是为了让 XCTest 能用
    /// 可控 prepare 闭包确定性复现取消/并发，不把测试钩子带进线上分支。
    @discardableResult
    func performPreparedConnectionChange(
        _ prepare: () async throws -> PreparedConnectionSettings
    ) async throws -> Bool {
        let operationGeneration = try beginPreparedConnectionChange()
        let previousStatus = appStore.connectionStatus
        let previousError = appStore.lastError
        let previousDuration = appStore.lastConnectionTestDurationMillis
        let previousReport = appStore.lastConnectionTestReport
        let previousRecentReports = appStore.recentConnectionTestReports
        let previousSessionTermination = connectionTermination
        let previousAppTermination = appStore.connectionTermination
        defer { finishPreparedConnectionChange(operationGeneration) }

        do {
            let prepared = try await prepare()
            try Task.checkCancellation()
            guard operationGeneration == connectionChangeGeneration,
                  inFlightConnectionChangeGeneration == operationGeneration,
                  !isAppInBackground else {
                throw CancellationError()
            }
            return try commitPreparedConnection(prepared)
        } catch {
            // 失败时恢复验证前的展示状态，但若等待期间旧 WS 已进入鉴权终态，必须保留
            // 新终态；否则一次失败的切换会把“访问码已失效”错误覆盖回已连接。
            if connectionTermination == previousSessionTermination,
               appStore.connectionTermination == previousAppTermination {
                appStore.connectionStatus = previousStatus
                appStore.lastError = previousError
                appStore.lastConnectionTestDurationMillis = previousDuration
                appStore.lastConnectionTestReport = previousReport
                appStore.recentConnectionTestReports = previousRecentReports
            }
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            throw error
        }
    }

    func beginPreparedConnectionChange() throws -> Int {
        guard !isAppInBackground else {
            throw CancellationError()
        }
        guard inFlightConnectionChangeGeneration == nil else {
            throw ConnectionProfileError.operationInProgress
        }
        connectionChangeGeneration += 1
        inFlightConnectionChangeGeneration = connectionChangeGeneration
        return connectionChangeGeneration
    }

    func finishPreparedConnectionChange(_ generation: Int) {
        guard inFlightConnectionChangeGeneration == generation else { return }
        inFlightConnectionChangeGeneration = nil
    }

    func invalidatePreparedConnectionChange() {
        // 不提前释放占用：旧 prepare 可能仍在网络回调中。等它返回并在提交门前发现代次失效，
        // 才允许下一项操作开始，避免两个 validateConnection 同时改写 AppStore 状态。
        connectionChangeGeneration += 1
    }

    func commitPreparedConnection(_ prepared: PreparedConnectionSettings) throws -> Bool {
        // 必须先原子提交 Keychain/endpoint，再退役旧连接。若 Keychain 写入失败，
        // 旧 WebSocket、runtime bundle、connectionGeneration 和当前会话数据都保持不变。
        let didChange = try appStore.commitConnectionSettings(prepared)
        connectionTermination = nil
        appLifecycleSuspendedSessionID = nil
        networkSuspendedSessionID = nil
        disconnectWebSocket()
        if didChange {
            clearConnectionData()
            reloadQueuedTurns()
        }
        setErrorMessage(nil)
        setStatusMessage(nil)
        return didChange
    }

    /// 打开本地通知对应会话。安全边界：只允许当前 profile，最多做一次有界首屏刷新，绝不自动切 Mac。
    func openSessionFromNotification(_ route: SessionNotificationRoute) async -> SessionNotificationOpenOutcome {
        let activeProfileID = appStore.notificationRoutingProfileID
        guard route.profileID == activeProfileID else {
            let profileName = appStore.connectionProfiles
                .first(where: { $0.id == route.profileID })?
                .displayName
            let message: String
            if let profileName {
                message = L10n.format("ui.the_notification_comes_from_value_please_switch_the", profileName)
            } else {
                message = L10n.text("ui.the_notification_comes_from_another_mac_please_switch")
            }
            setStatusMessage(message)
            return .requiresProfileSwitch(displayName: profileName)
        }

        let connectionGeneration = appStore.connectionGeneration
        var targetSession = sessionsByID[route.sessionID]
        if let targetSession, targetSession.projectID != route.projectID {
            // 同一 sessionID 却指向不同项目属于畸形或过期路由，不猜测、不发请求。
            return .ignored
        }

        if targetSession == nil {
            do {
                targetSession = try await refreshSessionForNotification(
                    route,
                    connectionGeneration: connectionGeneration
                )
                if targetSession == nil {
                    guard connectionGeneration == appStore.connectionGeneration,
                          route.profileID == appStore.notificationRoutingProfileID else {
                        return .ignored
                    }
                    let message = L10n.text("ui.the_session_corresponding_to_the_notification_is_temporarily")
                    setStatusMessage(message)
                    return .unavailable(message: message)
                }
            } catch {
                if terminateConnectionIfCredentialsInvalid(error) {
                    return .unavailable(message: L10n.text("ui.the_current_connection_credentials_have_expired_please_re"))
                }
                let message = L10n.text("ui.the_session_corresponding_to_the_notification_cannot_be")
                setStatusMessage(message)
                return .unavailable(message: message)
            }
        }

        guard connectionGeneration == appStore.connectionGeneration,
              route.profileID == appStore.notificationRoutingProfileID,
              let targetSession,
              targetSession.id == route.sessionID,
              targetSession.projectID == route.projectID
        else {
            return .ignored
        }

        await selectSession(targetSession)
        guard connectionGeneration == appStore.connectionGeneration,
              route.profileID == appStore.notificationRoutingProfileID,
              selectedSessionID == route.sessionID
        else {
            return .ignored
        }
        return .opened
    }

    func refreshSessionForNotification(
        _ route: SessionNotificationRoute,
        connectionGeneration: Int
    ) async throws -> AgentSession? {
        let client = try clientFactory()
        var workspace = ensureWorkspaceForKnownProjectID(route.projectID)

        if workspace == nil {
            // 冷启动时项目索引可能尚未建立；只补一次项目元数据，不进入 bootstrap 的循环重试。
            let fetchedProjects = try await client.projects()
            guard connectionGeneration == appStore.connectionGeneration,
                  route.profileID == appStore.notificationRoutingProfileID else {
                return nil
            }
            setProjectsIfChanged(fetchedProjects)
            reloadRecentWorkspaces()
            workspace = ensureWorkspaceForKnownProjectID(route.projectID)
        }

        guard let workspace else {
            return nil
        }
        // 用 workspace 首屏建立 Codex/Claude 的真实 runtime 路由；不盲猜 provider，也不自动翻页循环。
        let page = try await client.sessionsPage(
            workspace: workspace,
            cursor: nil,
            limit: Self.initialSessionPageLimit
        )
        guard connectionGeneration == appStore.connectionGeneration,
              route.profileID == appStore.notificationRoutingProfileID else {
            return nil
        }
        let refreshedSessions = sessions(page.sessions, in: workspace)
        mergeSessionPage(refreshedSessions)
        updateSessionPageState(projectID: workspace.id, page: page)
        clearWorkspaceUnavailable(workspace.id)

        guard let target = sessionsByID[route.sessionID],
              target.projectID == route.projectID else { return nil }
        return target
    }

    func selectSession(_ session: AgentSession) async {
        if isNoOpHistorySelection(session) {
            return
        }
        let previousSession = selectedSession
        let session = sessionForExplicitSelection(session)
        setSelectedProjectID(session.projectID)
        setSelectedSessionID(session.id)
        if let previousSession,
           previousSession.id != session.id,
           supportsCodexThreadManagement(previousSession) {
            if queuedRunningTurnsBySessionID[previousSession.id]?.isEmpty == false {
                ensureQueuedSessionMonitoring(sessionID: previousSession.id)
            } else {
                unsubscribeThreadInBackground(previousSession.id)
            }
        }
        stopQueuedSessionMonitoring(sessionID: session.id)
        revealProjectInSidebar(session.projectID)
        setErrorMessage(nil)
        conversationStore.retainSessionCache(sessionID: session.id)
        logStore.retainSessionCache(sessionID: session.id)
#if DEBUG
        guard !isDebugWorkbenchUISeedActive else {
            setStatusMessage(L10n.format("ui.debug_session_value_selected", session.title))
            return
        }
#endif

        if session.isRunning && canControlSession(session) {
            // 重新点回运行会话时，离开期间的输出先用 thread/read 快照一次性补齐；
            // 随后的 WebSocket 只回放状态级 backlog，避免消息区把旧 delta 逐条直播。
            let didRefreshHistory = await loadHistory(for: session)
            connectWebSocket(session, replayBufferedEvents: !didRefreshHistory)
        } else if session.isRunning {
            // 其他客户端正在运行：只读观察，不建立可发送的事件通道。
            await loadHistoryIfNeeded(for: session)
            disconnectWebSocket()
        } else {
            // 非运行会话有两种可能：真历史，或被瞬时 idle 误读降级的运行会话。
            // 已有缓存时先展示缓存、后台静默补一次最新页；同时仍建立事件订阅——
            // thread/resume 的权威状态能立即纠正误判，之后的 turn 事件也能直接推进来，
            // 不再要求手动刷新。
            let didRefreshHistory: Bool
            if conversationStore.hasLoadedHistory(sessionID: session.id) {
                scheduleQuietHistoryRefresh(for: session)
                didRefreshHistory = true
            } else {
                didRefreshHistory = await loadHistoryIfNeeded(for: session)
            }
            connectWebSocket(session, replayBufferedEvents: !didRefreshHistory, allowNonRunning: true)
        }
    }

    // 新建会话在点击瞬间就急切创建空线程并绑定 runtime；不传 runtimeProvider 时由默认模型
    // 决定（当前是 Codex）。要开 Claude 会话必须在这里显式指定，事后无法把线程迁到另一条通道。
    func startNewSession(runtimeProvider: String? = nil) async {
        guard let selectedProjectID else {
            setErrorMessage(L10n.text("ui.please_select_the_project_first"))
            return
        }
        await createSession(projectID: selectedProjectID, prompt: "", resume: nil, runtimeProvider: runtimeProvider)
    }

    func startNewSession(in project: AgentProject, runtimeProvider: String? = nil) async {
        let workspace = ensureWorkspace(for: project)
        setSelectedProjectID(workspace.id)
        setSelectedSessionID(nil)
        insertExpandedProjectID(workspace.id)
        setErrorMessage(nil)
        disconnectWebSocket()
        await createSession(projectID: workspace.id, prompt: "", resume: nil, runtimeProvider: runtimeProvider)
    }

    var hasClaudeRuntimeChannel: Bool {
        isClaudeRuntimeChannelAvailable
            || appServerModelOptions.contains { Self.normalizedRuntimeProvider($0.runtimeProvider) == "claude" }
            || sessions.contains { Self.normalizedRuntimeProvider($0.runtimeProvider ?? $0.source) == "claude" }
    }

    @discardableResult
    func sendPrompt(_ text: String) async -> Bool {
        await sendTurn(CodexAppServerTurnPayload(prompt: text))
    }

    @discardableResult
    func startGoalTurn(
        payload: CodexAppServerTurnPayload,
        objective: String,
        tokenBudget: Int64? = nil,
        runningDelivery: RunningTurnDelivery = .queued
    ) async -> Bool {
        let normalizedObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedObjective.isEmpty else {
            threadGoalErrorMessage = L10n.text("ui.target_content_cannot_be_empty")
            return false
        }
        if let tokenBudget, tokenBudget <= 0 {
            threadGoalErrorMessage = L10n.text("ui.token_budget_must_be_greater_than_0")
            return false
        }
        threadGoalErrorMessage = nil
        if let notice = selectedQuotaNotice, notice.blocksSending {
            setErrorMessage(notice.message)
            return false
        }

        if let session = selectedSession, session.isRunning {
            // 排队目标必须把“设置目标 + 启动 turn”作为同一个本地队列项保存；
            // 若在这里提前写远端目标，App 被挂起时会留下“目标已改、任务没发”的半完成状态。
            if runningDelivery == .queued {
                let sent = await sendTurn(
                    payload,
                    runningDelivery: .queued,
                    queuedIntent: .goal(objective: normalizedObjective, tokenBudget: tokenBudget)
                )
                if sent {
                    setStatusMessage(L10n.text("ui.the_target_task_has_been_added_to_be"))
                }
                return sent
            }

            guard readyWebSocket(for: session) != nil,
                  await setThreadGoal(
                    threadID: session.id,
                    objective: normalizedObjective,
                    status: .active,
                    tokenBudget: tokenBudget
                  ) else {
                return false
            }
            let sent = await sendTurn(
                payload,
                runningDelivery: .guided
            )
            if sent {
                setStatusMessage(L10n.text("ui.the_target_task_has_been_started"))
            }
            return sent
        }

        let resume = selectedSession
        let projectID = resume?.projectID ?? selectedProjectID
        guard let projectID else {
            setErrorMessage(L10n.text("ui.please_select_the_project_first"))
            return false
        }
        let started = await createSession(
            projectID: projectID,
            payload: payload,
            resume: resume,
            clientMessageID: UUID().uuidString,
            initialGoalObjective: normalizedObjective
        )
        if started {
            setStatusMessage(L10n.text("ui.the_target_task_has_been_started"))
        }
        return started
    }

    func transcribeVoice(filename: String, contentType: String, audioData: Data, language: String?) async throws -> VoiceTranscriptionResponse {
        try await clientFactory().transcribeVoice(
            filename: filename,
            contentType: contentType,
            audioData: audioData,
            language: language
        )
    }

    @discardableResult
    func sendTurn(
        _ payload: CodexAppServerTurnPayload,
        runningDelivery: RunningTurnDelivery = .queued,
        queuedIntent: QueuedTurnIntent? = nil
    ) async -> Bool {
        guard !payload.isEmpty else {
            return false
        }
        if let notice = selectedQuotaNotice, notice.blocksSending {
            setErrorMessage(notice.message)
            return false
        }
        let payload = runningDelivery == .queued ? await payloadResolvingRequiredModel(payload) : payload
        let prompt = payload.previewText

        let selectedSessionHasQueuedTurns = selectedSession.map {
            queuedRunningTurnsBySessionID[$0.id]?.isEmpty == false
        } ?? false
        if let session = selectedSession,
           session.isRunning || (runningDelivery == .queued && selectedSessionHasQueuedTurns) {
            guard canControlSession(session) else {
                setErrorMessage(L10n.text("ui.this_session_is_running_on_another_client_please_c95578ac"))
                return false
            }
            let clientMessageID = UUID().uuidString
            if runningDelivery == .queued {
                let queueCount = queuedRunningTurnsBySessionID[session.id]?.count ?? 0
                guard queueCount < Self.queuedTurnLimitPerSession else {
                    setErrorMessage(L10n.format("ui.each_session_retains_a_maximum_of_value_messages", Self.queuedTurnLimitPerSession))
                    return false
                }
                let intent = queuedIntent ?? (payload.options.collaborationMode == .plan ? .plan : .standard)
                let item = QueuedTurnEntry(
                    sessionID: session.id,
                    projectID: session.projectID,
                    payload: payload,
                    clientMessageID: clientMessageID,
                    intent: intent,
                    expectedTurnID: session.activeTurnID
                )
                guard mutateAndPersistQueuedTurns({
                    queuedRunningTurnsBySessionID[session.id, default: []].append(item)
                }) else {
                    return false
                }
                setStatusMessage(session.activeTurnID == nil ? L10n.text("ui.saved_to_this_machine_and_preparing_to_send") : L10n.text("ui.saved_to_this_machine_and_will_be_sent"))
                ensureQueuedSessionMonitoring(sessionID: session.id)
                dispatchNextQueuedRunningTurnIfIdle(sessionID: session.id)
                return true
            }

            guard let socket = readyWebSocket(for: session) else {
                return false
            }
            conversationStore.appendLocalUser(
                prompt,
                sessionID: session.id,
                clientMessageID: clientMessageID,
                sendStatus: .sending,
                turnPayload: payload,
                userDelivery: .guided
            )
            setSessionListProjection(sessionID: session.id, preview: prompt, source: .localUser, clientMessageID: clientMessageID)
            setForegroundActivity(.waitingForAssistant, sessionID: session.id)
            guard let activeTurnID = session.activeTurnID else {
                conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: session.id, status: .failed)
                clearSessionListProjection(sessionID: session.id, clientMessageID: clientMessageID)
                clearForegroundActivity(sessionID: session.id)
                setErrorMessage(L10n.text("ui.failed_to_guide_conversation_there_is_no_active"))
                return false
            }
            let didAcceptLocally = socket.sendGuidance(payload, clientMessageID: clientMessageID, expectedTurnID: activeTurnID)
            guard didAcceptLocally else {
                conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: session.id, status: .failed)
                clearSessionListProjection(sessionID: session.id, clientMessageID: clientMessageID)
                clearForegroundActivity(sessionID: session.id)
                setErrorMessage(L10n.text("ui.sending_failed_websocket_not_connected"))
                return false
            }
            // 只有后端通道接受首个 turn 后才解除 fresh-empty 保护；本地发送失败时 thread 仍无 rollout。
            freshEmptyHistorySignatureBySessionID.removeValue(forKey: session.id)
            return true
        }

        let resume = selectedSession
        let projectID = resume?.projectID ?? selectedProjectID
        guard let projectID else {
            setErrorMessage(L10n.text("ui.please_select_the_project_first"))
            return false
        }
        return await createSession(projectID: projectID, payload: payload, resume: resume, clientMessageID: UUID().uuidString)
    }

    func dispatchNextQueuedRunningTurnIfIdle(sessionID: SessionID) {
        guard let session = sessionsByID[sessionID],
              !queuedTurnAwaitingStartSessionIDs.contains(sessionID),
              session.activeTurnID == nil,
              let next = queuedRunningTurnsBySessionID[sessionID]?.first,
              next.dispatchState == .waiting,
              next.waitsForAcceptedTurnStart != true,
              next.expectedTurnID == nil
        else {
            return
        }
        guard canControlSession(session) else {
            setStatusMessage(L10n.text("ui.message_to_be_sent_is_waiting_please_take"))
            return
        }
        guard let socket = socketForQueuedDispatch(sessionID: sessionID) else {
            ensureQueuedSessionMonitoring(sessionID: sessionID)
            return
        }

        guard mutateAndPersistQueuedTurns({
            guard var queue = queuedRunningTurnsBySessionID[sessionID], !queue.isEmpty else { return }
            queue[0].dispatchState = .dispatching
            queue[0].lastAttemptAt = Date()
            queue[0].lastError = nil
            queuedRunningTurnsBySessionID[sessionID] = queue
        }) else {
            return
        }

        if case .goal(let objective, let tokenBudget) = next.intent {
            Task { @MainActor [weak self, socket] in
                guard let self else { return }
                guard await self.setThreadGoal(
                    threadID: sessionID,
                    objective: objective,
                    status: .active,
                    tokenBudget: tokenBudget
                ) else {
                    self.markQueuedTurnWaitingAfterDefiniteFailure(
                        clientMessageID: next.clientMessageID,
                        message: L10n.text("ui.target_setup_failed_and_has_not_been_sent")
                    )
                    return
                }
                self.performQueuedTurnSend(next, session: session, socket: socket)
            }
        } else {
            performQueuedTurnSend(next, session: session, socket: socket)
        }
    }

    func performQueuedTurnSend(
        _ item: QueuedTurnEntry,
        session: AgentSession,
        socket: any SessionWebSocketClient
    ) {
        guard queuedTurnLocation(clientMessageID: item.clientMessageID) != nil else { return }
        setForegroundActivity(.waitingForAssistant, sessionID: session.id)

        queuedTurnAwaitingStartSessionIDs.insert(session.id)
        guard socket.sendTurn(item.payload, clientMessageID: item.clientMessageID) else {
            queuedTurnAwaitingStartSessionIDs.remove(session.id)
            markQueuedTurnWaitingAfterDefiniteFailure(
                clientMessageID: item.clientMessageID,
                message: L10n.text("ui.the_connection_is_not_ready_yet_the_message")
            )
            clearForegroundActivity(sessionID: session.id)
            return
        }

        // 只有传输层接受 turn/start 后才进入 timeline；纯本地等待项只在输入框上方的队列托盘展示。
        conversationStore.appendLocalUser(
            item.previewText,
            sessionID: session.id,
            clientMessageID: item.clientMessageID,
            sendStatus: .sending,
            turnPayload: item.payload,
            userDelivery: .queued
        )
        setSessionListProjection(
            sessionID: session.id,
            preview: item.previewText,
            source: .localUser,
            clientMessageID: item.clientMessageID
        )

        // turn/started 可能稍后才到；先把本地状态推进为 running，避免窗口期重复派发下一项。
        locallyCompletedSessionIDs.remove(session.id)
        updateSession(session.id) { item in
            item.status = SessionStatus.running.rawValue
            item.pendingApproval = nil
            item.pendingUserInput = nil
        }
        contextStore.updateStatus(sessionID: session.id, status: SessionStatus.running.rawValue)
        freshEmptyHistorySignatureBySessionID.removeValue(forKey: session.id)
        setStatusMessage(L10n.text("ui.the_queued_message_has_been_sent_waiting_for"))
    }

    func markQueuedTurnWaitingAfterDefiniteFailure(
        clientMessageID: ClientMessageID,
        message: String
    ) {
        guard let location = queuedTurnLocation(clientMessageID: clientMessageID) else { return }
        _ = mutateAndPersistQueuedTurns {
            guard var queue = queuedRunningTurnsBySessionID[location.sessionID],
                  queue.indices.contains(location.index) else { return }
            queue[location.index].dispatchState = .waiting
            queue[location.index].lastError = message
            queuedRunningTurnsBySessionID[location.sessionID] = queue
        }
        setStatusMessage(message)
    }

    func hasQueuedGoalTurn(sessionID: SessionID) -> Bool {
        queuedRunningTurnsBySessionID[sessionID]?.contains(where: { $0.intent.startsGoal }) == true
    }

    func cancelQueuedRunningTurns(sessionID: SessionID, markMessagesFailed: Bool) {
        let queued = queuedRunningTurnsBySessionID[sessionID] ?? []
        queuedGuidanceDispatchClientMessageIDs.subtract(queued.map(\.clientMessageID))
        _ = mutateAndPersistQueuedTurns {
            setQueuedTurns([], sessionID: sessionID)
        }
        stopQueuedSessionMonitoringIfIdle(sessionID: sessionID)
        queuedTurnAwaitingStartSessionIDs.remove(sessionID)
        queuedTurnBlockedCompletionIDBySessionID.removeValue(forKey: sessionID)
        guard markMessagesFailed else {
            return
        }
        for item in queued {
            conversationStore.updateSendStatus(
                clientMessageID: item.clientMessageID,
                sessionID: sessionID,
                status: .failed
            )
        }
    }

    func socketForQueuedDispatch(sessionID: SessionID) -> (any SessionWebSocketClient)? {
        if selectedSessionID == sessionID,
           connectedSessionID == sessionID,
           case .connected = webSocketStatus {
            return webSocket
        }
        guard queuedSessionReadyIDs.contains(sessionID) else {
            return nil
        }
        return queuedSessionSockets[sessionID]
    }

    func ensureQueuedSessionMonitoring(sessionID: SessionID) {
        guard queuedRunningTurnsBySessionID[sessionID]?.isEmpty == false,
              connectionTermination == nil,
              !appStore.requiresRePairing,
              appStore.isConfigured,
              !isAppInBackground,
              !isNetworkUnavailable,
              let session = sessionsByID[sessionID]
        else {
            return
        }

        if selectedSessionID == sessionID {
            if queuedSessionSockets[sessionID] != nil {
                stopQueuedSessionMonitoring(sessionID: sessionID)
            }
            if connectedSessionID != sessionID || webSocket == nil {
                connectWebSocket(session, replayBufferedEvents: true, allowNonRunning: true)
            }
            return
        }
        guard queuedSessionSockets[sessionID] == nil else {
            return
        }

        let generation = (queuedSessionSocketGenerationByID[sessionID] ?? 0) + 1
        queuedSessionSocketGenerationByID[sessionID] = generation
        let socket = sessionWebSocketFactory?(session) ?? webSocketFactory()
        socket.onStatus = { [weak self] status in
            Task { @MainActor in
                guard self?.isCurrentQueuedSessionSocket(sessionID: sessionID, generation: generation) == true else {
                    return
                }
                switch status {
                case .connected:
                    self?.queuedSessionReadyIDs.insert(sessionID)
                    self?.dispatchNextQueuedRunningTurnIfIdle(sessionID: sessionID)
                case .failed(let message):
                    self?.queuedSessionReadyIDs.remove(sessionID)
                    self?.setStatusMessage(L10n.format("ui.failed_to_connect_to_queue_to_be_sent", message))
                    self?.scheduleQueuedSessionReconnect(sessionID: sessionID, generation: generation)
                case .terminated(let reason):
                    self?.queuedSessionReadyIDs.remove(sessionID)
                    self?.terminateConnection(reason)
                case .disconnected:
                    self?.queuedSessionReadyIDs.remove(sessionID)
                    self?.scheduleQueuedSessionReconnect(sessionID: sessionID, generation: generation)
                case .connecting:
                    break
                }
            }
        }
        socket.onEvent = { [weak self] event in
            Task { @MainActor in
                guard self?.isCurrentQueuedSessionSocket(sessionID: sessionID, generation: generation) == true else {
                    return
                }
                await self?.applyRuntimeEvent(event, sessionID: sessionID)
            }
        }
        socket.onSendAccepted = { [weak self] clientMessageID in
            Task { @MainActor in
                guard self?.isCurrentQueuedSessionSocket(sessionID: sessionID, generation: generation) == true,
                      let clientMessageID else { return }
                _ = self?.handleQueuedSendAccepted(clientMessageID: clientMessageID, sessionID: sessionID)
            }
        }
        socket.onSendFailure = { [weak self] clientMessageID, message in
            Task { @MainActor in
                guard self?.isCurrentQueuedSessionSocket(sessionID: sessionID, generation: generation) == true,
                      let clientMessageID else { return }
                _ = self?.handleQueuedSendFailure(
                    clientMessageID: clientMessageID,
                    sessionID: sessionID,
                    message: message
                )
            }
        }
        socket.onApprovalDecisionFailure = { _, _ in }
        socket.onUserInputResponseFailure = { _, _ in }
        socket.onControlFailure = { _ in }
        queuedSessionSockets[sessionID] = socket
        socket.connect(sessionID: sessionID, replayBufferedEvents: true)
    }

    func ensureAllQueuedSessionMonitoring() {
        for sessionID in queuedRunningTurnsBySessionID.keys {
            ensureQueuedSessionMonitoring(sessionID: sessionID)
        }
    }

    func isCurrentQueuedSessionSocket(sessionID: SessionID, generation: Int) -> Bool {
        queuedSessionSockets[sessionID] != nil
            && queuedSessionSocketGenerationByID[sessionID] == generation
    }

    func stopQueuedSessionMonitoringIfIdle(sessionID: SessionID) {
        guard queuedRunningTurnsBySessionID[sessionID]?.isEmpty != false else { return }
        guard queuedSessionSockets[sessionID] != nil || queuedSessionReconnectTasks[sessionID] != nil else {
            return
        }
        stopQueuedSessionMonitoring(sessionID: sessionID)
    }

    func stopQueuedSessionMonitoring(sessionID: SessionID) {
        markDispatchingQueuedTurnsNeedsConfirmation(
            sessionID: sessionID,
            message: L10n.text("ui.the_connection_has_been_interrupted_sending_results_requires")
        )
        queuedSessionSocketGenerationByID[sessionID, default: 0] += 1
        queuedSessionReconnectTasks.removeValue(forKey: sessionID)?.cancel()
        queuedSessionReadyIDs.remove(sessionID)
        let socket = queuedSessionSockets.removeValue(forKey: sessionID)
        socket?.disconnect()
    }

    func scheduleQueuedSessionReconnect(sessionID: SessionID, generation: Int) {
        guard isCurrentQueuedSessionSocket(sessionID: sessionID, generation: generation),
              queuedRunningTurnsBySessionID[sessionID]?.isEmpty == false else { return }
        markDispatchingQueuedTurnsNeedsConfirmation(
            sessionID: sessionID,
            message: L10n.text("ui.the_connection_has_been_interrupted_sending_results_requires")
        )
        let socket = queuedSessionSockets.removeValue(forKey: sessionID)
        queuedSessionSocketGenerationByID[sessionID, default: generation] += 1
        socket?.onStatus = nil
        socket?.disconnect()
        queuedSessionReconnectTasks[sessionID]?.cancel()
        queuedSessionReconnectTasks[sessionID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            guard let self else { return }
            self.queuedSessionReconnectTasks.removeValue(forKey: sessionID)
            self.ensureQueuedSessionMonitoring(sessionID: sessionID)
        }
    }

    func stopAllQueuedSessionMonitoring() {
        let sessionIDs = Set(queuedSessionSockets.keys).union(queuedSessionReconnectTasks.keys)
        for sessionID in sessionIDs {
            stopQueuedSessionMonitoring(sessionID: sessionID)
        }
    }

    func markDispatchingQueuedTurnsNeedsConfirmation(
        sessionID: SessionID,
        message: String
    ) {
        // 当前连接退役后，即使 turn/start 已 accepted，也可能错过紧随其后的 started；
        // 清掉仅属于该连接的门闩，恢复时交给 REST 快照重新判定 active turn。
        queuedTurnAwaitingStartSessionIDs.remove(sessionID)
        queuedTurnBlockedCompletionIDBySessionID.removeValue(forKey: sessionID)
        guard queuedRunningTurnsBySessionID[sessionID]?.contains(where: {
            $0.dispatchState == .dispatching
        }) == true else {
            return
        }
        _ = mutateAndPersistQueuedTurns {
            guard var queue = queuedRunningTurnsBySessionID[sessionID] else { return }
            for index in queue.indices where queue[index].dispatchState == .dispatching {
                queue[index].dispatchState = .needsConfirmation
                queue[index].lastError = message
            }
            queuedRunningTurnsBySessionID[sessionID] = queue
        }
    }

    @discardableResult
    func handleQueuedSendAccepted(
        clientMessageID: ClientMessageID,
        sessionID: SessionID
    ) -> Bool {
        guard let location = queuedTurnLocation(clientMessageID: clientMessageID),
              location.sessionID == sessionID,
              let item = queuedRunningTurnsBySessionID[sessionID]?[location.index],
              item.dispatchState == .dispatching
        else {
            return false
        }
        let wasGuidance = queuedGuidanceDispatchClientMessageIDs.remove(clientMessageID) != nil

        guard mutateAndPersistQueuedTurns({
            guard var queue = queuedRunningTurnsBySessionID[sessionID],
                  queue.indices.contains(location.index) else { return }
            queue.remove(at: location.index)
            if !wasGuidance {
                let blockedCompletionID = queuedTurnBlockedCompletionIDBySessionID[sessionID]
                for index in queue.indices where queue[index].dispatchState == .waiting {
                    queue[index].waitsForAcceptedTurnStart = true
                    queue[index].blockedCompletionID = blockedCompletionID
                    queue[index].expectedTurnID = nil
                }
            }
            setQueuedTurns(queue, sessionID: sessionID)
        }) else {
            return true
        }
        conversationStore.updateSendStatus(
            clientMessageID: clientMessageID,
            sessionID: sessionID,
            status: .sent
        )
        conversationStore.compactTurnPayloadAfterSendAccepted(
            clientMessageID: clientMessageID,
            sessionID: sessionID
        )
        stopQueuedSessionMonitoringIfIdle(sessionID: sessionID)
        return true
    }

    @discardableResult
    func handleQueuedSendFailure(
        clientMessageID: ClientMessageID,
        sessionID: SessionID,
        message: String
    ) -> Bool {
        guard let location = queuedTurnLocation(clientMessageID: clientMessageID),
              location.sessionID == sessionID,
              queuedRunningTurnsBySessionID[sessionID]?[location.index].dispatchState == .dispatching
        else {
            return false
        }
        queuedGuidanceDispatchClientMessageIDs.remove(clientMessageID)
        _ = mutateAndPersistQueuedTurns {
            guard var queue = queuedRunningTurnsBySessionID[sessionID],
                  queue.indices.contains(location.index) else { return }
            queue[location.index].dispatchState = .needsConfirmation
            queue[location.index].lastError = L10n.format("ui.uncertain_sending_result_value", message)
            queuedRunningTurnsBySessionID[sessionID] = queue
        }
        conversationStore.updateSendStatus(
            clientMessageID: clientMessageID,
            sessionID: sessionID,
            status: .failed
        )
        clearForegroundActivity(sessionID: sessionID)
        queuedTurnAwaitingStartSessionIDs.remove(sessionID)
        queuedTurnBlockedCompletionIDBySessionID.removeValue(forKey: sessionID)
        setErrorMessage(L10n.format("ui.the_result_of_the_message_to_be_sent", message))
        return true
    }

    func reconcilePersistedQueuedTurns() async {
        guard !queuedRunningTurnsBySessionID.isEmpty,
              connectionTermination == nil,
              !appStore.requiresRePairing,
              !isNetworkUnavailable
        else {
            return
        }
        let client: any SessionStoreAPIClient
        do {
            client = try clientFactory()
        } catch {
            return
        }

        // 每个有待发项的 thread 只做一次有界快照/历史核对。这里宁可要求用户确认重试，
        // 也不在 client_message_id 是否已落库不明确时盲目重放。
        for sessionID in Array(queuedRunningTurnsBySessionID.keys) {
            var authoritativeSession = sessionsByID[sessionID]
            if authoritativeSession == nil {
                do {
                    let response = try await client.session(id: sessionID, afterSeq: replayWatermark(for: sessionID))
                    let aligned = session(response.session, in: nil)
                    upsert(aligned)
                    authoritativeSession = aligned
                } catch {
                    continue
                }
            }

            let ambiguousIDs = Set(
                (queuedRunningTurnsBySessionID[sessionID] ?? [])
                    .filter { $0.dispatchState == .needsConfirmation }
                    .map(\.clientMessageID)
            )
            if !ambiguousIDs.isEmpty,
               let page = try? await client.messagesPage(
                    sessionID: sessionID,
                    before: nil,
                    limit: 60,
                    loadMode: .full
               ) {
                let deliveredIDs = Set(page.messages.compactMap(\.clientMessageID)).intersection(ambiguousIDs)
                if !deliveredIDs.isEmpty {
                    _ = mutateAndPersistQueuedTurns {
                        guard let queue = queuedRunningTurnsBySessionID[sessionID] else { return }
                        setQueuedTurns(
                            queue.filter { !deliveredIDs.contains($0.clientMessageID) },
                            sessionID: sessionID
                        )
                    }
                }
            }

            guard let authoritativeSession,
                  queuedRunningTurnsBySessionID[sessionID]?.first?.dispatchState == .waiting else {
                ensureQueuedSessionMonitoring(sessionID: sessionID)
                continue
            }
            _ = mutateAndPersistQueuedTurns {
                guard var queue = queuedRunningTurnsBySessionID[sessionID] else { return }
                for index in queue.indices where queue[index].dispatchState == .waiting {
                    if let activeTurnID = authoritativeSession.activeTurnID {
                        // 权威快照已确认上一条真正开始，持久化门闩可以转成具体 turn 等待。
                        queue[index].expectedTurnID = activeTurnID
                        queue[index].waitsForAcceptedTurnStart = nil
                        queue[index].blockedCompletionID = nil
                    } else if queue[index].waitsForAcceptedTurnStart != true {
                        // 普通等待项在权威快照 idle 时可恢复派发；accepted-but-not-started
                        // 门闩仍等待事件回放，避免瞬时 idle 把下一条注入尚未显现的 turn。
                        queue[index].expectedTurnID = nil
                    }
                }
                queuedRunningTurnsBySessionID[sessionID] = queue
            }
            ensureQueuedSessionMonitoring(sessionID: sessionID)
            dispatchNextQueuedRunningTurnIfIdle(sessionID: sessionID)
        }
    }

    func sendCtrlC() {
        guard let session = selectedSession, session.isRunning, canControlSession(session) else {
            return
        }
        guard session.activeTurnID != nil else {
            setStatusMessage(L10n.text("ui.there_are_currently_no_active_rounds_to_interrupt"))
            return
        }
        guard let socket = readyWebSocket(for: session) else {
            return
        }
        if !socket.sendCtrlC() {
            setErrorMessage(L10n.text("ui.sending_ctrl_c_failed_websocket_not_connected"))
        }
    }

    func decideApproval(_ approval: ApprovalSummary, accept: Bool) {
        decideApproval(approval, decision: accept ? "accept" : "decline")
    }

    func decideApproval(_ approval: ApprovalSummary, decision: String) {
        guard let session = selectedSession, session.isRunning else {
            setErrorMessage(L10n.text("ui.approval_failed_websocket_not_connected"))
            return
        }
        guard canControlSession(session) else {
            setErrorMessage(L10n.text("ui.this_session_is_running_on_another_client_please_d0b49af6"))
            return
        }
        guard let socket = readyWebSocket(for: session) else {
            setErrorMessage(L10n.text("ui.approval_failed_websocket_not_connected"))
            return
        }
        guard !isApprovalDecisionPending(approval, sessionID: session.id) else {
            setStatusMessage(L10n.text("ui.approval_decision_is_being_sent"))
            return
        }
        let normalizedDecision = decision.trimmingCharacters(in: .whitespacesAndNewlines)
        let isAccepting = normalizedDecision.lowercased().hasPrefix("accept")
        markApprovalDecisionPending(approval.id, sessionID: session.id)
        guard socket.sendApprovalDecision(approvalID: approval.id, decision: normalizedDecision, message: nil) else {
            clearPendingApprovalDecision(sessionID: session.id, approvalID: approval.id)
            setErrorMessage(L10n.text("ui.approval_sending_failed_websocket_not_connected"))
            return
        }
        if normalizedDecision.caseInsensitiveCompare("acceptWithPermissionUpdate") == .orderedSame {
            setStatusMessage(L10n.text("ui.sent_decision_to_approve_and_remember_rules_awaiting"))
        } else {
            setStatusMessage(isAccepting ? L10n.text("ui.the_approval_decision_has_been_sent_waiting_for") : L10n.text("ui.the_rejection_decision_has_been_sent_and_is"))
        }
    }

    func isApprovalDecisionPending(_ approval: ApprovalSummary) -> Bool {
        guard let sessionID = selectedSession?.id else {
            return false
        }
        return isApprovalDecisionPending(approval, sessionID: sessionID)
    }

    @discardableResult
    func respondToUserInput(_ request: AgentUserInputRequest, answers: [String: [String]]) -> Bool {
        guard let session = selectedSession, session.isRunning else {
            setErrorMessage(L10n.text("ui.supplemental_information_sending_failed_websocket_not_connected"))
            return false
        }
        guard canControlSession(session) else {
            setErrorMessage(L10n.text("ui.this_session_is_running_on_another_client_please_aacfc6a6"))
            return false
        }
        guard let socket = readyWebSocket(for: session) else {
            setErrorMessage(L10n.text("ui.supplemental_information_sending_failed_websocket_not_connected"))
            return false
        }
        guard !isUserInputResponsePending(request, sessionID: session.id) else {
            setStatusMessage(L10n.text("ui.additional_information_is_being_sent"))
            return false
        }
        markUserInputResponsePending(request, sessionID: session.id)
        guard socket.sendUserInputResponse(requestID: request.id, answers: answers) else {
            clearPendingUserInputResponse(sessionID: session.id, requestID: request.id)
            setErrorMessage(L10n.text("ui.supplemental_information_sending_failed_websocket_not_connected"))
            return false
        }
        acceptUserInputResponseLocally(request, sessionID: session.id)
        setStatusMessage(L10n.text("ui.supplementary_information_has_been_sent_waiting_for_codex"))
        return true
    }

    func isUserInputResponsePending(_ request: AgentUserInputRequest) -> Bool {
        guard let sessionID = selectedSession?.id else {
            return false
        }
        return isUserInputResponsePending(request, sessionID: sessionID)
    }

    @discardableResult
    func retryFailedUserMessage(_ message: ConversationMessage) async -> Bool {
        guard message.role == .user, message.sendStatus == .failed else {
            return false
        }
        let prompt = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return false
        }
        if let notice = selectedQuotaNotice, notice.blocksSending {
            setErrorMessage(notice.message)
            return false
        }

        if let session = selectedSession,
           session.isRunning,
           let clientMessageID = message.clientMessageID {
            guard canControlSession(session) else {
                setErrorMessage(L10n.text("ui.this_session_is_running_on_another_client_please_c95578ac"))
                return false
            }
            guard let socket = readyWebSocket(for: session) else {
                return false
            }
            // 失败消息有 client_message_id 时直接复用原 row 重发，避免 timeline 里出现重复用户气泡。
            conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: session.id, status: .sending)
            setSessionListProjection(sessionID: session.id, preview: prompt, source: .localUser, clientMessageID: clientMessageID)
            setForegroundActivity(.waitingForAssistant, sessionID: session.id)
            let payload = message.turnPayload ?? CodexAppServerTurnPayload(prompt: prompt)
            let resolvedPayload = await payloadResolvingRequiredModel(payload)
            guard socket.sendTurn(resolvedPayload, clientMessageID: clientMessageID) else {
                conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: session.id, status: .failed)
                clearSessionListProjection(sessionID: session.id, clientMessageID: clientMessageID)
                clearForegroundActivity(sessionID: session.id)
                setErrorMessage(L10n.text("ui.retry_failed_websocket_not_connected"))
                return false
            }
            return true
        }

        // 会话已经结束或失败时，沿用普通发送路径重新创建/恢复后端 thread。
        return await sendTurn(message.turnPayload ?? CodexAppServerTurnPayload(prompt: prompt))
    }

    func suspendForBackground() {
#if DEBUG
        guard !isDebugWorkbenchUISeedActive else {
            return
        }
#endif
        invalidatePreparedConnectionChange()
        isAppInBackground = true
        networkRecoveryTask?.cancel()
        networkRecoveryTask = nil
        guard connectionTermination == nil, !appStore.requiresRePairing else {
            return
        }

        let reconnectSessionID = connectedSessionID
            ?? (webSocketReconnectTask == nil ? nil : selectedSessionID)
            ?? networkSuspendedSessionID
        if let reconnectSessionID, sessionsByID[reconnectSessionID] != nil {
            if isNetworkUnavailable {
                networkSuspendedSessionID = reconnectSessionID
            } else {
                appLifecycleSuspendedSessionID = reconnectSessionID
                networkSuspendedSessionID = nil
            }
        }

        cancelWebSocketReconnect(resetAttempts: false)
        stopAllQueuedSessionMonitoring()
        webSocketConnectionGeneration += 1
        let socket = webSocket
        webSocket = nil
        connectedSessionID = nil
        socket?.disconnect()
        if let reconnectSessionID {
            markDispatchingQueuedTurnsNeedsConfirmation(
                sessionID: reconnectSessionID,
                message: L10n.text("ui.the_app_has_entered_the_background_and_confirmation")
            )
        }
        // iOS 可能在后台直接挂起 URLSession，未必及时回调断线。主动退役连接可避免回前台
        // 仍被旧 `.connected` 状态挡住；这里不清消息、排队 turn、审批或补充信息状态。
        setWebSocketStatus(.disconnected)
    }

    func resumeFromForeground() async {
#if DEBUG
        guard !isDebugWorkbenchUISeedActive else {
            return
        }
#endif
        isAppInBackground = false
        // 不用常驻 timer：App 每次回前台同步清理已触发提醒，离线或未配置时也能保持本地状态准确。
        reloadSessionReminders()
        guard appStore.isConfigured else {
            return
        }
        guard connectionTermination == nil, !appStore.requiresRePairing else {
            return
        }

        let reconnectSessionID = appLifecycleSuspendedSessionID ?? networkSuspendedSessionID
        appLifecycleSuspendedSessionID = nil
        networkSuspendedSessionID = nil
        guard !isNetworkUnavailable else {
            // 前台恢复时已知离线就不发 10 秒 REST 重试；把会话交还给 NWPath 恢复事件。
            if let reconnectSessionID, sessionsByID[reconnectSessionID] != nil {
                networkSuspendedSessionID = reconnectSessionID
            }
            setStatusMessage(L10n.text("ui.the_network_is_unavailable_and_will_automatically_reconnect_682354fa"))
            return
        }
        // 回前台同样可能赶上 gateway 还没恢复；做几秒的高频重试，避免单次失败后又卡到下次切换。
        // 正常情况下首次 refreshAll 就成功（errorMessage 为 nil），立即返回，不会有额外开销。
        await refreshUntilLoaded(maxWait: 10, autoAttach: true)
        ensureAllQueuedSessionMonitoring()

        guard connectionTermination == nil,
              !appStore.requiresRePairing,
              !isNetworkUnavailable,
              let reconnectSessionID,
              selectedSessionID == reconnectSessionID,
              let session = sessionsByID[reconnectSessionID],
              connectedSessionID != reconnectSessionID || webSocket == nil else {
            return
        }
        // REST 即使在短时 gateway 故障下没恢复，也用本地会话兜底重建监听；状态级回放会校准
        // 离开期间的完成/审批事件，且不会把旧内容 backlog 再直播一遍。
        connectWebSocket(
            session,
            isReconnectAttempt: true,
            replayBufferedEvents: false,
            allowNonRunning: true
        )
    }

    func stopSelectedSession() async {
        guard let session = selectedSession else {
            return
        }
        guard canControlSession(session) else {
            setErrorMessage(L10n.text("ui.this_session_is_running_on_another_client_please"))
            return
        }
        do {
            let client = try clientFactory()
            try await client.stopSession(id: session.id)
            updateSession(session.id) { item in
                item.status = "closed"
                item.pendingApproval = nil
                item.activeTurnID = nil
            }
            clearForegroundActivity(sessionID: session.id)
            clearRuntimeActivity(sessionID: session.id)
            cancelQueuedRunningTurns(sessionID: session.id, markMessagesFailed: true)
            conversationStore.appendSystem(L10n.text("ui.the_session_has_been_stopped"), sessionID: session.id)
            disconnectWebSocket()
            setStatusMessage(L10n.text("ui.session_stopped"))
        } catch {
            setErrorMessage(error.localizedDescription)
        }
    }

    func refreshSelectedThreadGoal() async {
        guard let sessionID = selectedSessionID else {
            return
        }
        isUpdatingThreadGoal = true
        threadGoalErrorMessage = nil
        defer { isUpdatingThreadGoal = false }
        do {
            let goal = try await clientFactory().threadGoal(threadID: sessionID)
            if let goal {
                applyThreadGoal(goal, fallbackSessionID: sessionID)
            } else {
                clearThreadGoal(sessionID: sessionID)
            }
        } catch {
            threadGoalErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func setThreadGoal(
        threadID: SessionID,
        objective: String?,
        status: ThreadGoalStatus?,
        tokenBudget: Int64?
    ) async -> Bool {
        let normalizedObjective = objective?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedObjective, normalizedObjective.isEmpty {
            threadGoalErrorMessage = L10n.text("ui.target_content_cannot_be_empty")
            return false
        }
        if let tokenBudget, tokenBudget <= 0 {
            threadGoalErrorMessage = L10n.text("ui.token_budget_must_be_greater_than_0")
            return false
        }
        isUpdatingThreadGoal = true
        threadGoalErrorMessage = nil
        defer { isUpdatingThreadGoal = false }
        do {
            let goal = try await clientFactory().setThreadGoal(
                threadID: threadID,
                objective: normalizedObjective,
                status: status,
                tokenBudget: tokenBudget
            )
            if let status, status != .complete {
                clearLocalCompletedGoalMark(goal, sessionID: threadID)
            }
            applyThreadGoal(goal, fallbackSessionID: threadID, respectsLocalCompletion: false)
            setStatusMessage(L10n.text("ui.goal_updated"))
            return true
        } catch {
            threadGoalErrorMessage = error.localizedDescription
            setErrorMessage(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func setSelectedThreadGoal(
        objective: String?,
        status: ThreadGoalStatus?,
        tokenBudget: Int64?
    ) async -> Bool {
        guard let sessionID = selectedSessionID else {
            return false
        }
        return await setThreadGoal(threadID: sessionID, objective: objective, status: status, tokenBudget: tokenBudget)
    }

    func updateSelectedThreadGoalStatus(_ status: ThreadGoalStatus) async {
        guard let sessionID = selectedSessionID else {
            return
        }
        _ = await setThreadGoal(threadID: sessionID, objective: nil, status: status, tokenBudget: nil)
    }

    func clearSelectedThreadGoal() async {
        guard let sessionID = selectedSessionID else {
            return
        }
        isUpdatingThreadGoal = true
        threadGoalErrorMessage = nil
        defer { isUpdatingThreadGoal = false }
        do {
            try await clientFactory().clearThreadGoal(threadID: sessionID)
            clearThreadGoal(sessionID: sessionID)
            setStatusMessage(L10n.text("ui.target_cleared"))
        } catch {
            threadGoalErrorMessage = error.localizedDescription
            setErrorMessage(error.localizedDescription)
        }
    }

}
