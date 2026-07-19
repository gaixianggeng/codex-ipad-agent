import Foundation

// 启动恢复、项目选择与 Worktree 生命周期从稳定外观 API 中拆出。
extension SessionStore {
    func bootstrap(restoring snapshot: SessionRestoreSnapshot? = nil) async {
#if DEBUG
        if appStore.shouldSeedDebugWorkbenchUI {
            applyDebugWorkbenchUISeedIfNeeded()
            return
        }
#endif
        guard appStore.isConfigured else {
            return
        }
        // 冷启动有两层“没就绪”：① VPN / Tailscale 隧道还没建好，首个 HTTP 请求就失败；
        // ② agentd 的 HTTP 端口先于 app-server gateway 上游就绪——projects 能立刻拿到，但首个
        // 会话请求 / WebSocket 连接会因为上游还没接受连接而失败。scenePhase 的 .active 回调在
        // 冷启动不会触发（没有 background→active 切换），所以这里必须自己退避重试，直到数据
        // 真正加载完成。否则只要 projects 一到手就收手，首屏会停在“有项目、无会话、点什么都
        // 连不上”的半成品状态，只能靠用户杀进程重开才恢复。
        await refreshUntilLoaded(maxWait: 45, autoAttach: true)
        if let snapshot {
            await restoreSessionIfPossible(snapshot)
        }
    }

    func restoreSessionIfPossible(_ snapshot: SessionRestoreSnapshot) async {
        guard AgentAPIClient.normalizedEndpoint(snapshot.endpoint) == AgentAPIClient.normalizedEndpoint(appStore.endpoint),
              let workspace = ensureWorkspaceForKnownProjectID(snapshot.session.projectID)
        else { return }

        // 先让 runtime 从真实 thread/list 建立 session→provider 路由；旧会话不在首屏时再使用本地轻量快照。
        do {
            let page = try await sessionListFirstPage(workspace: workspace, limit: Self.initialSessionPageLimit, reuseRecent: true)
            mergeSessionPage(sessions(page.sessions, in: workspace))
            updateSessionPageState(projectID: workspace.id, page: page)
        } catch {
            // 恢复快照仍须经过工作区授权校验；单次列表失败不应让用户丢掉上次阅读位置。
        }

        let restored = sessionsByID[snapshot.session.id] ?? session(snapshot.session, in: workspace)
        guard restored.projectID == workspace.id else { return }
        mergeSessionPage([restored])
        await selectSession(restored)
    }

#if DEBUG
    func applyDebugWorkbenchUISeedIfNeeded() {
        guard !didApplyDebugWorkbenchUISeed else {
            return
        }
        didApplyDebugWorkbenchUISeed = true

        let now = Date()
        let debugRateLimit = RateLimitSummary(
            limitName: "Codex",
            planType: "pro",
            primaryUsedPercent: 42,
            secondaryUsedPercent: 27,
            primaryResetsAt: Int64(now.addingTimeInterval(60 * 82).timeIntervalSince1970),
            secondaryResetsAt: Int64(now.addingTimeInterval(60 * 60 * 24 * 3).timeIntervalSince1970),
            primaryWindowDurationMins: 300,
            secondaryWindowDurationMins: 10_080,
            hasCredits: false,
            creditsUnlimited: false,
            creditBalance: nil
        )
        let mimiDemo = AgentWorkspace(
            id: "debug-mimi-demo",
            name: "mimi-remote",
            path: "/Users/demo/code/mimi-remote",
            rootProjectID: "debug-mimi-demo",
            rootProjectName: "mimi-remote",
            rootProjectPath: "/Users/demo/code/mimi-remote",
            lastOpenedAt: now.addingTimeInterval(-60 * 8)
        )
        let sampleApp = AgentWorkspace(
            id: "debug-sample-app",
            name: "sample-app",
            path: "/Users/demo/code/sample-app",
            rootProjectID: "debug-sample-app",
            rootProjectName: "sample-app",
            rootProjectPath: "/Users/demo/code/sample-app",
            lastOpenedAt: now.addingTimeInterval(-60 * 35)
        )
        let selectedSessionID = "debug-session-layout"
        let runningSessionID = "debug-session-running"
        let sessions = [
            AgentSession(
                id: selectedSessionID,
                projectID: mimiDemo.id,
                project: mimiDemo.name,
                dir: mimiDemo.path,
                title: L10n.text("ui.organize_open_source_release_notes"),
                status: SessionStatus.completed.rawValue,
                source: "debug",
                runtimeProvider: "codex",
                resumeID: selectedSessionID,
                createdAt: now.addingTimeInterval(-60 * 40),
                updatedAt: now.addingTimeInterval(-60 * 3),
                preview: L10n.text("ui.review_installation_steps_architecture_diagrams_privacy_boundaries_and"),
                rateLimit: debugRateLimit
            ),
            AgentSession(
                id: runningSessionID,
                projectID: mimiDemo.id,
                project: mimiDemo.name,
                dir: mimiDemo.path,
                title: L10n.text("ui.check_connection_recovery_test"),
                status: SessionStatus.running.rawValue,
                source: "debug",
                runtimeProvider: "codex",
                resumeID: runningSessionID,
                createdAt: now.addingTimeInterval(-60 * 110),
                updatedAt: now.addingTimeInterval(-60 * 1),
                preview: L10n.text("ui.verifying_disconnection_recovery_approval_and_queued_message_status"),
                activeTurnID: "debug-turn-running"
            ),
            AgentSession(
                id: "debug-session-workspace",
                projectID: sampleApp.id,
                project: sampleApp.name,
                dir: sampleApp.path,
                title: L10n.text("ui.improve_sample_project_documentation"),
                status: SessionStatus.closed.rawValue,
                source: "debug",
                runtimeProvider: "codex",
                resumeID: "debug-session-workspace",
                createdAt: now.addingTimeInterval(-60 * 180),
                updatedAt: now.addingTimeInterval(-60 * 28),
                preview: L10n.text("ui.supplemented_with_executable_commands_configuration_examples_and_troubleshooting")
            )
        ]

        isLoading = false
        setErrorMessage(nil)
        setStatusMessage(L10n.text("ui.debug_ui_sample_loaded"))
        setProjectsIfChanged([mimiDemo.project, sampleApp.project])
        setRecentWorkspacesIfChanged([mimiDemo, sampleApp])
        sessionWorkspaceIDs = nil
        setExpandedProjectIDs([mimiDemo.id])
        replaceSessionsIfChanged(with: sessions, projectID: nil)
        setSelectedProjectID(mimiDemo.id)
        setSelectedSessionID(appStore.shouldSeedDebugQueuedTurnsUI ? runningSessionID : selectedSessionID)
        if appStore.shouldSeedDebugQueuedTurnsUI {
            // 队列样例需要处于可控的运行中会话，才能同时验收“排队（默认）/引导”切换；
            // 普通 Debug 工作台仍保留原来的观察态样例，不改变其接管流程覆盖。
            setSessionControlState(.takenOver, sessionID: runningSessionID)
        }
        webSocketStatus = .disconnected
        disconnectWebSocket()
        seedDebugConversationMessages(sessionID: selectedSessionID, now: now)
        seedDebugConversationMessages(sessionID: runningSessionID, now: now.addingTimeInterval(-60 * 10))
        // 调试样例保留两种关键队列态，便于在模拟器直接验收托盘、编辑和歧义重试 UI；
        // 只写内存，不污染真实连接档案的持久化队列。
        queuedRunningTurnsBySessionID[runningSessionID] = [
            QueuedTurnEntry(
                sessionID: runningSessionID,
                projectID: mimiDemo.id,
                payload: CodexAppServerTurnPayload(prompt: L10n.text("ui.after_the_current_reply_is_complete_continue_checking")),
                clientMessageID: "debug-queued-waiting",
                intent: .standard,
                expectedTurnID: "debug-turn-running"
            ),
            QueuedTurnEntry(
                sessionID: runningSessionID,
                projectID: mimiDemo.id,
                payload: CodexAppServerTurnPayload(prompt: L10n.text("ui.after_confirming_that_the_security_scan_is_complete")),
                clientMessageID: "debug-queued-confirmation",
                intent: .standard,
                dispatchState: .needsConfirmation,
                lastError: L10n.text("ui.last_send_interrupted_before_confirmation")
            )
        ]
        rebuildProjectSessionListSnapshots()
    }

    func seedDebugConversationMessages(sessionID: SessionID, now: Date) {
        let history = [
            CodexHistoryMessage(
                id: "\(sessionID)-user-1",
                role: "user",
                content: L10n.text("ui.help_me_check_this_readme_change_and_confirm"),
                createdAt: now.addingTimeInterval(-60 * 18),
                turnID: "\(sessionID)-turn-1",
                itemID: "\(sessionID)-item-user-1",
                timelineOrdinal: 1
            ),
            CodexHistoryMessage(
                id: "\(sessionID)-assistant-1",
                role: "assistant",
                content: L10n.text("ui.i_ll_go_over_homebrew_source_build_and"),
                createdAt: now.addingTimeInterval(-60 * 16),
                turnID: "\(sessionID)-turn-1",
                itemID: "\(sessionID)-item-assistant-1",
                timelineOrdinal: 2
            ),
            CodexHistoryMessage(
                id: "\(sessionID)-summary-1",
                role: "system",
                kind: .reasoningSummary,
                content: L10n.text("ui.document_verification_has_been_completed_the_installation_command"),
                createdAt: now.addingTimeInterval(-60 * 14),
                turnID: "\(sessionID)-turn-1",
                itemID: "\(sessionID)-item-summary-1",
                timelineOrdinal: 3
            ),
            CodexHistoryMessage(
                id: "\(sessionID)-user-2",
                role: "user",
                content: L10n.text("ui.check_again_whether_there_are_real_tokens_private"),
                createdAt: now.addingTimeInterval(-60 * 6),
                turnID: "\(sessionID)-turn-2",
                itemID: "\(sessionID)-item-user-2",
                timelineOrdinal: 4
            ),
            CodexHistoryMessage(
                id: "\(sessionID)-assistant-2",
                role: "assistant",
                content: L10n.text("ui.the_screenshot_only_uses_users_demo_and_local"),
                createdAt: now.addingTimeInterval(-60 * 4),
                turnID: "\(sessionID)-turn-2",
                itemID: "\(sessionID)-item-assistant-2",
                timelineOrdinal: 5
            )
        ]
        conversationStore.replaceHistorySnapshot(history, sessionID: sessionID)
    }

    var isDebugWorkbenchUISeedActive: Bool {
        appStore.shouldSeedDebugWorkbenchUI && didApplyDebugWorkbenchUISeed
    }
#endif

    // refreshAll 成功拿到数据、或后端确实为空时都会清空 errorMessage；只要还有 errorMessage，
    // 就说明 projects / sessions / gateway 至少有一环没就绪，需要继续重试让首屏自愈。
    //
    // 冷启动失败基本是后端还没就绪（agentd / Tailscale 未通，或 app-server 上游还没接受连接），这类失败
    // 都很快返回，所以用较短的固定退避高频轮询：后端一就绪就能在 ~1s 内被探测到并自愈，而不是用
    // 慢退避白等。按总时长封顶而非固定次数，后端晚十几二十秒才起来也能等到，不会提前放弃又卡回
    // “要杀进程”的老问题。
    func refreshUntilLoaded(maxWait: TimeInterval, autoAttach: Bool) async {
        let deadline = Date().addingTimeInterval(max(0, maxWait))
        var attempt = 0
        while true {
            await refreshAll(autoAttach: autoAttach)
            if connectionTermination != nil || appStore.requiresRePairing {
                return
            }
            if errorMessage == nil {
                return
            }
            if Task.isCancelled || Date() >= deadline {
                return
            }
            // Gateway 已明确给出 retryAfter 时必须尊重该窗口；继续按 0.3/0.9 秒探测只会把一次限流
            // 放大成重试风暴。
            if let workspace = selectedProjectID.flatMap({ workspacesByID[$0] }),
               let cooldownDelay = sessionListCooldownDelayNanoseconds(for: workspace) {
                attempt += 1
                await sessionListSleep(cooldownDelay)
                if Task.isCancelled { return }
                continue
            }
            // Tailscale 会在同一个地址下自行选择直连、Peer Relay 或 DERP；App 只需重试业务请求。
            let backoffNanoseconds: UInt64 = attempt == 0 ? 300_000_000 : 900_000_000
            attempt += 1
            await sessionListSleep(backoffNanoseconds)
            if Task.isCancelled { return }
        }
    }

    /// 连接凭据已经安全提交后，统一等待首屏数据真正可用。
    ///
    /// 这里复用冷启动的重试逻辑，避免扫码、URL Scheme 和手动连接分别维护退避策略。
    /// 超时只改变展示状态，不回滚已写入 Keychain 的 Token 或当前连接档案；一次性配对票据
    /// 已经兑换成功时，用户也可以直接重试加载，无需重新扫码。
    @discardableResult
    func refreshAfterConnectionCommit(maxWait: TimeInterval) async -> Bool {
        await refreshUntilLoaded(maxWait: maxWait, autoAttach: true)

        guard !Task.isCancelled else {
            return false
        }
        guard connectionTermination == nil,
              !appStore.requiresRePairing,
              errorMessage == nil else {
            if connectionTermination == nil, !appStore.requiresRePairing {
                let message = L10n.text("ui.the_connection_credentials_have_been_saved_safely_but")
                appStore.connectionStatus = .failed(message)
                appStore.lastError = message
                setErrorMessage(message)
            }
            return false
        }
        return true
    }

    func refreshAll(autoAttach: Bool = false) async {
#if DEBUG
        guard !isDebugWorkbenchUISeedActive else {
            setStatusMessage(L10n.text("ui.debug_ui_sample_will_not_connect_to_the"))
            return
        }
#endif
        isLoading = true
        defer { isLoading = false }
        let connectionGeneration = appStore.connectionGeneration
        var requestToken: Int?
        var requestProjectID: String?
        var activeWorkspace: AgentWorkspace?
        do {
            let client = try clientFactory()
            let previousProjectID = selectedProjectID
            let previousSessionID = selectedSessionID
            let fetchedProjects = try await client.projects()
            guard connectionGeneration == appStore.connectionGeneration else {
                return
            }
            setProjectsIfChanged(fetchedProjects)
            reloadRecentWorkspaces()
            if let previousProjectID,
               sidebarProjectsByID[previousProjectID] == nil,
               let project = projectsByID[previousProjectID] {
                _ = ensureWorkspace(for: project)
            }
            let validProjectIDs = Self.projectIDs(sidebarProjects)
            setExpandedProjectIDs(expandedProjectIDs.intersection(validProjectIDs))
            setShowingAllSessionProjectIDs(showingAllSessionProjectIDs.intersection(validProjectIDs))
            sessionPageCursorByProjectID = sessionPageCursorByProjectID.filter { validProjectIDs.contains($0.key) }
            sessionHasMoreByProjectID = sessionHasMoreByProjectID.filter { validProjectIDs.contains($0.key) }
            sessionProjectsWithAdditionalPages.formIntersection(validProjectIDs)
            sessionPageRequestTokenByProjectID = sessionPageRequestTokenByProjectID.filter { validProjectIDs.contains($0.key) }
            sessionPageLoadingTokenByProjectID = sessionPageLoadingTokenByProjectID.filter { validProjectIDs.contains($0.key) }
            rebuildProjectSessionListSnapshots()
            let projectID = previousProjectID.flatMap { id in
                sidebarProjectsByID[id] == nil ? nil : id
            } ?? (autoAttach ? sidebarProjects.first?.id : nil)
            setSelectedProjectID(projectID)
            guard let projectID else {
                replaceSessionsIfChanged(with: [], projectID: nil)
                setSelectedSessionID(nil)
                disconnectWebSocket()
                setStatusMessage(sidebarProjects.isEmpty ? L10n.text("ui.no_workspace_has_been_opened_yet") : L10n.plural("ui.recent_workspaces_loaded_count", count: sidebarProjects.count))
                setErrorMessage(nil)
                await reconcilePersistedQueuedTurns()
                return
            }

            requestProjectID = projectID
            requestToken = beginSessionPageRequest(projectID: projectID)
            defer { finishSessionPageRequest(projectID: projectID, token: requestToken ?? 0) }
            guard let workspace = workspacesByID[projectID] else {
                setSelectedProjectID(nil)
                setSelectedSessionID(nil)
                setStatusMessage(L10n.text("ui.the_workspace_has_expired_please_reopen_it"))
                setErrorMessage(nil)
                return
            }
            activeWorkspace = workspace
            // refreshAll 也必须进入首屏列表 single-flight。否则它与前台轮询或手动刷新重叠时，
            // 会向 gateway 发出两个相同 thread/list，后发请求被保护策略拒绝为 -32080。
            // reuseRecent=false 只绕过短缓存，不绕过正在执行的共享请求，仍保持全量刷新的语义。
            let page = try await sessionListFirstPage(
                workspace: workspace,
                limit: Self.initialSessionPageLimit,
                reuseRecent: false
            )
            guard connectionGeneration == appStore.connectionGeneration else {
                return
            }
            guard isCurrentSessionPageRequest(projectID: projectID, token: requestToken ?? 0) else {
                return
            }
            let pageSessions = sessions(page.sessions, in: workspace)
            replaceSessionsIfChanged(with: pageSessionsPreservingLoadedWindow(pageSessions, projectID: projectID), projectID: projectID)
            updateSessionPageState(projectID: projectID, page: page)
            clearWorkspaceUnavailable(projectID)

            if let previousSessionID, let session = sessionsByID[previousSessionID] {
                // 刷新或重新保存设置不能抢走用户已经点选的历史会话。
                setSelectedProjectID(session.projectID)
                setSelectedSessionID(session.id)
                revealProjectInSidebar(session.projectID)
                await prepareSelectedSessionAfterRefresh(session, autoAttach: autoAttach)
            } else if autoAttach, let runningSession = sessions(forProjectID: projectID).first(where: \.isRunning) {
                // iPad 冷启动/回前台时，如果当前没有明确选中的会话，优先恢复正在运行的会话。
                // 这会触发 direct app-server 的 thread/resume，让残留审批等运行态问题有机会自愈。
                setSelectedProjectID(runningSession.projectID)
                setSelectedSessionID(runningSession.id)
                revealProjectInSidebar(runningSession.projectID)
                await prepareSelectedSessionAfterRefresh(runningSession, autoAttach: true)
            } else {
                setSelectedSessionID(nil)
            }

            await reconcilePersistedQueuedTurns()
            ensureAllQueuedSessionMonitoring()
            setStatusMessage(L10n.format(
                "ui.counts_joined",
                L10n.plural("ui.recent_workspaces_loaded_count", count: sidebarProjects.count),
                L10n.plural("ui.sessions_loaded_count", count: filteredSessions.count)
            ))
            setErrorMessage(nil)
        } catch {
            if let requestProjectID, let requestToken, !isCurrentSessionPageRequest(projectID: requestProjectID, token: requestToken) {
                return
            }
            if terminateConnectionIfCredentialsInvalid(error) {
                return
            }
            if let activeWorkspace {
                // 已经拿到 projects、只是这个工作区的会话加载失败：单独判定该工作区可用性，
                // 避免把“某个 recent 失效”冒泡成整页错误，也避免冷启动退避一直重试一个已删除目录。
                await handleWorkspaceLoadFailure(workspace: activeWorkspace, error: error)
            } else {
                setErrorMessage(error.localizedDescription)
            }
        }
    }

    func selectProject(_ project: AgentProject) async {
        let workspace = ensureWorkspace(for: project)
        setSelectedProjectID(workspace.id)
        setSelectedSessionID(nil)
        insertExpandedProjectID(workspace.id)
        setErrorMessage(nil)
#if DEBUG
        guard !isDebugWorkbenchUISeedActive else {
            setStatusMessage(L10n.format("ui.debug_workspace_value_selected", project.name))
            return
        }
#endif
        disconnectWebSocket()
        await refreshSessions(forProjectID: workspace.id)
    }

    /// 只刷新工作区目录，不改变当前会话选择，也不重建 WebSocket。
    /// 工作区页浏览和手动刷新必须与会话运行态隔离，避免用户查看目录时打断长任务。
    func refreshWorkspaceCatalog() async throws {
        let fetchedProjects = try await clientFactory().projects()
        setProjectsIfChanged(fetchedProjects)

        // projects() 是后端可选目录，不等于用户已打开的工作区。旧实现把所有候选目录
        // 自动写进最近列表；手动 openWorkspace/rememberWorkspace 会写入 lastOpenedAt，
        // 因此这里只保留明确打开过的目录，并顺带迁移清理旧版自动灌入项。
        let nextWorkspaces = recentWorkspaces
            .filter { $0.lastOpenedAt != nil }
            .sorted { lhs, rhs in
                let lhsDate = lhs.lastOpenedAt ?? .distantPast
                let rhsDate = rhs.lastOpenedAt ?? .distantPast
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        recentWorkspaceStore.save(nextWorkspaces, endpoint: appStore.endpoint)
        setRecentWorkspacesIfChanged(nextWorkspaces)
    }

    /// 刷新工作区页正在浏览的会话，但不改变全局会话选择或 WebSocket。
    /// 工作区页有自己的本地浏览选择，不能复用 selectProject，否则刷新另一个目录会打断当前任务。
    func refreshWorkspaceSessions(projectID: String) async throws {
#if DEBUG
        guard !isDebugWorkbenchUISeedActive else { return }
#endif
        guard let workspace = ensureWorkspaceForKnownProjectID(projectID) else {
            throw WorkspaceSessionRefreshError.workspaceUnavailable
        }

        if let cooldownDelay = sessionListCooldownDelayNanoseconds(for: workspace) {
            // 用户已经明确点了刷新：尊重 gateway 的 retry-after，但窗口结束后必须真正请求一次。
            // 旧逻辑直接返回缓存，会让按钮看似刷新成功，实际要等后台轮询才看到新运行会话。
            await sessionListSleep(cooldownDelay)
            try Task.checkCancellation()
        }

        let requestToken = beginSessionPageRequest(projectID: workspace.id)
        defer { finishSessionPageRequest(projectID: workspace.id, token: requestToken) }

        do {
            let page = try await sessionListFirstPage(
                workspace: workspace,
                limit: Self.initialSessionPageLimit,
                reuseRecent: false
            )
            guard isCurrentSessionPageRequest(projectID: workspace.id, token: requestToken) else {
                return
            }

            let pageSessions = sessions(page.sessions, in: workspace)
            replaceSessionsIfChanged(
                // 工作区页下拉刷新首屏时，保留用户已经翻到的旧页，避免列表突然收缩回 20 条。
                with: pageSessionsPreservingLoadedWindow(
                    pageSessions,
                    projectID: workspace.id,
                    preserveAllLoaded: sessionProjectsWithAdditionalPages.contains(workspace.id)
                ),
                projectID: workspace.id
            )
            updateSessionPageState(projectID: workspace.id, page: page)
            clearWorkspaceUnavailable(workspace.id)
        } catch {
            _ = terminateConnectionIfCredentialsInvalid(error)
            throw error
        }
    }

    @discardableResult
    func openWorkspace(path: String) async -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setErrorMessage(L10n.text("ui.please_enter_the_directory_path_in_the_development"))
            return false
        }
        do {
            // 走 clientFactory（与会话请求同一个注入点）而不是 appStore.client()，
            // 让 resolve 和后续会话加载共用一条可测试链路。
            let workspace = try await clientFactory().resolveWorkspace(path: trimmed)
            rememberWorkspace(workspace)
            clearWorkspaceUnavailable(workspace.id)
            setSelectedProjectID(workspace.id)
            setSelectedSessionID(nil)
            insertExpandedProjectID(workspace.id)
            setErrorMessage(nil)
            disconnectWebSocket()
            await refreshSessions(forProjectID: workspace.id)
            return true
        } catch {
            setErrorMessage(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func openWorkspace(project: AgentProject) async -> Bool {
        await openWorkspace(path: project.path)
    }

    @discardableResult
    func createWorktreeAndOpen(project: AgentProject, name: String? = nil, base: String? = nil, branch: String? = nil) async -> Bool {
        isCreatingWorktree = true
        defer { isCreatingWorktree = false }
        do {
            let response = try await clientFactory().createWorktree(
                path: project.path,
                name: name?.trimmingCharacters(in: .whitespacesAndNewlines),
                base: base?.trimmingCharacters(in: .whitespacesAndNewlines),
                branch: branch?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let workspace = response.workspace
            // Worktree 成功创建后作为一个普通 workspace 接入，后续 thread/list 和 thread/start 复用现有 cwd 安全链路。
            rememberWorkspace(workspace)
            upsertManagedWorktree(WorktreeListItem(workspace: workspace, worktree: response.worktree))
            clearWorkspaceUnavailable(workspace.id)
            setSelectedProjectID(workspace.id)
            setSelectedSessionID(nil)
            insertExpandedProjectID(workspace.id)
            setErrorMessage(nil)
            disconnectWebSocket()
            await refreshSessions(forProjectID: workspace.id)
            return true
        } catch {
            setErrorMessage(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func handoffSessionToWorktree(_ session: AgentSession, name: String? = nil, base: String? = nil, branch: String? = nil) async -> Bool {
        guard !session.isRunning else {
            setErrorMessage(L10n.text("ui.running_sessions_cannot_go_directly_to_worktree_please"))
            return false
        }
        let rootProjectID = rootProjectID(forProjectID: session.projectID)
        guard let rootWorkspace = ensureWorkspaceForKnownProjectID(rootProjectID) else {
            setErrorMessage(L10n.text("ui.the_root_project_of_the_source_session_has"))
            return false
        }

        isCreatingWorktree = true
        defer { isCreatingWorktree = false }
        do {
            // handoff 仍然创建真实 managed Worktree，再用普通 thread/start 启动新线程；
            // 不伪造历史迁移，避免跨 cwd resume 带来不可预测状态。
            let response = try await clientFactory().createWorktree(
                path: rootWorkspace.path,
                name: normalizedOptional(name) ?? defaultHandoffWorktreeName(for: session),
                base: normalizedOptional(base),
                branch: normalizedOptional(branch)
            )
            let workspace = response.workspace
            rememberWorkspace(workspace)
            upsertManagedWorktree(WorktreeListItem(workspace: workspace, worktree: response.worktree))
            clearWorkspaceUnavailable(workspace.id)
            setSelectedProjectID(workspace.id)
            setSelectedSessionID(nil)
            insertExpandedProjectID(workspace.id)
            setErrorMessage(nil)
            worktreeErrorMessage = nil
            disconnectWebSocket()
            await refreshSessions(forProjectID: workspace.id)

            let sourceThreadID = normalizedOptional(session.resumeID) ?? session.id
            do {
                let forked = try await clientFactory().forkSession(threadID: sourceThreadID, workspace: workspace)
                let responseSession = self.session(forked, in: workspace)
                upsert(responseSession)
                setSelectedProjectID(responseSession.projectID)
                setSelectedSessionID(responseSession.id)
                insertExpandedProjectID(responseSession.projectID)
                await loadHistoryIfNeeded(for: responseSession)
                if responseSession.isRunning {
                    connectWebSocket(responseSession)
                } else {
                    disconnectWebSocket()
                }
                conversationStore.appendSystem(L10n.text("ui.this_worktree_has_been_forked_from_the_source"), sessionID: responseSession.id)
                setStatusMessage(L10n.text("ui.forked_to_new_worktree"))
                return true
            } catch {
                setStatusMessage(L10n.format("ui.native_fork_is_not_available_use_prompt_worktree", error.localizedDescription))
            }

            var options = CodexAppServerTurnOptions.default
            options.sessionStartSource = "mimi_remote_worktree_handoff"
            options.threadSource = "worktree_handoff"
            let prompt = worktreeHandoffPrompt(
                source: session,
                rootWorkspace: rootWorkspace,
                targetWorkspace: workspace,
                worktree: response.worktree
            )
            let started = await createSession(
                projectID: workspace.id,
                payload: CodexAppServerTurnPayload(prompt: prompt, options: options),
                resume: nil,
                clientMessageID: UUID().uuidString
            )
            if started {
                setStatusMessage(L10n.text("ui.moved_to_new_git_worktree"))
            }
            return started
        } catch {
            setErrorMessage(error.localizedDescription)
            return false
        }
    }

    func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func defaultHandoffWorktreeName(for session: AgentSession) -> String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "handoff" : "handoff-\(String(title.prefix(36)))"
    }

    func worktreeHandoffPrompt(
        source session: AgentSession,
        rootWorkspace: AgentWorkspace,
        targetWorkspace: AgentWorkspace,
        worktree: WorktreeDescriptor
    ) -> String {
        let sourceThreadID = normalizedOptional(session.resumeID) ?? session.id
        let branch = normalizedOptional(worktree.branch) ?? L10n.text("ui.unnamed_branch")
        let preview = normalizedOptional(session.preview).map { L10n.format("ui.source_summary_value", $0) } ?? ""
        return L10n.format(
            "ui.worktree_handoff_prompt",
            session.title,
            sourceThreadID,
            rootWorkspace.path,
            preview,
            targetWorkspace.path,
            worktree.base,
            branch
        )
    }

    func worktreeBranches(path: String) -> WorktreeBranchListResponse? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return worktreeBranchesByPath[trimmed]
    }

    func worktreeBranchError(path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return worktreeBranchErrorByPath[trimmed]
    }

    func refreshWorktreeBranches(path: String) async {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        isRefreshingWorktreeBranches = true
        defer { isRefreshingWorktreeBranches = false }
        do {
            // 分支列表是只读建议值：缓存服务端 canonical path，同时保留调用方原始 key，避免 /var 和 /private/var 这类路径差异影响 UI 命中。
            let response = try await clientFactory().worktreeBranches(path: trimmed)
            worktreeBranchesByPath[trimmed] = response
            worktreeBranchesByPath[response.path] = response
            worktreeBranchErrorByPath.removeValue(forKey: trimmed)
            worktreeBranchErrorByPath.removeValue(forKey: response.path)
        } catch {
            worktreeBranchErrorByPath[trimmed] = error.localizedDescription
        }
    }

    func refreshManagedWorktrees() async {
        isRefreshingWorktrees = true
        defer { isRefreshingWorktrees = false }
        do {
            let worktrees = try await clientFactory().listWorktrees()
            setManagedWorktreesIfChanged(worktrees)
            worktreeErrorMessage = nil
        } catch {
            worktreeErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func pruneMissingManagedWorktrees() async -> Int {
        isPruningWorktrees = true
        defer { isPruningWorktrees = false }
        do {
            let response = try await clientFactory().pruneMissingWorktrees()
            let prunedPaths = Set(response.prunedPaths.compactMap(normalizedWorktreeCleanupPath))
            // 先应用服务端返回的成功结果；即使部分 registry 文件删除失败，
            // 已经 prune 的登记也不能继续残留在 Worktree 管理列表中。
            setManagedWorktreesIfChanged(response.worktrees.filter { item in
                guard let path = normalizedWorktreeCleanupPath(item.worktree.path) else {
                    return true
                }
                return !prunedPaths.contains(path)
            })
            let count = response.prunedPaths.count
            if let failedPaths = response.failedPaths, !failedPaths.isEmpty {
                let detail = failedPaths
                    .sorted { $0.key < $1.key }
                    .map { L10n.format("ui.labeled_value", $0.key, $0.value) }
                    .joined(separator: L10n.text("ui.semicolon_separator"))
                worktreeErrorMessage = L10n.format(
                    "ui.value_missing_worktree_entries_cleaned_up_but_value",
                    L10n.plural("ui.worktree_registrations_cleaned_count", count: count),
                    L10n.plural("ui.worktree_cleanup_failures_count", count: failedPaths.count),
                    detail
                )
                setStatusMessage(count == 0
                    ? L10n.text("ui.worktree_registration_cleanup_not_completed")
                    : L10n.format(
                        "ui.git_worktree_cleanup_partial_success",
                        L10n.plural("ui.worktree_registrations_cleaned_count", count: count)
                    ))
            } else {
                worktreeErrorMessage = nil
                setStatusMessage(count == 0 ? L10n.text("ui.there_are_no_worktree_registrations_to_clean_up") : L10n.plural("ui.worktree_registrations_cleaned_count", count: count))
            }
            return count
        } catch {
            worktreeErrorMessage = error.localizedDescription
            return 0
        }
    }

    func previewManagedWorktreeCleanup() async throws -> WorktreeCleanupResponse {
        do {
            let response = try await clientFactory().previewWorktreeCleanup()
            worktreeErrorMessage = nil
            return response
        } catch {
            worktreeErrorMessage = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    func cleanupManagedWorktrees(
        paths: Set<String>,
        preview: WorktreeCleanupResponse
    ) async throws -> WorktreeCleanupResponse {
        let requestedPaths = Set(paths.compactMap(normalizedWorktreeCleanupPath))
        guard !requestedPaths.isEmpty else {
            throw WorktreeCleanupSelectionError.emptySelection
        }

        let previewCandidates = Set(preview.candidatePaths.compactMap(normalizedWorktreeCleanupPath))
        let eligiblePaths = Set(preview.worktrees.filter(\.eligible).compactMap {
            normalizedWorktreeCleanupPath($0.worktree.path)
        })
        // 客户端只能确认服务端 dry-run 同时标记为 eligible 和 candidate 的路径；
        // blocker 发生变化时最终仍由 agentd 重新评估并拒绝，客户端没有 force 逃生口。
        let allowedPaths = previewCandidates.intersection(eligiblePaths)
        guard requestedPaths.isSubset(of: allowedPaths) else {
            throw WorktreeCleanupSelectionError.containsBlockedPath
        }
        guard let planID = preview.planID?.trimmingCharacters(in: .whitespacesAndNewlines), !planID.isEmpty else {
            throw WorktreeCleanupSelectionError.missingPlan
        }

        do {
            let response = try await clientFactory().executeWorktreeCleanup(paths: requestedPaths.sorted(), planID: planID)
            let deletedPaths = Set(response.deletedPaths.compactMap(normalizedWorktreeCleanupPath))
            let deletedItems = managedWorktrees.filter {
                guard let path = normalizedWorktreeCleanupPath($0.worktree.path) else {
                    return false
                }
                return deletedPaths.contains(path)
            }
            setManagedWorktreesIfChanged(managedWorktrees.filter {
                guard let path = normalizedWorktreeCleanupPath($0.worktree.path) else {
                    return true
                }
                return !deletedPaths.contains(path)
            })
            for item in deletedItems {
                forgetManagedWorktreeAfterDeletion(item.workspace)
            }

            // 删除响应描述本次策略评估；再取一次管理列表，确保 Sheet 背后的列表与 agentd registry 一致。
            await refreshManagedWorktrees()
            if let partialFailureMessage = response.partialFailureMessage {
                // 多 Worktree 删除无法形成文件系统事务。先承认并刷新已经成功的部分，
                // 再暴露失败，避免 UI 把整批操作误报为“全部未执行”。
                worktreeErrorMessage = partialFailureMessage
                setStatusMessage(deletedPaths.isEmpty
                    ? L10n.text("ui.worktree_cleanup_failed")
                    : L10n.format(
                        "ui.git_worktree_cleanup_partial_success",
                        L10n.plural("ui.git_worktrees_cleaned_count", count: deletedPaths.count)
                    ))
            } else {
                worktreeErrorMessage = nil
                setStatusMessage(deletedPaths.isEmpty ? L10n.text("ui.no_worktree_is_deleted") : L10n.plural("ui.git_worktrees_cleaned_count", count: deletedPaths.count))
            }
            return response
        } catch {
            worktreeErrorMessage = error.localizedDescription
            throw error
        }
    }

    func managedWorktrees(rootProjectID: String) -> [WorktreeListItem] {
        let root = rootProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            return []
        }
        return managedWorktrees.filter { $0.worktree.rootProjectID == root }
    }

    func rootProjectID(forProjectID projectID: String) -> String {
        workspacesByID[projectID]?.rootProjectID ?? projectID
    }

    func hasRunningSession(in worktree: WorktreeListItem) -> Bool {
        sessions.contains { session in
            session.projectID == worktree.workspace.id && session.isRunning
        }
    }

    @discardableResult
    func openManagedWorktree(_ item: WorktreeListItem) async -> Bool {
        let workspace = item.workspace
        rememberWorkspace(workspace)
        clearWorkspaceUnavailable(workspace.id)
        setSelectedProjectID(workspace.id)
        setSelectedSessionID(nil)
        insertExpandedProjectID(workspace.id)
        setErrorMessage(nil)
        worktreeErrorMessage = nil
        disconnectWebSocket()
        await refreshSessions(forProjectID: workspace.id)
        return true
    }

    @discardableResult
    func deleteManagedWorktree(_ item: WorktreeListItem, force: Bool = false) async -> Bool {
        if hasRunningSession(in: item) {
            worktreeErrorMessage = L10n.text("ui.this_worktree_also_has_a_running_session_stop")
            return false
        }

        let workspace = item.workspace
        isDeletingWorktree = true
        defer { isDeletingWorktree = false }
        do {
            let response = try await clientFactory().deleteWorktree(path: workspace.path, force: force)
            let deletedPaths = Set([response.deletedPath, workspace.path].compactMap(normalizedWorktreeCleanupPath))
            // Git checkout 已经删除后，registry unlink 失败可能让 response.worktrees
            // 暂时仍含陈旧项。先按 deleted_path/当前 workspace 移除真实删除结果，
            // 再展示 registry 警告，避免 UI 把不存在的 checkout 放回来。
            setManagedWorktreesIfChanged(response.worktrees.filter { candidate in
                if candidate.workspace.id == workspace.id {
                    return false
                }
                guard let path = normalizedWorktreeCleanupPath(candidate.worktree.path) else {
                    return true
                }
                return !deletedPaths.contains(path)
            })
            forgetManagedWorktreeAfterDeletion(workspace)
            if let registryCleanupError = normalizedOptional(response.registryCleanupError) {
                worktreeErrorMessage = L10n.format("ui.git_worktree_was_deleted_but_cleanup_management_registration", registryCleanupError)
                setStatusMessage(L10n.format("ui.git_worktree_value_has_been_deleted_but_the", workspace.name))
            } else {
                worktreeErrorMessage = nil
                setStatusMessage(L10n.format("ui.git_worktree_value_has_been_deleted", workspace.name))
            }
            return true
        } catch {
            worktreeErrorMessage = error.localizedDescription
            return false
        }
    }

    // 目录浏览只读不改状态，错误交给调用方（打开面板内联展示），不污染全局 errorMessage。
}
