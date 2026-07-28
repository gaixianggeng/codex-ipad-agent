import Foundation

// Codex Desktop 与 Mimi 的 app-server 是两个独立进程，runtime status 不能跨进程复用。
// 这里消费 agentd 从 rollout 提炼出的只读活动层；所有消息仍走现有历史读取，不建立控制连接。
extension SessionStore {
    func externalActivityPollingDelayNanoseconds() -> UInt64 {
        if let selectedSessionID,
           externalActivityBySessionID[selectedSessionID] != nil {
            return externalActivitySelectedPollingDelayNanoseconds
        }
        return externalActivityDefaultPollingDelayNanoseconds
    }

    func pollExternalActivitiesWhileVisible() async {
        while !Task.isCancelled {
            if connectionTermination != nil || appStore.requiresRePairing {
                return
            }
#if DEBUG
            if isDebugWorkbenchUISeedActive {
                return
            }
#endif
            if !isAppInBackground,
               !isNetworkUnavailable,
               appStore.isConfigured {
                _ = await refreshExternalActivities()
                if externalActivityCapabilityUnavailable {
                    // 旧 agentd 没有该 capability 时结束本次前台轮询，不制造 404/配置请求噪音。
                    return
                }
            }
            let delay = externalActivityPollingDelayNanoseconds()
            await externalActivitySleep(delay)
        }
    }

    @discardableResult
    func refreshExternalActivities(
        client fixedClient: (any SessionStoreAPIClient)? = nil
    ) async -> Bool {
        guard !isRefreshingExternalActivity,
              !isAppInBackground,
              !isNetworkUnavailable,
              appStore.isConfigured,
              connectionTermination == nil,
              !appStore.requiresRePairing else {
            return false
        }
        isRefreshingExternalActivity = true
        defer { isRefreshingExternalActivity = false }

        let hostScope = appStore.activeHostScope
        let client: any SessionStoreAPIClient
        do {
            client = try fixedClient ?? clientFactory()
        } catch {
            return false
        }

        do {
            guard let response = try await client.externalActivities() else {
                guard appStore.activeHostScope == hostScope else { return false }
                // 同一主机降级到旧 agentd 时不能把上次缓存的 Mac 活动态永久留在“进行中”。
                // 按空快照完成最后一次只读收尾，再停止本次前台轮询。
                await applyExternalActivitySnapshot(
                    [],
                    client: client,
                    hostScope: hostScope
                )
                guard appStore.activeHostScope == hostScope else { return false }
                externalActivityCapabilityUnavailable = true
                return false
            }
            guard appStore.activeHostScope == hostScope else {
                return false
            }
            externalActivityCapabilityUnavailable = false
            await applyExternalActivitySnapshot(
                response.activities,
                client: client,
                hostScope: hostScope
            )
            return appStore.activeHostScope == hostScope
        } catch {
            guard appStore.activeHostScope == hostScope, !Task.isCancelled else {
                return false
            }
            _ = terminateConnectionIfCredentialsInvalid(error)
            // 短暂读取失败不清空上次活动态，否则列表会在“进行中/历史”之间来回抖动。
            return false
        }
    }

    func applyExternalActivitySnapshot(
        _ activities: [ExternalSessionActivity],
        client: any SessionStoreAPIClient,
        hostScope: HostScope
    ) async {
        var nextByID: [SessionID: ExternalSessionActivity] = [:]
        for activity in activities where activity.state.lowercased() == "running" {
            guard workspacesByID[activity.projectID] != nil || projectsByID[activity.projectID] != nil else {
                continue
            }
            nextByID[activity.threadID] = activity
        }

        let previousByID = externalActivityBySessionID
        let activeIDs = Set(nextByID.keys)
        // 上一次 terminal 最终刷新若因退后台被取消，externalActivityBySessionID 已经清空，
        // 但只读 tombstone 会保留。把它重新纳入 removedIDs，下一次前台轮询即可续跑并清理。
        let removedIDs = Set(previousByID.keys)
            .union(externalReadOnlySessionIDs)
            .subtracting(activeIDs)
        externalReadOnlySessionIDs.formUnion(activeIDs)
        externalReadOnlySessionIDs.formUnion(removedIDs)
        externalActivityBySessionID = nextByID

        for (sessionID, activity) in nextByID {
            stopQueuedSessionMonitoring(sessionID: sessionID)
            updateSession(sessionID) { session in
                session.status = SessionStatus.running.rawValue
                session.activeTurnID = activity.turnID
                session.pendingApproval = nil
                session.pendingUserInput = nil
                session.updatedAt = max(session.updatedAt ?? .distantPast, activity.lastActivityAt)
                session.recencyAt = max(session.recencyAt ?? .distantPast, activity.lastActivityAt)
            }
        }
        if let selectedSessionID, activeIDs.contains(selectedSessionID) {
            disconnectWebSocket()
        }

        // 先本地降级，确保 terminal/过期快照一到就从“进行中”移回“历史”；
        // 随后的权威列表与最终历史读取负责补齐标题、消息和最新时间。
        for sessionID in removedIDs {
            updateSession(sessionID) { session in
                session.status = SessionStatus.history.rawValue
                session.activeTurnID = nil
                session.pendingApproval = nil
                session.pendingUserInput = nil
            }
            clearForegroundActivity(sessionID: sessionID)
            clearRuntimeActivity(sessionID: sessionID)
        }

        let newOrMissingProjectIDs = Set(nextByID.values.compactMap { activity in
            if previousByID[activity.threadID] == nil || sessionsByID[activity.threadID] == nil {
                return activity.projectID
            }
            return nil
        })
        for projectID in newOrMissingProjectIDs {
            guard appStore.activeHostScope == hostScope, !Task.isCancelled else { return }
            await refreshExternalActivityProject(
                projectID: projectID,
                client: client,
                hostScope: hostScope
            )
        }

        if let selectedSessionID,
           let activity = nextByID[selectedSessionID],
           previousByID[selectedSessionID]?.revision != activity.revision,
           let session = sessionsByID[selectedSessionID] {
            _ = await loadHistory(
                for: session,
                quiet: true,
                loadMode: .full,
                force: true
            )
        }

        // terminal/过期必须做最后一次强制历史补拉。只读集合在所有 await 完成前保留，
        // 即使磁盘里遗留 `.takenOver`，这段时间也不能触发 resume 或发送。
        for sessionID in removedIDs {
            guard appStore.activeHostScope == hostScope, !Task.isCancelled else { return }
            if selectedSessionID == sessionID, let session = sessionsByID[sessionID] {
                _ = await loadHistory(
                    for: session,
                    quiet: true,
                    loadMode: .full,
                    force: true
                )
            }
            let projectID = previousByID[sessionID]?.projectID ?? sessionsByID[sessionID]?.projectID
            if let projectID {
                await refreshExternalActivityProject(
                    projectID: projectID,
                    client: client,
                    hostScope: hostScope
                )
            }
        }
        guard appStore.activeHostScope == hostScope else { return }
        externalReadOnlySessionIDs.subtract(removedIDs)
    }

    func refreshExternalActivityProject(
        projectID: String,
        client: any SessionStoreAPIClient,
        hostScope: HostScope
    ) async {
        guard let workspace = ensureWorkspaceForKnownProjectID(projectID) else {
            return
        }
        do {
            let page = try await client.sessionsPage(
                workspace: workspace,
                cursor: nil,
                limit: Self.initialSessionPageLimit,
                consistency: .authoritative
            )
            guard appStore.activeHostScope == hostScope, !Task.isCancelled else {
                return
            }
            mergeSessionPage(sessions(page.sessions, in: workspace))
            updateSessionPageState(projectID: projectID, page: page)
            clearWorkspaceUnavailable(projectID)
        } catch {
            // 活动 API 已给出可靠运行态；列表补拉失败时保留已有行，下一次轮询继续重试未知线程。
        }
    }
}
