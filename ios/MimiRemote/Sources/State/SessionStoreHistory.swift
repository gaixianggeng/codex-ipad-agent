import Foundation

// 会话创建、历史预算、分页投影与搜索索引集中管理，保留原有缓存和限流语义。
extension SessionStore {
    @discardableResult
    func createSession(
        projectID: String,
        prompt: String,
        resume: AgentSession?,
        clientMessageID: ClientMessageID? = nil,
        runtimeProvider: String? = nil
    ) async -> Bool {
        var payload = CodexAppServerTurnPayload(prompt: prompt)
        if let runtimeProvider, !runtimeProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload.options.runtimeProvider = runtimeProvider
        }
        return await createSession(projectID: projectID, payload: payload, resume: resume, clientMessageID: clientMessageID)
    }

    @discardableResult
    func createSession(
        projectID: String,
        payload: CodexAppServerTurnPayload,
        resume: AgentSession?,
        clientMessageID: ClientMessageID? = nil,
        initialGoalObjective: String? = nil
    ) async -> Bool {
        // 空会话只执行 thread/start，没有 turn/start；提前拉 model/list 既不会影响线程创建，
        // 还会在远程链路上平白增加一次串行往返。只有真正要发送首轮输入时才解析模型。
        let payload = payload.isEmpty ? payload : await payloadResolvingRequiredModel(payload)
        if !payload.isEmpty, let notice = selectedQuotaNotice, notice.blocksSending {
            setErrorMessage(notice.message)
            return false
        }
        var projectID = projectID
        guard let workspace = ensureWorkspaceForKnownProjectID(projectID) else {
            setErrorMessage(L10n.text("ui.the_workspace_has_expired_please_reopen_it"))
            return false
        }
        projectID = workspace.id
        isLoading = true
        defer { isLoading = false }
        let prompt = payload.previewText
        let optimisticSessionID = optimisticSessionID(
            projectID: projectID,
            resume: resume,
            clientMessageID: clientMessageID,
            prompt: prompt
        ) ?? (resume == nil && payload.isEmpty ? "local:\(projectID):\(UUID().uuidString)" : nil)
        if let optimisticSessionID {
            // 空会话也先发布本地占位，让 UI 立即离开创建弹窗；带首轮输入时继续用
            // client_message_id 合并本地气泡，服务端确认后再迁移到真实 session_id。
            if resume == nil {
                upsert(makeOptimisticSession(
                    id: optimisticSessionID,
                    projectID: projectID,
                    prompt: prompt,
                    runtimeProvider: payload.options.runtimeProvider
                ))
            }
            setSelectedProjectID(projectID)
            setSelectedSessionID(optimisticSessionID)
            insertExpandedProjectID(projectID)
            if let clientMessageID {
                conversationStore.appendLocalUser(prompt, sessionID: optimisticSessionID, clientMessageID: clientMessageID, sendStatus: .sending, turnPayload: payload)
                setSessionListProjection(sessionID: optimisticSessionID, preview: prompt, source: .localUser, clientMessageID: clientMessageID)
                setForegroundActivity(.waitingForAssistant, sessionID: optimisticSessionID)
            } else if resume == nil {
                // 新建空会话同样属于用户最近操作；没有消息投影时单独建立排序保护。
                setSessionRecentActivityProjection(sessionID: optimisticSessionID, clientMessageID: nil)
            }
        }

        do {
            let client = try clientFactory()
            let response = try await client.createSession(CreateSessionRequest(
                projectID: projectID,
                projectPath: workspace.path,
                projectName: workspace.name,
                rootProjectID: workspace.rootProjectID,
                prompt: prompt,
                input: payload.input,
                turnOptions: payload.options,
                initialGoalObjective: initialGoalObjective,
                resumeID: resume?.resumeID ?? "",
                clientMessageID: clientMessageID
            ))
            let responseSession = self.session(response.session, in: workspace)

            if let optimisticSessionID,
               optimisticSessionID != responseSession.id {
                // 新建会话会从 local:<project>:<client_message_id> 切换到后端 session_id，
                // 这里迁移前台活动和本地气泡，保持列表/对话 store 解耦。
                if let clientMessageID {
                    conversationStore.moveLocalEcho(clientMessageID: clientMessageID, from: optimisticSessionID, to: responseSession.id)
                    moveSessionListProjection(from: optimisticSessionID, to: responseSession.id, clientMessageID: clientMessageID)
                    migrateForegroundActivity(from: optimisticSessionID, to: responseSession.id)
                    migrateRuntimeActivity(from: optimisticSessionID, to: responseSession.id)
                } else {
                    moveSessionRecentActivityProjection(
                        from: optimisticSessionID,
                        to: responseSession.id,
                        clientMessageID: nil
                    )
                }
                if resume == nil {
                    // 先让真实 ID 入库，再删临时 ID。否则 sessions 的 didSet 裁剪会把刚迁移到
                    // 真实 ID 的预览/最近活动投影当成孤儿清掉，造成新会话瞬间回跳或消失。
                    upsert(responseSession)
                    removeSession(optimisticSessionID)
                }
            }
            upsert(responseSession)
            setSessionControlState(resume == nil ? .ipadOwned : .takenOver, sessionID: responseSession.id)
            setSelectedProjectID(responseSession.projectID)
            setSelectedSessionID(responseSession.id)
            insertExpandedProjectID(responseSession.projectID)

            // 历史 resume 必须先补齐上下文，再追加本次用户输入，避免“发完历史没了”；
            // 带首轮 prompt 的新会话也保留 thread/read 快照，用它校准后续事件回放。
            // 新建空交互会话没有历史可补；启动后立刻请求完整历史容易撞上后端 thread/read
            // 初始化窗口并误报“大历史加载失败”，因此只跳过这类空会话的首屏补拉。
            let didLoadInitialHistory: Bool
            if hasLoadedFullHistorySnapshot(sessionID: responseSession.id) {
                // 用户刚从历史列表进入时可复用已有快照，避免同一会话立刻再打一次 full。
                didLoadInitialHistory = true
            } else if resume != nil || !payload.isEmpty {
                didLoadInitialHistory = await loadHistoryIfNeeded(for: responseSession)
            } else {
                // 新建空 thread 在首个 turn 前没有 rollout。把当前空快照标成已加载，前台恢复时
                // 就不会误打 thread/turns/list 并把 no-rollout 错报成“大历史加载失败”；首个 turn
                // 会改变 updatedAt/revision/lastSeq，届时签名自然失效并允许正常补拉。
                markEmptyHistoryLoaded(for: responseSession)
                didLoadInitialHistory = true
            }
            if !prompt.isEmpty {
                if let clientMessageID {
                    conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: responseSession.id, status: .sent)
                    conversationStore.compactTurnPayloadAfterSendAccepted(clientMessageID: clientMessageID, sessionID: responseSession.id)
                } else {
                    conversationStore.appendLocalUser(
                        prompt,
                        sessionID: responseSession.id,
                        clientMessageID: nil,
                        sendStatus: .sent,
                        turnPayload: payload.retainedAfterAcceptedSend()
                    )
                }
                setForegroundActivity(.waitingForAssistant, sessionID: responseSession.id)
            } else {
                conversationStore.appendSystem(L10n.text("ui.an_interactive_session_has_been_started"), sessionID: responseSession.id)
            }
            if let firstMessage = response.firstMessage {
                conversationStore.completeMessage(firstMessage, metadata: .empty, fallbackSessionID: responseSession.id)
                if firstMessage.role == .assistant {
                    setSessionListProjection(sessionID: responseSession.id, preview: firstMessage.content, source: .localAssistant, clientMessageID: nil)
                    clearForegroundActivity(sessionID: responseSession.id)
                }
            }
            // 历史已成为 canonical 快照后，WS 只需要补连接状态；否则 buffered content replay
            // 会把同一 turn 的过程卡再次 append 到时间线。历史加载失败时仍保留 replay，避免漏消息。
            let shouldReplayBufferedEvents = resume == nil || !didLoadInitialHistory
            connectWebSocket(responseSession, replayBufferedEvents: shouldReplayBufferedEvents)
            // 恢复反馈属于页面生命周期状态，不是服务端 transcript 内容，避免它参与历史排序。
            setStatusMessage(resume == nil ? L10n.text("ui.session_started") : L10n.text("ui.this_historical_conversation_has_been_continued"))
            setErrorMessage(nil)
            return true
        } catch {
            if let optimisticSessionID {
                if let clientMessageID {
                    conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: optimisticSessionID, status: .failed)
                    clearSessionListProjection(sessionID: optimisticSessionID, clientMessageID: clientMessageID)
                }
                clearSessionRecentActivityProjection(sessionID: optimisticSessionID, clientMessageID: clientMessageID)
                updateSession(optimisticSessionID) { item in
                    item.status = "failed"
                }
                clearForegroundActivity(sessionID: optimisticSessionID)
            }
            setErrorMessage(error.localizedDescription)
            return false
        }
    }

    func markEmptyHistoryLoaded(for session: AgentSession) {
        conversationStore.replaceHistorySnapshot([], sessionID: session.id)
        historyLoadedSignatureBySessionID[session.id] = HistoryLoadSignature(session: session)
        historyLoadedQualityBySessionID[session.id] = .full
        freshEmptyHistorySignatureBySessionID[session.id] = HistoryLoadSignature(session: session)
        historySavingsNoticesBySessionID.removeValue(forKey: session.id)
    }

    @discardableResult
    func loadHistoryIfNeeded(for session: AgentSession) async -> Bool {
        if canReuseFreshEmptyHistory(for: session) {
            return true
        }
        guard !canReuseLoadedHistory(for: session, loadMode: .full) else {
            return true
        }
        return await loadHistory(for: session)
    }

    func canReuseFreshEmptyHistory(for session: AgentSession) -> Bool {
        guard let baseline = freshEmptyHistorySignatureBySessionID[session.id] else {
            return false
        }
        // thread/start 与 thread/list 的 updatedAt 来源并不稳定，不能用它判断首个 turn 是否存在。
        // 本地首发会主动清除此标记；远端状态若已出现 turn/seq/revision，也立即恢复正常历史补拉。
        let isStillFresh = baseline.revision == session.revision
            && baseline.lastSeq == session.lastSeq
            && session.activeTurnID == nil
        if !isStillFresh {
            freshEmptyHistorySignatureBySessionID.removeValue(forKey: session.id)
        }
        return isStillFresh
    }

    // quiet 模式用于切回已加载会话时的后台补拉：界面继续展示缓存，不出进度条，
    // 失败也不打扰用户（下一次轮询/手动刷新仍会兜底）。
    @discardableResult
    func loadHistory(
        for session: AgentSession,
        quiet: Bool = false,
        loadMode: HistoryMessagesPage.LoadMode = .full,
        force: Bool = false,
        reason: HistoryLoadReason = .automatic,
        successStatusMessage: String? = nil,
        allowPolicyRetry: Bool = true
    ) async -> Bool {
        if !force, canReuseLoadedHistory(for: session, loadMode: loadMode) {
            return true
        }

        if let existing = historyLoadJobsBySessionID[session.id] {
            if existing.loadMode == loadMode {
                // 已有同模式加载时直接等待同一个 job，避免切换/刷新制造重复大包请求。
                // 前台刷新加入 quiet job 后必须提升共享 job 的反馈级别；否则 quiet waiter
                // 若先恢复，会先移除 job 并吞掉失败提示，手动刷新只能静默返回 false。
                if !quiet {
                    promoteHistoryLoadJobForForegroundReporting(
                        existing,
                        sessionID: session.id,
                        successStatusMessage: successStatusMessage
                    )
                    setHistoryLoadProgress(
                        sessionID: session.id,
                        title: loadMode == .full ? L10n.text("ui.request_full_history") : L10n.text("ui.request_thumbnail_history"),
                        fraction: 0.32
                    )
                    let didLoad = await awaitHistoryLoadJob(
                        existing,
                        session: session,
                        quiet: false,
                        successStatusMessage: successStatusMessage
                    )
                    clearHistoryLoadProgress(sessionID: session.id)
                    return didLoad
                }
                return await awaitHistoryLoadJob(
                    existing,
                    session: session,
                    quiet: quiet,
                    successStatusMessage: successStatusMessage
                )
            }
            switch reason {
            case .summaryChoice, .manualFull:
                cancelHistoryLoadJob(existing, sessionID: session.id)
            case .automatic:
                return true
            }
        }

        let signature = HistoryLoadSignature(session: session)
        let jobToken = beginHistoryLoadJob(sessionID: session.id)
        let limit = loadMode == .full ? fullHistoryPageLimit : economyHistoryPageLimit
        let hasNewerSessionSnapshot = historyLoadedSignatureBySessionID[session.id].map { $0 != signature } == true
        let cachePolicy: HistoryFirstPageCachePolicy = force || hasNewerSessionSnapshot ? .bypass : .reuseRecent
        let task = Task { [self] in
            try await historyFirstPage(
                sessionID: session.id,
                limit: limit,
                loadMode: loadMode,
                cachePolicy: cachePolicy
            )
        }
        let job = HistoryLoadJob(
            token: jobToken,
            sessionSignature: signature,
            loadMode: loadMode,
            allowPolicyRetry: allowPolicyRetry,
            task: task,
            requiresForegroundReporting: !quiet,
            foregroundSuccessStatusMessage: quiet ? nil : successStatusMessage
        )
        historyLoadJobsBySessionID[session.id] = job
        if !quiet {
            setHistoryLoadNotice(sessionID: session.id, kind: loadMode == .full ? .loadingFull : .loadingSummary)
        }

        if !quiet {
            setHistoryLoadProgress(sessionID: session.id, title: loadMode == .full ? L10n.text("ui.ready_to_load_full_history") : L10n.text("ui.prepare_to_load_abbreviated_history"), fraction: 0.08)
        }
        defer {
            if !quiet {
                clearHistoryLoadProgress(sessionID: session.id)
            }
        }

        if !quiet {
            setHistoryLoadProgress(sessionID: session.id, title: loadMode == .full ? L10n.text("ui.request_full_history") : L10n.text("ui.request_thumbnail_history"), fraction: 0.32)
        }
        return await awaitHistoryLoadJob(job, session: session, quiet: quiet, successStatusMessage: successStatusMessage)
    }

    func promoteHistoryLoadJobForForegroundReporting(
        _ job: HistoryLoadJob,
        sessionID: SessionID,
        successStatusMessage: String?
    ) {
        guard var current = historyLoadJobsBySessionID[sessionID], current.token == job.token else {
            return
        }
        current.requiresForegroundReporting = true
        if let successStatusMessage {
            current.foregroundSuccessStatusMessage = successStatusMessage
        }
        historyLoadJobsBySessionID[sessionID] = current
        setHistoryLoadNotice(
            sessionID: sessionID,
            kind: current.loadMode == .full ? .loadingFull : .loadingSummary
        )
    }

    func scheduleQuietHistoryRefresh(for session: AgentSession) {
        Task { [weak self] in
            guard let self, self.selectedSessionID == session.id else {
                return
            }
            await self.loadHistory(for: session, quiet: true)
        }
    }

    func canReuseLoadedHistory(for session: AgentSession, loadMode: HistoryMessagesPage.LoadMode) -> Bool {
        guard conversationStore.hasLoadedHistory(sessionID: session.id),
              let loadedSignature = historyLoadedSignatureBySessionID[session.id],
              loadedSignature == HistoryLoadSignature(session: session),
              let loadedQuality = historyLoadedQualityBySessionID[session.id]
        else {
            return false
        }
        // 缩略历史只能满足 summary 视图；当调用方明确需要 full 时必须重新拉完整历史。
        return loadMode == .economy || loadedQuality == .full
    }

    func hasLoadedFullHistorySnapshot(sessionID: SessionID) -> Bool {
        conversationStore.hasLoadedHistory(sessionID: sessionID)
            && historyLoadedQualityBySessionID[sessionID] == .full
    }

    func awaitHistoryLoadJob(
        _ job: HistoryLoadJob,
        session: AgentSession,
        quiet: Bool,
        successStatusMessage: String?
    ) async -> Bool {
        do {
            let result = try await job.task.value
            return finishHistoryLoadJob(
                job,
                result: result,
                sessionID: session.id,
                quiet: quiet,
                successStatusMessage: successStatusMessage
            )
        } catch {
            return await failHistoryLoadJob(job, session: session, error: error, quiet: quiet)
        }
    }

    func finishHistoryLoadJob(
        _ job: HistoryLoadJob,
        result: HistoryFirstPageResult,
        sessionID: SessionID,
        quiet: Bool,
        successStatusMessage: String?
    ) -> Bool {
        guard let current = historyLoadJobsBySessionID[sessionID], current.token == job.token else {
            // 当前 job 已被用户选择 summary 或新的刷新取代；旧结果可以完成，但不能覆盖界面。
            return historyLoadedSignatureBySessionID[sessionID] == job.sessionSignature
        }
        let effectiveQuiet = quiet && !current.requiresForegroundReporting
        let effectiveSuccessStatusMessage = current.foregroundSuccessStatusMessage ?? successStatusMessage
        historyLoadJobsBySessionID.removeValue(forKey: sessionID)
        guard isCurrentHistoryPageRequest(sessionID: sessionID, token: result.token) else {
            return false
        }
        if !effectiveQuiet {
            setHistoryLoadProgress(sessionID: sessionID, title: L10n.text("ui.parse_historical_messages"), fraction: 0.74)
        }
        applyHistoryFirstPage(result.page, sessionID: sessionID)
        if !effectiveQuiet {
            setHistoryLoadProgress(sessionID: sessionID, title: L10n.text("ui.update_interface"), fraction: 0.94)
        }
        updateHistoryPageState(sessionID: sessionID, page: result.page, preserveExistingCursorOnEmptyPage: true)
        historyLoadedSignatureBySessionID[sessionID] = job.sessionSignature
        historyLoadedQualityBySessionID[sessionID] = job.loadMode == .full ? .full : .summary
        if job.loadMode == .full {
            historySavingsNoticesBySessionID.removeValue(forKey: sessionID)
        } else if !effectiveQuiet {
            setHistoryLoadNotice(sessionID: sessionID, kind: .summaryLoaded)
        }
        if let effectiveSuccessStatusMessage {
            setStatusMessage(effectiveSuccessStatusMessage)
        }
        return true
    }

    func failHistoryLoadJob(
        _ job: HistoryLoadJob,
        session: AgentSession,
        error: Error,
        quiet: Bool
    ) async -> Bool {
        let sessionID = session.id
        guard let current = historyLoadJobsBySessionID[sessionID], current.token == job.token else {
            return false
        }
        let effectiveQuiet = quiet && !current.requiresForegroundReporting
        historyLoadJobsBySessionID.removeValue(forKey: sessionID)
        if error is CancellationError {
            return false
        }
        if let failure = error as? HistoryFirstPageFetchFailure,
           !isCurrentHistoryPageRequest(sessionID: sessionID, token: failure.token) {
            return false
        }
        if let policyFailure = historyPolicyFailure(from: error) {
            switch job.loadMode {
            case .full:
                let message = L10n.text("ui.the_full_history_content_is_large_and_the")
                if !effectiveQuiet {
                    setHistoryLoadNotice(sessionID: sessionID, kind: .loadingSummary, message: message)
                    setStatusMessage(message)
                }
                return await loadHistory(
                    for: session,
                    quiet: effectiveQuiet,
                    loadMode: .economy,
                    force: true,
                    reason: .automatic,
                    successStatusMessage: effectiveQuiet ? nil : L10n.text("ui.thumbnail_history_automatically_loaded")
                )
            case .economy where job.allowPolicyRetry:
                let delay = policyFailure.retryAfterNanoseconds ?? historyPolicyRetryFallbackNanoseconds
                let seconds = policyFailure.retryAfterSeconds ?? Int((delay + 999_999_999) / 1_000_000_000)
                let message = L10n.plural("ui.compact_history_retry_seconds_count", count: seconds)
                if !effectiveQuiet {
                    setHistoryLoadNotice(sessionID: sessionID, kind: .loadingSummary, message: message)
                    setStatusMessage(message)
                }
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else {
                    return false
                }
                if let selectedSessionID, selectedSessionID != sessionID {
                    return false
                }
                return await loadHistory(
                    for: session,
                    quiet: effectiveQuiet,
                    loadMode: .economy,
                    force: true,
                    reason: .automatic,
                    successStatusMessage: effectiveQuiet ? nil : L10n.text("ui.thumbnail_history_loaded"),
                    allowPolicyRetry: false
                )
            default:
                break
            }
        }
        if job.loadMode == .full {
            if !effectiveQuiet {
                setHistoryLoadNotice(sessionID: sessionID, kind: .fullFailed)
                setStatusMessage(L10n.format("ui.full_history_loading_failed_value", error.localizedDescription))
            }
        } else {
            // 终态失败必须离开“正在加载”横幅，否则重连触发的静默刷新会让界面永远停在加载中。
            if !effectiveQuiet {
                setHistoryLoadNotice(sessionID: sessionID, kind: .summaryFailed)
                setErrorMessage(L10n.format("ui.thumbnail_history_loading_failed_value", error.localizedDescription))
            }
        }
        return false
    }

    // gateway 策略拒绝（-32080）对同样的请求参数是确定性失败：自动重连只会带着相同参数再次被拒，
    // 结果是错误横幅无限刷新。历史预算类拒绝（限流/响应过大/pending 过多）是时间窗资源，恢复后
    // 可以成功，这些仍保留重连与 history 重试路径。
    nonisolated static func isDeterministicGatewayPolicyFailure(_ message: String) -> Bool {
        guard message.contains("-32080") else {
            return false
        }
        let lowerMessage = message.lowercased()
        if lowerMessage.contains("thread/turns/list")
            || lowerMessage.contains("thread/read")
            || lowerMessage.contains("history response")
            || lowerMessage.contains("limit/itemsview")
            || message.contains("相同历史或列表请求仍在执行") {
            return false
        }
        return !(message.contains("历史响应")
            || message.contains("临时限流")
            || message.contains("响应过大")
            || message.contains("内容过大")
            || message.contains("请求过多"))
    }

    func sessionListPolicyFailure(from error: Error) -> SessionListPolicyFailure? {
        let appServerError: CodexAppServerError?
        if case CodexAppServerConnectionError.appServer(let error) = error {
            appServerError = error
        } else {
            appServerError = nil
        }
        let data = appServerError?.data?.objectValue
        let method = data?["method"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let reason = data?["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let message = error.localizedDescription.lowercased()
        let isStructuredListPolicy = appServerError?.code == -32080
            && method == "thread/list"
            && (reason == "history_budget_limited" || reason == "history_request_in_flight")
        let isLegacyListPolicy = message.contains("-32080")
            && message.contains("thread/list")
            && (message.contains("临时限流") || message.contains("相同历史或列表请求"))
        guard isStructuredListPolicy || isLegacyListPolicy else { return nil }

        let fallbackNanoseconds: UInt64 = reason == "history_request_in_flight"
            ? 1_000_000_000
            : 15_000_000_000
        let requestedNanoseconds: UInt64
        if let retryAfterMs = data?["retryAfterMs"]?.intValue, retryAfterMs > 0 {
            requestedNanoseconds = UInt64(retryAfterMs) * 1_000_000
        } else if let retryAfterSeconds = data?["retryAfterSeconds"]?.intValue, retryAfterSeconds > 0 {
            requestedNanoseconds = UInt64(retryAfterSeconds) * 1_000_000_000
        } else {
            requestedNanoseconds = fallbackNanoseconds
        }
        // 防止异常上游把客户端挂起太久；正常 gateway 窗口目前是 1~15 秒。
        let boundedNanoseconds = min(max(requestedNanoseconds, 1_000_000), 60_000_000_000)
        let seconds = max(1, Int((boundedNanoseconds + 999_999_999) / 1_000_000_000))
        return SessionListPolicyFailure(
            retryAfterNanoseconds: boundedNanoseconds,
            retryAfterSeconds: seconds
        )
    }

    func historyPolicyFailure(from error: Error) -> HistoryPolicyFailure? {
        let underlying = (error as? HistoryFirstPageFetchFailure)?.underlying ?? error
        let message = underlying.localizedDescription
        let lowerMessage = message.lowercased()
        let appServerError: CodexAppServerError?
        if case CodexAppServerConnectionError.appServer(let error) = underlying {
            appServerError = error
        } else {
            appServerError = nil
        }

        let data = appServerError?.data?.objectValue
        let reason = data?["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isHistoryReason = reason?.hasPrefix("history_") == true
        let isLegacyHistoryPolicyMessage =
            lowerMessage.contains("-32080")
            && (
                lowerMessage.contains("thread/turns/list")
                || lowerMessage.contains("thread/read")
                || lowerMessage.contains("history response")
                || lowerMessage.contains("limit/itemsview")
                || message.contains("历史响应")
                || message.contains("临时限流")
                || message.contains("响应过大")
                || message.contains("内容过大")
            )
        let isGatewayHistoryPolicy = appServerError?.code == -32080 && (isHistoryReason || isLegacyHistoryPolicyMessage)
        guard isGatewayHistoryPolicy || isLegacyHistoryPolicyMessage else {
            return nil
        }

        let retryAfterMs = data?["retryAfterMs"]?.intValue
        let retryAfterSeconds = data?["retryAfterSeconds"]?.intValue
            ?? Self.retryAfterSeconds(fromHistoryPolicyMessage: message)
        let retryAfterNanoseconds: UInt64?
        if let retryAfterMs, retryAfterMs > 0 {
            retryAfterNanoseconds = boundedHistoryPolicyRetryNanoseconds(UInt64(retryAfterMs) * 1_000_000)
        } else if let retryAfterSeconds, retryAfterSeconds > 0 {
            retryAfterNanoseconds = boundedHistoryPolicyRetryNanoseconds(UInt64(retryAfterSeconds) * 1_000_000_000)
        } else {
            retryAfterNanoseconds = nil
        }
        return HistoryPolicyFailure(retryAfterNanoseconds: retryAfterNanoseconds, retryAfterSeconds: retryAfterSeconds)
    }

    func boundedHistoryPolicyRetryNanoseconds(_ nanoseconds: UInt64) -> UInt64 {
        min(max(nanoseconds, 1_000_000), historyPolicyRetryMaxNanoseconds)
    }

    nonisolated static func retryAfterSeconds(fromHistoryPolicyMessage message: String) -> Int? {
        let patterns = [
            #""retryAfterSeconds"\s*:\s*(\d+)"#,
            #""retry_after_seconds"\s*:\s*(\d+)"#,
            #"请\s*(\d+)\s*秒后重试"#
        ]
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            guard let match = regex.firstMatch(in: message, range: range),
                  let secondsRange = Range(match.range(at: 1), in: message),
                  let seconds = Int(message[secondsRange]) else {
                continue
            }
            return seconds
        }
        return nil
    }

    func cancelHistoryLoadJob(_ job: HistoryLoadJob, sessionID: SessionID) {
        if historyLoadJobsBySessionID[sessionID]?.token == job.token {
            // best-effort 取消旧 job；即使底层请求已发出，token 校验也会阻止迟到结果覆盖当前视图。
            job.task.cancel()
            historyLoadJobsBySessionID.removeValue(forKey: sessionID)
        }
    }

    func setHistoryLoadNotice(sessionID: SessionID, kind: HistorySavingsNotice.Kind, message customMessage: String? = nil) {
        let defaultMessage: String
        switch kind {
        case .loadingFull:
            defaultMessage = L10n.text("ui.loading_the_complete_history_you_may_need_to")
        case .fullFailed:
            defaultMessage = L10n.text("ui.the_complete_history_failed_to_load_the_content")
        case .loadingSummary:
            defaultMessage = L10n.text("ui.loading_thumbnail_history")
        case .summaryLoaded:
            defaultMessage = L10n.text("ui.currently_showing_abbreviated_history")
        case .summaryFailed:
            defaultMessage = L10n.text("ui.the_thumbnail_history_loading_failed_possibly_due_to")
        }
        let message = customMessage ?? defaultMessage
        historySavingsNoticesBySessionID[sessionID] = HistorySavingsNotice(sessionID: sessionID, kind: kind, message: message)
    }

    func refreshSelectedSessionContent(
        _ session: AgentSession,
        successStatusMessage: String = L10n.text("ui.the_current_session_has_been_refreshed"),
        reason: HistoryLoadReason = .manualFull
    ) async {
        isRefreshingSelectedSession = true
        defer { isRefreshingSelectedSession = false }

        let didLoad = await loadHistory(
            for: session,
            quiet: false,
            loadMode: .full,
            force: true,
            reason: reason,
            successStatusMessage: successStatusMessage
        )
        if didLoad {
            if !session.isRunning {
                clearForegroundActivity(sessionID: session.id)
                clearRuntimeActivity(sessionID: session.id)
            }
            // 手动刷新当前会话只等待历史页接口；列表/运行态校准放到后台，
            // 避免 thread/list 之类的慢接口把“刷新历史”按钮继续卡住。
            scheduleSessionStateReconciliationAfterHistoryRefresh(session)
            setErrorMessage(nil)
        }
    }

    func historyFirstPage(
        sessionID: SessionID,
        limit: Int,
        loadMode: HistoryMessagesPage.LoadMode,
        cachePolicy: HistoryFirstPageCachePolicy
    ) async throws -> HistoryFirstPageResult {
        let key = HistoryFirstPageRequestKey(sessionID: sessionID, limit: limit, loadMode: loadMode)
        if cachePolicy == .reuseRecent,
           let cached = historyFirstPageCacheByKey[key],
           Date().timeIntervalSince(cached.loadedAt) < historyFirstPageCacheTTL {
            return HistoryFirstPageResult(page: cached.page, token: cached.token)
        }
        if cachePolicy == .reuseRecent,
           let inFlight = historyFirstPageInFlightByKey[key] {
            do {
                return HistoryFirstPageResult(page: try await inFlight.task.value, token: inFlight.token)
            } catch {
                throw HistoryFirstPageFetchFailure(underlying: error, token: inFlight.token)
            }
        }

        let token = beginHistoryPageRequest(sessionID: sessionID)
        let client = try clientFactory()
        let task = Task {
            try await client.messagesPage(
                sessionID: sessionID,
                before: nil,
                limit: limit,
                loadMode: loadMode
            )
        }
        historyFirstPageInFlightByKey[key] = HistoryFirstPageInFlight(token: token, task: task)
        do {
            let page = try await task.value
            if historyFirstPageInFlightByKey[key]?.token == token {
                historyFirstPageInFlightByKey.removeValue(forKey: key)
                historyFirstPageCacheByKey[key] = HistoryFirstPageCacheEntry(page: page, loadedAt: Date(), token: token)
            }
            return HistoryFirstPageResult(page: page, token: token)
        } catch {
            if historyFirstPageInFlightByKey[key]?.token == token {
                historyFirstPageInFlightByKey.removeValue(forKey: key)
            }
            throw HistoryFirstPageFetchFailure(underlying: error, token: token)
        }
    }

    func applyHistoryFirstPage(_ page: HistoryMessagesPage, sessionID: SessionID) {
        ingestHistoryContext(page.context, fallbackSessionID: sessionID)
        conversationStore.replaceHistorySnapshot(
            page.messages,
            sessionID: sessionID,
            authoritativeCompletedTurnItems: page.authoritativeCompletedTurnItems
        )
        updateHistorySavingsNotice(sessionID: sessionID, page: page)
    }

    func updateHistorySavingsNotice(sessionID: SessionID, page: HistoryMessagesPage) {
        guard page.loadMode == .economy,
              let notice = page.notice?.trimmingCharacters(in: .whitespacesAndNewlines),
              !notice.isEmpty
        else {
            historySavingsNoticesBySessionID.removeValue(forKey: sessionID)
            return
        }
        historySavingsNoticesBySessionID[sessionID] = HistorySavingsNotice(sessionID: sessionID, kind: .summaryLoaded, message: notice)
    }

    func scheduleSessionStateReconciliationAfterHistoryRefresh(_ session: AgentSession) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.reconcileSessionStateAfterHistoryRefresh(session)
        }
    }

    func reconcileSessionStateAfterHistoryRefresh(_ session: AgentSession) async {
        if session.isRunning {
            do {
                let client = try clientFactory()
                let response = try await client.session(id: session.id, afterSeq: logStore.lastSeq(for: session.id))
                let refreshed = self.session(response.session, in: workspaceForSession(session))
                upsert(refreshed)
                if !refreshed.isRunning {
                    clearForegroundActivity(sessionID: session.id)
                    clearRuntimeActivity(sessionID: session.id)
                }
                if let recentOutput = response.recentOutput, !recentOutput.isEmpty {
                    // recent_output 只作为诊断日志展示；对话内容以 app-server 结构化 history/event 为准。
                    logStore.append(recentOutput, sessionID: session.id, seq: response.lastSeq)
                }
            } catch {
                // 运行态快照读取失败时，后台静默用列表刷新重新同步 app-server 线程状态。
                await refreshSessionListQuietlyIfStillSelected(projectID: session.projectID)
            }
        } else {
            await refreshSessionListQuietlyIfStillSelected(projectID: session.projectID)
        }
    }

    func refreshSessionListQuietlyIfStillSelected(projectID: String) async {
        guard selectedProjectID == projectID else {
            return
        }
        await refreshSessions(
            forProjectID: projectID,
            showLoading: false,
            clearErrorOnSuccess: false,
            updateStatusMessage: false,
            reportErrorOnFailure: false
        )
    }

    func refreshSessions(
        forProjectID projectID: String,
        showLoading: Bool = true,
        clearErrorOnSuccess: Bool = true,
        updateStatusMessage: Bool = true,
        reportErrorOnFailure: Bool = true,
        reuseRecent: Bool? = nil,
        consistency: SessionListConsistency = .fastIndexed,
        activatesProject: Bool = true
    ) async {
        var projectID = projectID
        guard let workspace = ensureWorkspaceForKnownProjectID(projectID) else {
            setErrorMessage(L10n.text("ui.the_workspace_has_expired_please_reopen_it"))
            return
        }
        projectID = workspace.id
        if activatesProject, selectedProjectID != projectID {
            setSelectedProjectID(projectID)
        }
        if showLoading {
            isLoading = true
        }
        defer {
            if showLoading {
                isLoading = false
            }
        }
        var requestToken: Int?
        do {
            requestToken = beginSessionPageRequest(projectID: projectID)
            defer { finishSessionPageRequest(projectID: projectID, token: requestToken ?? 0) }
            let page = try await sessionListFirstPage(
                workspace: workspace,
                limit: Self.initialSessionPageLimit,
                reuseRecent: reuseRecent ?? !showLoading,
                consistency: consistency
            )
            guard isCurrentSessionPageRequest(projectID: projectID, token: requestToken ?? 0) else {
                return
            }
            guard !activatesProject || selectedProjectID == projectID else {
                return
            }
            // 只替换当前项目的会话，避免一次项目点击误删其他项目已经加载好的列表。
            let pageSessions = sessions(page.sessions, in: workspace)
            replaceSessionsIfChanged(with: pageSessionsPreservingLoadedWindow(pageSessions, projectID: projectID), projectID: projectID)
            updateSessionPageState(projectID: projectID, page: page)
            clearWorkspaceUnavailable(projectID)
            if updateStatusMessage {
                setStatusMessage(L10n.plural("ui.sessions_loaded_count", count: filteredSessions.count))
            }
            // 手动刷新/切换工作区成功时可以清掉旧错误；发送后的后台刷新不能抢掉刚产生的发送失败提示。
            if clearErrorOnSuccess {
                setErrorMessage(nil)
            }
        } catch {
            if let requestToken, !isCurrentSessionPageRequest(projectID: projectID, token: requestToken) {
                return
            }
            if reportErrorOnFailure, selectedProjectID == projectID {
                await handleWorkspaceLoadFailure(workspace: workspace, error: error)
            }
        }
    }

    func sessionLibraryPage(
        workspace: AgentWorkspace,
        consistency: SessionListConsistency = .fastIndexed
    ) async -> (workspace: AgentWorkspace, page: SessionsPage?) {
        do {
            let page = try await sessionListFirstPage(
                workspace: workspace,
                limit: Self.initialSessionPageLimit,
                reuseRecent: consistency == .fastIndexed,
                consistency: consistency
            )
            return (workspace, page)
        } catch {
            // 某个最近工作区失效不能阻断整个会话库；该项目仍可在工作区页单独重试。
            return (workspace, nil)
        }
    }

    func mergeSessionLibraryPages(
        _ results: [(workspace: AgentWorkspace, page: SessionsPage?)],
        generation: Int
    ) {
        guard generation == appStore.connectionGeneration else { return }
        for result in results {
            guard let page = result.page else { continue }
            mergeSessionPage(sessions(page.sessions, in: result.workspace))
            updateSessionPageState(projectID: result.workspace.id, page: page)
            clearWorkspaceUnavailable(result.workspace.id)
        }
    }

    func sessionListFirstPage(
        workspace: AgentWorkspace,
        limit: Int,
        reuseRecent: Bool,
        consistency: SessionListConsistency = .fastIndexed
    ) async throws -> SessionsPage {
        let key = SessionListFirstPageRequestKey(
            connectionGeneration: appStore.connectionGeneration,
            workspaceID: workspace.id,
            workspacePath: workspace.path,
            limit: limit,
            consistency: consistency
        )
        // 手动刷新可以绕过短缓存，但同一时刻仍必须等待已存在的共享请求。
        if let inFlight = sessionListFirstPageInFlightByKey[key] {
            return try await inFlight.task.value
        }
        // 会话库只需要 8 条时，可以复用同工作区正在执行的 20 条请求；反向复用会缩短主列表，不能做。
        // 后台快速刷新也可以等待更强的权威请求；权威刷新不能复用快速索引结果，否则会重新引入漏会话问题。
        if let largerInFlight = sessionListFirstPageInFlightByKey.first(where: { entry in
            entry.key.connectionGeneration == key.connectionGeneration
                && entry.key.workspaceID == key.workspaceID
                && entry.key.workspacePath == key.workspacePath
                && (
                    entry.key.consistency == key.consistency
                        || (key.consistency == .fastIndexed && entry.key.consistency == .authoritative)
                )
                && entry.key.limit >= key.limit
        })?.value {
            return try await largerInFlight.task.value
        }
        let now = sessionListNow()
        if reuseRecent,
           let cached = sessionListFirstPageCacheByKey[key]
                ?? cachedSessionListEntry(workspace: workspace, minimumLimit: limit),
           now.timeIntervalSince(cached.loadedAt) < sessionListFirstPageCacheTTL {
            return cached.page
        }

        if let cooldownDelay = sessionListCooldownDelayNanoseconds(for: workspace) {
            // 已有页时直接保留旧列表；后台轮询会在窗口恢复后自然校准，不让限流冒泡成整页红错。
            if let stale = cachedSessionListPage(workspace: workspace, minimumLimit: limit) {
                return stale
            }
            // 冷启动没有任何可展示数据时才等待窗口并继续请求，保证首屏最终自动恢复。
            await sessionListSleep(cooldownDelay)
        }

        let client = try clientFactory()
        let task = Task {
            try await client.sessionsPage(
                workspace: workspace,
                cursor: nil,
                limit: limit,
                consistency: consistency
            )
        }
        sessionListFirstPageInFlightByKey[key] = SessionListFirstPageInFlight(task: task)
        do {
            let page = try await task.value
            sessionListFirstPageInFlightByKey.removeValue(forKey: key)
            sessionListFirstPageCacheByKey[key] = SessionListFirstPageCacheEntry(page: page, loadedAt: sessionListNow())
            clearSessionListCooldown(for: workspace)
            return page
        } catch {
            sessionListFirstPageInFlightByKey.removeValue(forKey: key)
            if let policyFailure = sessionListPolicyFailure(from: error) {
                registerSessionListCooldown(policyFailure, for: workspace)
            }
            throw error
        }
    }

    func cachedSessionListPage(workspace: AgentWorkspace, minimumLimit: Int) -> SessionsPage? {
        cachedSessionListEntry(workspace: workspace, minimumLimit: minimumLimit)?.page
    }

    func cachedSessionListEntry(
        workspace: AgentWorkspace,
        minimumLimit: Int
    ) -> SessionListFirstPageCacheEntry? {
        sessionListFirstPageCacheByKey
            .filter { entry in
                entry.key.connectionGeneration == appStore.connectionGeneration
                    && entry.key.workspaceID == workspace.id
                    && entry.key.workspacePath == workspace.path
                    && entry.key.limit >= minimumLimit
            }
            .max { $0.value.loadedAt < $1.value.loadedAt }?
            .value
    }

    func sessionListBudgetKey(for workspace: AgentWorkspace) -> SessionListBudgetKey {
        let workspacePath = standardizedSessionListPath(workspace.path)
        let rootPath = workspace.rootProjectPath.map(standardizedSessionListPath)
        let cwd: String
        if let rootPath, workspacePath == rootPath || workspacePath.hasPrefix(rootPath == "/" ? "/" : rootPath + "/") {
            cwd = rootPath
        } else {
            cwd = workspacePath
        }
        return SessionListBudgetKey(connectionGeneration: appStore.connectionGeneration, cwd: cwd)
    }

    func standardizedSessionListPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    func sessionListCooldownDelayNanoseconds(for workspace: AgentWorkspace) -> UInt64? {
        let key = sessionListBudgetKey(for: workspace)
        guard let until = sessionListCooldownUntilByBudgetKey[key] else { return nil }
        let remaining = until.timeIntervalSince(sessionListNow())
        guard remaining > 0 else {
            sessionListCooldownUntilByBudgetKey.removeValue(forKey: key)
            return nil
        }
        return UInt64(ceil(remaining * 1_000_000_000))
    }

    func registerSessionListCooldown(_ failure: SessionListPolicyFailure, for workspace: AgentWorkspace) {
        let key = sessionListBudgetKey(for: workspace)
        let until = sessionListNow().addingTimeInterval(Double(failure.retryAfterNanoseconds) / 1_000_000_000)
        if let current = sessionListCooldownUntilByBudgetKey[key], current >= until {
            return
        }
        sessionListCooldownUntilByBudgetKey[key] = until
    }

    func clearSessionListCooldown(for workspace: AgentWorkspace) {
        sessionListCooldownUntilByBudgetKey.removeValue(forKey: sessionListBudgetKey(for: workspace))
    }

    func prepareSelectedSessionAfterRefresh(_ session: AgentSession, autoAttach: Bool) async {
        await loadHistoryIfNeeded(for: session)
        if session.isRunning {
            if autoAttach && canControlSession(session) {
                // 前台恢复会反复走到这里；已加载会话的 loadHistoryIfNeeded 是 no-op，此时若做
                // 完整回放，backlog 里的旧卡会被追加到已合并的时间线后面。状态级回放已经
                // 覆盖 completed 内容，足够补齐离开期间的输出。
                connectWebSocket(session, replayBufferedEvents: false)
            } else if !canControlSession(session) {
                disconnectWebSocket()
            }
        } else if autoAttach {
            // 非运行会话回前台也重新订阅：连接重建后 resume 的权威状态能纠正误判，
            // 期间完成的输出走状态级回放 + 静默补拉，不再依赖手动刷新。
            connectWebSocket(session, replayBufferedEvents: false, allowNonRunning: true)
            scheduleQuietHistoryRefresh(for: session)
        } else if connectedSessionID != nil {
            disconnectWebSocket()
        }
    }

    static func replacingSessions(_ current: [AgentSession], with fresh: [AgentSession], projectID: String?) -> [AgentSession] {
        SessionIndexStore.replacingSessions(current, with: fresh, projectID: projectID)
    }

    func replaceSessionsIfChanged(with fresh: [AgentSession], projectID: String?) {
        let nextFresh = fresh.map(sessionPreparedForStorage)
        let next = Self.replacingSessions(sessions, with: nextFresh, projectID: projectID)
        ingestSessionContexts(next)
        guard next != sessions else {
            return
        }
        sessions = next
    }

    func pageSessionsPreservingSelection(_ fresh: [AgentSession], projectID: String) -> [AgentSession] {
        guard let selectedSessionID,
              let selected = sessionsByID[selectedSessionID],
              selected.projectID == projectID,
              !fresh.contains(where: { $0.id == selected.id }),
              shouldRetainSessionMissingFromFreshPage(selected)
        else {
            return fresh
        }
        // 分页首屏只取最近会话；如果用户当前停在更旧的历史，会话行必须保留，
        // 否则前台刷新会把右侧正在看的上下文从列表索引里踢掉。
        return fresh + [selected]
    }

    func pageSessionsPreservingLoadedWindow(
        _ fresh: [AgentSession],
        projectID: String,
        preserveAllLoaded: Bool = false
    ) -> [AgentSession] {
        acknowledgeRecentActivityProjections(in: fresh)
        let freshIDs = Set(fresh.map(\.id))
        recordRunningSessionsMissingFromFreshPage(freshIDs: freshIDs, projectID: projectID)
        var result = pageSessionsPreservingSelection(fresh, projectID: projectID)
        var knownIDs = Set(result.map(\.id))
        let projectedSessions = sessions(forProjectID: projectID).filter { session in
            guard recentActivityProjectionBySessionID[session.id] != nil,
                  shouldRetainSessionMissingFromFreshPage(session),
                  !knownIDs.contains(session.id) else {
                return false
            }
            knownIDs.insert(session.id)
            return true
        }
        // 新建/发送后的列表请求可能命中旧缓存或旧的 single-flight 响应；服务端列表确认前不能删掉本地最近项。
        result.append(contentsOf: projectedSessions)
        let knownRunningSessions = sessions(forProjectID: projectID).filter { session in
            guard session.isRunning,
                  shouldRetainSessionMissingFromFreshPage(session),
                  !knownIDs.contains(session.id) else {
                return false
            }
            knownIDs.insert(session.id)
            return true
        }
        // thread/list 的索引可能短暂落后于实时事件：先短暂保留，连续缺失后用
        // thread/read 校准。读取也失败时最多保留 3 个刷新周期，不能形成永久幽灵运行态。
        result.append(contentsOf: knownRunningSessions)

        guard preserveAllLoaded || isShowingAllSessions(projectID: projectID) else {
            return result
        }

        let olderLoadedSessions = sessions(forProjectID: projectID).filter { session in
            guard shouldRetainSessionMissingFromFreshPage(session),
                  !knownIDs.contains(session.id) else {
                return false
            }
            knownIDs.insert(session.id)
            return true
        }
        guard !olderLoadedSessions.isEmpty else {
            return result
        }
        // 用户已经展开/翻页看到的旧会话属于本地分页窗口；后台首屏刷新只更新最新状态，
        // 不能把这些旧页踢掉，否则列表会在轮询后从“图二”回跳到“图一”。
        result.append(contentsOf: olderLoadedSessions)
        return result
    }

    func recordRunningSessionsMissingFromFreshPage(freshIDs: Set<SessionID>, projectID: String) {
        let runningSessions = sessions(forProjectID: projectID).filter(\.isRunning)
        let runningIDs = Set(runningSessions.map(\.id))

        // 当前页重新出现、或实时事件已把它改成终态时，连续缺失计数立即失效。
        let resolvedSessionIDs: [SessionID] = missingRunningSessionStateByID.compactMap { element in
            let (sessionID, state) = element
            guard state.projectID == projectID,
                  freshIDs.contains(sessionID) || !runningIDs.contains(sessionID) else {
                return nil
            }
            return sessionID
        }
        for sessionID in resolvedSessionIDs {
            missingRunningSessionStateByID.removeValue(forKey: sessionID)
        }

        for session in runningSessions where !freshIDs.contains(session.id) {
            let previous = missingRunningSessionStateByID[session.id]?.consecutiveRefreshMisses ?? 0
            let nextMisses = previous + 1
            missingRunningSessionStateByID[session.id] = MissingRunningSessionState(
                projectID: projectID,
                consecutiveRefreshMisses: nextMisses
            )
            if nextMisses >= Self.missingRunningSessionReadThreshold,
               nextMisses <= Self.maximumUnverifiedRunningSessionMisses {
                scheduleMissingRunningSessionReconciliation(session)
            }
        }
    }

    func shouldRetainSessionMissingFromFreshPage(_ session: AgentSession) -> Bool {
        guard session.isRunning,
              let state = missingRunningSessionStateByID[session.id] else {
            return true
        }
        return state.consecutiveRefreshMisses <= Self.maximumUnverifiedRunningSessionMisses
            || missingRunningSessionReconciliationTasksByID[session.id] != nil
    }

    func scheduleMissingRunningSessionReconciliation(_ session: AgentSession) {
        guard missingRunningSessionReconciliationTasksByID[session.id] == nil else {
            return
        }
        let sessionID = session.id
        missingRunningSessionReconciliationTasksByID[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.missingRunningSessionReconciliationTasksByID.removeValue(forKey: sessionID)
            }
            do {
                let response = try await self.clientFactory().session(
                    id: sessionID,
                    afterSeq: self.logStore.lastSeq(for: sessionID)
                )
                try Task.checkCancellation()
                let refreshed = self.session(response.session, in: self.workspaceForSession(session))
                // thread/read 是这里的权威状态：无论仍在运行还是已经完成，都从新的事实重新计数。
                self.missingRunningSessionStateByID.removeValue(forKey: sessionID)
                self.upsert(refreshed)
                if !refreshed.isRunning {
                    self.clearForegroundActivity(sessionID: sessionID)
                    self.clearRuntimeActivity(sessionID: sessionID)
                }
            } catch is CancellationError {
                return
            } catch {
                // 读取失败不猜测终态；后续刷新还会再校准一次，但未验证状态最多只保留 3 个周期。
                return
            }
        }
    }

    func sessions(_ items: [AgentSession], in workspace: AgentWorkspace) -> [AgentSession] {
        items.map { session($0, in: workspace) }
    }

    func session(_ item: AgentSession, in workspace: AgentWorkspace?) -> AgentSession {
        guard let workspace else {
            return alignSessionToKnownWorkspace(item)
        }
        return AgentSession(
            id: item.id,
            projectID: workspace.id,
            project: workspace.name,
            dir: item.dir.isEmpty ? workspace.path : item.dir,
            title: item.title,
            status: item.status,
            source: item.source,
            runtimeProvider: item.runtimeProvider,
            resumeID: item.resumeID,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            recencyAt: item.recencyAt,
            preview: item.preview,
            activeTurnID: item.activeTurnID,
            lastSeq: item.lastSeq,
            revision: item.revision,
            usage: item.usage,
            rateLimit: item.rateLimit,
            pendingApproval: item.pendingApproval,
            pendingUserInput: item.pendingUserInput,
            goal: item.goal,
            context: item.context
        )
    }

    func alignSessionToKnownWorkspace(_ item: AgentSession) -> AgentSession {
        if let existing = sessionsByID[item.id],
           let workspace = workspacesByID[existing.projectID] {
            return session(item, in: workspace)
        }
        if let workspace = workspaceForPath(item.dir) {
            return session(item, in: workspace)
        }
        return item
    }

    func workspaceForSession(_ session: AgentSession) -> AgentWorkspace? {
        workspacesByID[session.projectID] ?? workspaceForPath(session.dir)
    }

    func workspaceForPath(_ rawPath: String) -> AgentWorkspace? {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return nil
        }
        return recentWorkspaces
            .filter { workspace in
                let workspacePath = workspace.path.trimmingCharacters(in: .whitespacesAndNewlines)
                return path == workspacePath || path.hasPrefix(workspacePath + "/")
            }
            .max { lhs, rhs in
                lhs.path.split(separator: "/").count < rhs.path.split(separator: "/").count
            }
    }

    func mergeSessionPage(_ pageSessions: [AgentSession]) {
        guard !pageSessions.isEmpty else {
            return
        }
        let pageSessions = pageSessions.map(sessionPreparedForStorage)
        ingestSessionContexts(pageSessions)
        var next = sessions
        var indexByID = sessionIndexByID
        for session in pageSessions {
            if let index = indexByID[session.id], next.indices.contains(index) {
                next[index] = session
            } else {
                indexByID[session.id] = next.count
                next.append(session)
            }
        }
        guard next != sessions else {
            return
        }
        sessions = next
    }

    func updateSessionPageState(projectID: String, page: SessionsPage) {
        if let cursor = page.nextCursor, page.hasMore {
            sessionPageCursorByProjectID[projectID] = cursor
            sessionHasMoreByProjectID[projectID] = true
        } else {
            sessionPageCursorByProjectID.removeValue(forKey: projectID)
            sessionHasMoreByProjectID[projectID] = false
        }
        rebuildProjectSessionListSnapshot(forProjectID: projectID)
    }

    func updateHistoryPageState(
        sessionID: SessionID,
        page: HistoryMessagesPage,
        preserveExistingCursorOnEmptyPage: Bool
    ) {
        recordHistorySnapshotSeq(page.snapshotSeq, sessionID: sessionID)
        if let cursor = page.previousCursor, page.hasMoreBefore {
            historyPreviousCursorBySessionID[sessionID] = cursor
            historyHasMoreBeforeBySessionID[sessionID] = true
        } else if preserveExistingCursorOnEmptyPage,
                  page.messages.isEmpty,
                  historyPreviousCursorBySessionID[sessionID] != nil {
            // resume/刷新首屏偶发空页时不要丢掉已有 older cursor。用户主动点“加载更早”
            // 的请求仍会传 false，让后端空页可以明确关闭分页入口。
            historyHasMoreBeforeBySessionID[sessionID] = true
        } else {
            historyPreviousCursorBySessionID.removeValue(forKey: sessionID)
            historyHasMoreBeforeBySessionID[sessionID] = false
        }
    }

    func setSessionListProjection(
        sessionID: SessionID,
        preview rawPreview: String,
        source: SessionListProjection.Source,
        clientMessageID: ClientMessageID?
    ) {
        let preview = rawPreview
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !preview.isEmpty else {
            return
        }

        let existingProjection = listProjectionBySessionID[sessionID]
        let existingSession = sessionsByID[sessionID]
        let projection = SessionListProjection(
            preview: preview,
            updatedAt: Date(),
            baseRemoteUpdatedAt: existingProjection?.baseRemoteUpdatedAt ?? existingSession?.updatedAt,
            basePreview: existingProjection?.basePreview ?? existingSession?.preview,
            source: source,
            clientMessageID: clientMessageID
        )
        listProjectionBySessionID[sessionID] = projection
        updateSession(sessionID) { item in
            item.preview = projection.preview
            item.updatedAt = projection.updatedAt
        }
        if source == .localUser {
            setSessionRecentActivityProjection(sessionID: sessionID, clientMessageID: clientMessageID)
        }
    }

    func clearSessionListProjection(sessionID: SessionID, clientMessageID: ClientMessageID?) {
        guard let projection = listProjectionBySessionID[sessionID] else {
            return
        }
        if let clientMessageID,
           let projectionClientID = projection.clientMessageID,
           projectionClientID != clientMessageID {
            return
        }
        listProjectionBySessionID.removeValue(forKey: sessionID)
        updateSession(sessionID) { item in
            item.preview = projection.basePreview
            item.updatedAt = projection.baseRemoteUpdatedAt ?? item.updatedAt
        }
    }

    func moveSessionListProjection(from sourceSessionID: SessionID, to targetSessionID: SessionID, clientMessageID: ClientMessageID?) {
        guard sourceSessionID != targetSessionID,
              let projection = listProjectionBySessionID[sourceSessionID]
        else {
            return
        }
        if let clientMessageID,
           let projectionClientID = projection.clientMessageID,
           projectionClientID != clientMessageID {
            return
        }
        listProjectionBySessionID.removeValue(forKey: sourceSessionID)
        let existing = sessionsByID[targetSessionID]
        listProjectionBySessionID[targetSessionID] = SessionListProjection(
            preview: projection.preview,
            updatedAt: projection.updatedAt,
            baseRemoteUpdatedAt: existing?.updatedAt,
            basePreview: existing?.preview,
            source: projection.source,
            clientMessageID: projection.clientMessageID
        )
        moveSessionRecentActivityProjection(
            from: sourceSessionID,
            to: targetSessionID,
            clientMessageID: clientMessageID
        )
    }

    func optimisticSessionID(
        projectID: String,
        resume: AgentSession?,
        clientMessageID: ClientMessageID?,
        prompt: String
    ) -> SessionID? {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let clientMessageID else {
            return nil
        }
        if let resume {
            return resume.id
        }
        return "local:\(projectID):\(clientMessageID)"
    }

    func makeOptimisticSession(id: SessionID, projectID: String, prompt: String, runtimeProvider: String?) -> AgentSession {
        let project = sidebarProjectsByID[projectID] ?? projectsByID[projectID]
        let title = Self.promptTitle(prompt)
        return AgentSession(
            id: id,
            projectID: projectID,
            project: project?.name ?? projectID,
            dir: project?.path ?? "",
            title: title,
            status: "running",
            source: Self.optimisticSessionSource,
            runtimeProvider: runtimeProvider,
            resumeID: nil,
            createdAt: Date(),
            updatedAt: Date(),
            preview: prompt
        )
    }

    func removeSession(_ id: SessionID) {
        guard let index = sessionIndexByID[id] else {
            return
        }
        var next = sessions
        next.remove(at: index)
        sessions = next
        listProjectionBySessionID.removeValue(forKey: id)
        recentActivityProjectionBySessionID.removeValue(forKey: id)
        clearRuntimeActivity(sessionID: id)
    }

    func migrateForegroundActivity(from sourceSessionID: SessionID, to targetSessionID: SessionID) {
        guard sourceSessionID != targetSessionID,
              let activity = foregroundActivityBySessionID[sourceSessionID] else {
            return
        }
        foregroundActivityBySessionID.removeValue(forKey: sourceSessionID)
        foregroundActivityBySessionID[targetSessionID] = activity
        foregroundActivityClearTasks[targetSessionID]?.cancel()
        foregroundActivityClearTasks[targetSessionID] = foregroundActivityClearTasks.removeValue(forKey: sourceSessionID)
    }

    func migrateRuntimeActivity(from sourceSessionID: SessionID, to targetSessionID: SessionID) {
        guard sourceSessionID != targetSessionID,
              let activity = runtimeActivityBySessionID[sourceSessionID] else {
            return
        }
        runtimeActivityBySessionID.removeValue(forKey: sourceSessionID)
        runtimeActivityBySessionID[targetSessionID] = activity
    }

    // 会话列表请求是按 project 并发的：用户快速切项目、刷新、展开加载更多时，
    // 旧响应可能晚于新响应返回。每次请求递增 token，落库前只接受当前 token。
    func beginSessionPageRequest(projectID: String) -> Int {
        let token = (sessionPageRequestTokenByProjectID[projectID] ?? 0) + 1
        sessionPageRequestTokenByProjectID[projectID] = token
        sessionPageLoadingTokenByProjectID[projectID] = token
        rebuildProjectSessionListSnapshot(forProjectID: projectID)
        return token
    }

    func finishSessionPageRequest(projectID: String, token: Int) {
        guard sessionPageLoadingTokenByProjectID[projectID] == token else {
            return
        }
        sessionPageLoadingTokenByProjectID.removeValue(forKey: projectID)
        rebuildProjectSessionListSnapshot(forProjectID: projectID)
    }

    func isCurrentSessionPageRequest(projectID: String, token: Int) -> Bool {
        sessionPageRequestTokenByProjectID[projectID] == token
    }

    func beginHistoryLoadJob(sessionID: SessionID) -> Int {
        let token = (historyLoadJobTokenBySessionID[sessionID] ?? 0) + 1
        historyLoadJobTokenBySessionID[sessionID] = token
        return token
    }

    // 历史首屏也会并发触发：点选历史、前台恢复、手动刷新都可能同时请求 before=nil。
    // 只接受最新 token，避免旧 rollout 快照晚到后覆盖较新的消息投影和分页 cursor。
    func beginHistoryPageRequest(sessionID: SessionID) -> Int {
        let token = (historyPageRequestTokenBySessionID[sessionID] ?? 0) + 1
        historyPageRequestTokenBySessionID[sessionID] = token
        return token
    }

    func isCurrentHistoryPageRequest(sessionID: SessionID, token: Int) -> Bool {
        historyPageRequestTokenBySessionID[sessionID] == token
    }

    func rebuildProjectIndex() {
        var byID: [String: AgentProject] = [:]
        byID.reserveCapacity(projects.count)
        for project in projects {
            byID[project.id] = project
        }
        projectsByID = byID
    }

    func rebuildWorkspaceIndex() {
        var byID: [String: AgentWorkspace] = [:]
        byID.reserveCapacity(recentWorkspaces.count)
        for workspace in recentWorkspaces {
            byID[workspace.id] = workspace
        }
        workspacesByID = byID
        setSidebarProjectsIfChanged(recentWorkspaces.map(\.project))
    }

    func rebuildSessionIndexes() {
        var byID: [SessionID: AgentSession] = [:]
        var indexByID: [SessionID: Int] = [:]
        byID.reserveCapacity(sessions.count)
        indexByID.reserveCapacity(sessions.count)
        for (index, session) in sessions.enumerated() {
            byID[session.id] = session
            indexByID[session.id] = index
        }
        sessionsByID = byID
        sessionIndexByID = indexByID
        pruneSessionScopedState(validSessionIDs: Set(byID.keys))

        // 和 Codex/Litter 的 snapshot 思路一致：Store 在数据变更时生成排序/分组投影，
        // SwiftUI 列表渲染时只读取缓存，避免每个项目行反复 filter + sort。
        let listableSessions = sessions.filter(isListableSession)
        let sorted = sortedSessionsForList(listableSessions)
        if sessions.contains(where: \.isRunning) {
            let previousOrder = frozenAllSessionOrder.isEmpty ? Self.sessionIDs(sortedAllSessions) : frozenAllSessionOrder
            let frozen = Self.applyFrozenOrder(to: sorted, previousOrder: previousOrder)
            sortedAllSessions = frozen
            frozenAllSessionOrder = Self.sessionIDs(frozen)
        } else {
            sortedAllSessions = sorted
            frozenAllSessionOrder = []
        }

        var naturalGrouped: [String: [AgentSession]] = [:]
        naturalGrouped.reserveCapacity(sidebarProjects.count)
        for session in sorted {
            naturalGrouped[session.projectID, default: []].append(session)
        }

        var runningProjectIDs: Set<String> = []
        runningProjectIDs.reserveCapacity(naturalGrouped.count)
        for session in listableSessions where session.isRunning {
            runningProjectIDs.insert(session.projectID)
        }
        var grouped: [String: [AgentSession]] = [:]
        grouped.reserveCapacity(naturalGrouped.count)
        for (projectID, projectSessions) in naturalGrouped {
            guard runningProjectIDs.contains(projectID) else {
                grouped[projectID] = projectSessions
                frozenSessionOrderByProjectID.removeValue(forKey: projectID)
                continue
            }
            let previousOrder = frozenSessionOrderByProjectID[projectID]
                ?? sortedSessionsByProjectID[projectID].map(Self.sessionIDs)
                ?? Self.sessionIDs(projectSessions)
            let frozen = Self.applyFrozenOrder(to: projectSessions, previousOrder: previousOrder)
            grouped[projectID] = frozen
            frozenSessionOrderByProjectID[projectID] = Self.sessionIDs(frozen)
        }
        frozenSessionOrderByProjectID = frozenSessionOrderByProjectID.filter { runningProjectIDs.contains($0.key) }
        sortedSessionsByProjectID = grouped

        var previews: [String: [AgentSession]] = [:]
        var hiddenCounts: [String: Int] = [:]
        previews.reserveCapacity(grouped.count)
        hiddenCounts.reserveCapacity(grouped.count)
        for (projectID, projectSessions) in grouped {
            let visibleSessions = Self.lifecycleVisibleSessions(
                projectSessions,
                limit: Self.sessionPreviewLimit
            )
            let hiddenCount = max(0, projectSessions.count - visibleSessions.count)
            hiddenCounts[projectID] = hiddenCount
            // 侧栏每次 body 计算都会读取可见会话。像 Litter 的派生模型一样提前保存预览窗口，
            // 避免多个项目行在刷新时重复构造 prefix 数组。
            previews[projectID] = visibleSessions
        }
        previewSessionsByProjectID = previews
        hiddenSessionCountByProjectID = hiddenCounts
        rebuildProjectSessionListSnapshots()
    }

    func makeProjectSessionListSnapshot(forProjectID projectID: String) -> ProjectSessionListSnapshot {
        let baseSessions = sortedSessionsByProjectID[projectID] ?? []
        if isSessionSearchActive {
            let matchingSessions = sessionsMatchingSearch(sessionsIncludingRemoteSearch(baseSessions, projectID: projectID))
            return ProjectSessionListSnapshot(
                projectID: projectID,
                isExpanded: true,
                isShowingAll: true,
                visibleSessions: matchingSessions,
                allSessionCount: matchingSessions.count,
                hiddenCount: 0,
                canLoadMore: false,
                isLoadingMore: false,
                hasCollapsedPreview: false
            )
        }

        let allSessions = baseSessions
        let visibleLimit = sessionVisibleLimit(forProjectID: projectID)
        let visibleSessions = Self.lifecycleVisibleSessions(allSessions, limit: visibleLimit)
        let isShowingAll = visibleLimit > Self.sessionPreviewLimit

        return ProjectSessionListSnapshot(
            projectID: projectID,
            isExpanded: expandedProjectIDs.contains(projectID),
            isShowingAll: isShowingAll,
            visibleSessions: visibleSessions,
            allSessionCount: allSessions.count,
            hiddenCount: max(0, allSessions.count - visibleSessions.count),
            canLoadMore: canLoadMoreSessions(projectID: projectID),
            isLoadingMore: sessionPageLoadingTokenByProjectID[projectID] != nil,
            hasCollapsedPreview: allSessions.count > Self.sessionPreviewLimit
        )
    }

    /// 项目折叠时仍要完整保留运行态；历史会话只负责填满剩余预览位。
    /// 这样即使排序被冻结、运行任务不在前三条，也不会被“显示更多”折叠掉。
    static func lifecycleVisibleSessions(
        _ sessions: [AgentSession],
        limit: Int
    ) -> [AgentSession] {
        let normalizedLimit = max(0, limit)
        guard sessions.count > normalizedLimit else {
            return sessions
        }
        let active = sessions.filter(\.isRunning)
        guard !active.isEmpty else {
            return Array(sessions.prefix(normalizedLimit))
        }
        let historyLimit = max(0, normalizedLimit - active.count)
        return active + Array(sessions.lazy.filter { !$0.isRunning }.prefix(historyLimit))
    }

    func rebuildProjectSessionListSnapshot(forProjectID projectID: String) {
        let snapshot = makeProjectSessionListSnapshot(forProjectID: projectID)
        sessionListSnapshotsByProjectID[projectID] = snapshot
    }

    func rebuildProjectSessionListSnapshots() {
        var projectIDs: Set<String> = []
        projectIDs.reserveCapacity(sidebarProjects.count + sortedSessionsByProjectID.count)
        for project in sidebarProjects {
            projectIDs.insert(project.id)
        }
        projectIDs.formUnion(sortedSessionsByProjectID.keys)
        projectIDs.formUnion(expandedProjectIDs)
        projectIDs.formUnion(showingAllSessionProjectIDs)
        projectIDs.formUnion(sessionHasMoreByProjectID.keys)
        projectIDs.formUnion(sessionPageLoadingTokenByProjectID.keys)

        var snapshots: [String: ProjectSessionListSnapshot] = [:]
        snapshots.reserveCapacity(projectIDs.count)
        for projectID in projectIDs {
            snapshots[projectID] = makeProjectSessionListSnapshot(forProjectID: projectID)
        }
        sessionListSnapshotsByProjectID = snapshots
    }

    var normalizedSessionSearchQuery: String {
        Self.normalizedSearchText(sessionSearchQuery)
    }

    func scheduleRemoteSessionSearch() {
        sessionSearchTask?.cancel()
        sessionSearchTask = nil
        sessionSearchGeneration &+= 1
        let generation = sessionSearchGeneration
        let connectionGeneration = appStore.connectionGeneration
        let searchTerm = sessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        // 每个关键词只保留自身的远端投影，避免连续搜索让基础会话库永久膨胀；用户点开后
        // selectSession 会通过既有 upsert 路径正式加入 sessions，因此不会破坏选择状态。
        resetRemoteSessionSearchState()

        // 空查询只恢复本地已加载列表，不发请求，也不删除之前搜索补入的会话缓存。
        guard !searchTerm.isEmpty,
              !isNetworkUnavailable,
              connectionTermination == nil
        else {
            return
        }

        isSearchingRemoteSessionResults = true
        sessionSearchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                // 旧查询的 defer 不能清掉新查询从防抖阶段开始展示的 loading。
                if self.sessionSearchGeneration == generation {
                    self.sessionSearchTask = nil
                    self.isSearchingRemoteSessionResults = false
                }
            }
            do {
                if self.sessionSearchDebounceNanoseconds > 0 {
                    try await self.sessionSearchSleep(self.sessionSearchDebounceNanoseconds)
                }
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.sessionSearchGeneration == generation,
                  self.appStore.connectionGeneration == connectionGeneration,
                  !self.isNetworkUnavailable,
                  self.connectionTermination == nil
            else {
                return
            }

            do {
                let client = try self.clientFactory()
                let page = try await client.searchSessions(query: searchTerm, cursor: nil, limit: 50)
                // 部分 transport 在取消后仍可能交付已完成响应；generation 是最终防线，禁止旧查询污染新结果。
                guard !Task.isCancelled,
                      self.sessionSearchGeneration == generation,
                      self.appStore.connectionGeneration == connectionGeneration,
                      self.sessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == searchTerm,
                      !self.isNetworkUnavailable,
                      self.connectionTermination == nil
                else {
                    return
                }
                self.applyRemoteSessionSearchPage(page, replacing: true, requestedCursor: nil)
            } catch {
                // 搜索属于列表增强：旧服务 method unavailable、弱网或临时鉴权失败都只回退本地过滤，
                // 不能把普通搜索失败升级成全局连接/鉴权终态。
            }
        }
    }

    func resetRemoteSessionSearchState() {
        sessionSearchLoadMoreTask?.cancel()
        sessionSearchLoadMoreTask = nil
        sessionSearchLoadingCursor = nil
        remoteSessionSearchSnippetByID = [:]
        remoteSessionSearchResults = []
        sessionSearchNextCursor = nil
        sessionSearchHasMore = false
        isSearchingRemoteSessionResults = false
        isLoadingMoreSessionSearchResults = false
    }

    func cancelRemoteSessionSearchRequestsPreservingResults() {
        sessionSearchTask?.cancel()
        sessionSearchTask = nil
        sessionSearchLoadMoreTask?.cancel()
        sessionSearchLoadMoreTask = nil
        sessionSearchGeneration &+= 1
        sessionSearchLoadingCursor = nil
        isSearchingRemoteSessionResults = false
        isLoadingMoreSessionSearchResults = false
    }

    func applyRemoteSessionSearchPage(
        _ page: ThreadSearchPage,
        replacing: Bool,
        requestedCursor: String?
    ) {
        var sessionsByID: [SessionID: AgentSession] = [:]
        var snippetsByID: [SessionID: String] = replacing ? [:] : remoteSessionSearchSnippetByID
        if !replacing {
            for session in remoteSessionSearchResults {
                sessionsByID[session.id] = session
            }
        }

        for result in page.results {
            let alignedSession = alignSessionToKnownWorkspace(result.session)
            sessionsByID[alignedSession.id] = alignedSession
            let snippet = result.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            if snippet.isEmpty {
                snippetsByID.removeValue(forKey: alignedSession.id)
            } else {
                // 后续页若重复返回同一 thread，以新 snippet 为准；canonical sessions 始终不参与写入。
                snippetsByID[alignedSession.id] = snippet
            }
        }

        remoteSessionSearchSnippetByID = snippetsByID
        remoteSessionSearchResults = Self.sortedSessions(Array(sessionsByID.values))

        let nextCursor = page.nextCursor.flatMap { cursor in
            cursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : cursor
        }
        let canContinue = nextCursor != nil && nextCursor != requestedCursor
        sessionSearchNextCursor = canContinue ? nextCursor : nil
        sessionSearchHasMore = canContinue
    }

    func sessionsIncludingRemoteSearch(
        _ base: [AgentSession],
        projectID: String? = nil
    ) -> [AgentSession] {
        guard isSessionSearchActive, !remoteSessionSearchResults.isEmpty else {
            return base
        }
        let remote = remoteSessionSearchResults.filter { session in
            projectID == nil || session.projectID == projectID
        }
        guard !remote.isEmpty else {
            return base
        }
        // 同一 ID 保留基础会话的权威状态/preview；snippet 单独展示，不能因一次搜索覆盖 canonical session。
        var combined = base
        let baseIDs = Set(base.map(\.id))
        combined.append(contentsOf: remote.filter { !baseIDs.contains($0.id) })
        return Self.sortedSessions(combined)
    }

    func sessionsMatchingSearch(_ items: [AgentSession]) -> [AgentSession] {
        let query = normalizedSessionSearchQuery
        guard !query.isEmpty else {
            return items
        }
        // 搜索只作用于已加载会话投影，不改原始 sessions；这样清空搜索后能恢复分页、冻结顺序和选择状态。
        let remoteResultIDs = Set(remoteSessionSearchResults.map(\.id))
        // Codex 可能按 token/FTS 命中，snippet 不保证包含完整连续查询；远端结果应视为已经命中，
        // 这里只对普通本地会话继续做 literal contains 过滤。
        return items.filter { remoteResultIDs.contains($0.id) || sessionMatchesSearch($0, query: query) }
    }

    func sessionMatchesSearch(_ session: AgentSession, query: String) -> Bool {
        [
            session.title,
            session.preview,
            session.project,
            session.dir,
            session.displayStatusText,
            session.id,
            session.resumeID
        ].contains { value in
            Self.normalizedSearchText(value ?? "").contains(query)
        }
    }

    func isListableSession(_ session: AgentSession) -> Bool {
        !archivedSessionIDs.contains(session.id) || session.id == selectedSessionID || session.isRunning
    }

    func projectMatchesSearch(_ project: AgentProject) -> Bool {
        let query = normalizedSessionSearchQuery
        guard !query.isEmpty else {
            return true
        }
        return [
            project.name,
            project.path,
            project.id
        ].contains { value in
            Self.normalizedSearchText(value).contains(query)
        }
    }

    static func normalizedSearchText(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    func pruneSessionScopedState(validSessionIDs: Set<SessionID>) {
        // 会话分页只保留当前已知列表和被选中保留的 session；旧 session 的 cursor/token/activity
        // 继续留在字典里没有业务价值，长时间浏览大量历史时还会慢慢堆内存。
        historyPreviousCursorBySessionID = historyPreviousCursorBySessionID.filter { validSessionIDs.contains($0.key) }
        historyHasMoreBeforeBySessionID = historyHasMoreBeforeBySessionID.filter { validSessionIDs.contains($0.key) }
        historySnapshotSeqBySessionID = historySnapshotSeqBySessionID.filter { validSessionIDs.contains($0.key) }
        historyPageRequestTokenBySessionID = historyPageRequestTokenBySessionID.filter { validSessionIDs.contains($0.key) }
        historyLoadProgressBySessionID = historyLoadProgressBySessionID.filter { validSessionIDs.contains($0.key) }
        let staleHistoryLoadJobIDs = historyLoadJobsBySessionID.keys.filter { !validSessionIDs.contains($0) }
        for sessionID in staleHistoryLoadJobIDs {
            historyLoadJobsBySessionID[sessionID]?.task.cancel()
            historyLoadJobsBySessionID.removeValue(forKey: sessionID)
        }
        historyLoadJobTokenBySessionID = historyLoadJobTokenBySessionID.filter { validSessionIDs.contains($0.key) }
        historyLoadedSignatureBySessionID = historyLoadedSignatureBySessionID.filter { validSessionIDs.contains($0.key) }
        historyLoadedQualityBySessionID = historyLoadedQualityBySessionID.filter { validSessionIDs.contains($0.key) }
        let staleHistoryFirstPageKeys = historyFirstPageInFlightByKey.keys.filter { !validSessionIDs.contains($0.sessionID) }
        for key in staleHistoryFirstPageKeys {
            historyFirstPageInFlightByKey[key]?.task.cancel()
            historyFirstPageInFlightByKey.removeValue(forKey: key)
        }
        historyFirstPageCacheByKey = historyFirstPageCacheByKey.filter { validSessionIDs.contains($0.key.sessionID) }
        historySavingsNoticesBySessionID = historySavingsNoticesBySessionID.filter { validSessionIDs.contains($0.key) }
        listProjectionBySessionID = listProjectionBySessionID.filter { validSessionIDs.contains($0.key) }
        recentActivityProjectionBySessionID = recentActivityProjectionBySessionID.filter { validSessionIDs.contains($0.key) }
        initialHistoryLoadingSessionIDs.formIntersection(validSessionIDs)
        missingRunningSessionStateByID = missingRunningSessionStateByID.filter { sessionID, _ in
            validSessionIDs.contains(sessionID) || missingRunningSessionReconciliationTasksByID[sessionID] != nil
        }

        let loadingEarlierSessionIDs = loadingEarlierHistorySessionIDs.intersection(validSessionIDs)
        if loadingEarlierSessionIDs != loadingEarlierHistorySessionIDs {
            loadingEarlierHistorySessionIDs = loadingEarlierSessionIDs
        }

        let staleActivitySessionIDs = Set(foregroundActivityBySessionID.keys).subtracting(validSessionIDs)
        for sessionID in staleActivitySessionIDs {
            foregroundActivityClearTasks[sessionID]?.cancel()
            foregroundActivityClearTasks.removeValue(forKey: sessionID)
        }
        lastSeenEventSeqBySessionID = lastSeenEventSeqBySessionID.filter { validSessionIDs.contains($0.key) }
        let foregroundActivities = foregroundActivityBySessionID.filter { validSessionIDs.contains($0.key) }
        if foregroundActivities != foregroundActivityBySessionID {
            foregroundActivityBySessionID = foregroundActivities
        }
        let runtimeActivities = runtimeActivityBySessionID.filter { validSessionIDs.contains($0.key) }
        if runtimeActivities != runtimeActivityBySessionID {
            runtimeActivityBySessionID = runtimeActivities
        }
    }

    static func sortedSessions(_ items: [AgentSession]) -> [AgentSession] {
        SessionIndexStore.sortedSessions(items)
    }

    func sortedSessionsForList(_ items: [AgentSession]) -> [AgentSession] {
        let sorted = Self.sortedSessions(items)
        let indexByID = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($0.element.id, $0.offset) })
        return sorted.sorted { lhs, rhs in
            let leftPinned = pinnedSessionIDs.contains(lhs.id)
            let rightPinned = pinnedSessionIDs.contains(rhs.id)
            if leftPinned != rightPinned {
                return leftPinned
            }
            return (indexByID[lhs.id] ?? 0) < (indexByID[rhs.id] ?? 0)
        }
    }

    static func applyFrozenOrder(to items: [AgentSession], previousOrder: [SessionID]) -> [AgentSession] {
        guard !items.isEmpty, !previousOrder.isEmpty else {
            return items
        }
        let previousIDs = Set(previousOrder)
        var byID: [SessionID: AgentSession] = [:]
        byID.reserveCapacity(items.count)
        for item in items {
            byID[item.id] = item
        }
        var result: [AgentSession] = []
        result.reserveCapacity(items.count)

        // 新会话仍按当前排序排在前面；已有会话沿用冻结顺序，避免 running 输出刷新 updatedAt 时侧栏上下跳。
        for item in items where !previousIDs.contains(item.id) {
            result.append(item)
        }
        for id in previousOrder {
            if let item = byID[id] {
                result.append(item)
            }
        }
        return result
    }

    static func sessionIDs(_ items: [AgentSession]) -> [SessionID] {
        var ids: [SessionID] = []
        ids.reserveCapacity(items.count)
        for item in items {
            ids.append(item.id)
        }
        return ids
    }

    static func projectIDs(_ items: [AgentProject]) -> Set<String> {
        var ids: Set<String> = []
        ids.reserveCapacity(items.count)
        for item in items {
            ids.insert(item.id)
        }
        return ids
    }

}
