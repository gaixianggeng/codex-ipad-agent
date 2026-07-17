import Foundation

// 文件预览、命令动作、Git、项目列表与网络恢复按工作区能力集中。
extension SessionStore {
    func listDirectories(path: String) async throws -> DirectoryListResponse {
        try await clientFactory().listDirectories(path: path)
    }

    // 文件预览同样不污染全局错误状态：后端只返回授权边界内的普通文件，客户端落到临时目录后交给 QuickLook。
    func previewFile(path: String) async throws -> URL {
        let response = try await clientFactory().readFile(path: path)
        return try Self.previewURL(from: response)
    }

    // 历史图片走 app-server gateway 的短期缓存 ID，不阻塞会话文字首屏；点按后再落到临时文件预览。
    func previewHistoryMedia(id: String) async throws -> URL {
        let response = try await clientFactory().readHistoryMedia(id: id)
        return try Self.previewURL(from: response)
    }

    static func previewURL(from response: FileReadResponse) throws -> URL {
        guard let data = Data(base64Encoded: response.contentBase64) else {
            throw FilePreviewStoreError.invalidPayload
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MimiRemotePreviews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let filename = Self.safePreviewFilename(response.name)
        let url = directory.appendingPathComponent("\(UUID().uuidString)-\(filename)", isDirectory: false)
        try data.write(to: url, options: [.atomic])
        return url
    }

    func refreshSelectedCommandActions() async {
        guard let path = selectedCommandActionPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await refreshCommandActions(path: path)
    }

    func refreshCommandActions(path: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            return
        }
        isRefreshingCommandActions = true
        defer { isRefreshingCommandActions = false }
        do {
            let actions = try await clientFactory().commandActions(path: targetPath)
            // action 是 agentd 配置里的 allowlist，只按工作区 path 缓存，避免跨会话串结果。
            commandActionsByPath[targetPath] = actions
            commandActionErrorByPath.removeValue(forKey: targetPath)
        } catch {
            commandActionsByPath[targetPath] = []
            commandActionErrorByPath[targetPath] = error.localizedDescription
        }
    }

    func runSelectedCommandAction(_ action: AgentCommandAction) async {
        guard let path = selectedCommandActionPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await runCommandAction(path: path, id: action.id, confirmed: action.requiresConfirmation)
    }

    func runCommandAction(path: String, id: String, confirmed: Bool = false) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let actionID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty, !actionID.isEmpty else {
            return
        }

        let run = QueuedCommandActionRun(path: targetPath, id: actionID, confirmed: confirmed)
        if isRunningCommandAction {
            enqueueCommandActionRun(run)
            return
        }

        await drainCommandActionRuns(startingWith: run)
    }

    func enqueueCommandActionRun(_ run: QueuedCommandActionRun) {
        queuedCommandActionRuns.append(run)
        var ids = queuedCommandActionIDsByPath[run.path] ?? []
        ids.append(run.id)
        queuedCommandActionIDsByPath[run.path] = ids
    }

    func dequeueCommandActionRun() -> QueuedCommandActionRun? {
        guard !queuedCommandActionRuns.isEmpty else {
            return nil
        }
        let run = queuedCommandActionRuns.removeFirst()
        var ids = queuedCommandActionIDsByPath[run.path] ?? []
        if let index = ids.firstIndex(of: run.id) {
            ids.remove(at: index)
        }
        if ids.isEmpty {
            queuedCommandActionIDsByPath.removeValue(forKey: run.path)
        } else {
            queuedCommandActionIDsByPath[run.path] = ids
        }
        return run
    }

    func drainCommandActionRuns(startingWith firstRun: QueuedCommandActionRun) async {
        var nextRun: QueuedCommandActionRun? = firstRun
        while let run = nextRun {
            await performCommandActionRun(run)
            nextRun = dequeueCommandActionRun()
        }
    }

    func performCommandActionRun(_ run: QueuedCommandActionRun) async {
        runningCommandActionPath = run.path
        runningCommandActionID = run.id
        defer {
            runningCommandActionPath = nil
            runningCommandActionID = nil
        }
        do {
            let response = try await clientFactory().runCommandAction(path: run.path, id: run.id, confirmed: run.confirmed)
            commandActionResultByPath[run.path] = response
            var history = commandActionHistoryByPath[run.path] ?? []
            // 执行历史只做本地短缓存，不写后端，避免命令输出长期留存在配置服务里。
            history.insert(response, at: 0)
            if history.count > Self.commandActionHistoryLimit {
                history.removeLast(history.count - Self.commandActionHistoryLimit)
            }
            commandActionHistoryByPath[run.path] = history
            commandActionErrorByPath.removeValue(forKey: run.path)
        } catch {
            commandActionErrorByPath[run.path] = error.localizedDescription
        }
    }

    func refreshSelectedGitStatus() async {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await refreshGitStatus(path: path)
    }

    func refreshGitStatus(path: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            return
        }
        isRefreshingGitStatus = true
        defer { isRefreshingGitStatus = false }
        do {
            let status = try await clientFactory().gitStatus(path: targetPath)
            // Git 状态是只读辅助信息，按路径缓存；用户切换会话后，旧请求只会更新旧路径缓存。
            gitStatusByPath[targetPath] = status
            gitStatusErrorByPath.removeValue(forKey: targetPath)
            gitActionErrorByPath.removeValue(forKey: targetPath)
        } catch {
            gitStatusErrorByPath[targetPath] = error.localizedDescription
        }
    }

    func performSelectedGitAction(_ action: GitActionKind, files: [String]) async {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await performGitAction(path: path, action: action, files: files)
    }

    func performGitAction(path: String, action: GitActionKind, files: [String]) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetFiles = files
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !targetPath.isEmpty, !targetFiles.isEmpty else {
            return
        }

        isRunningGitAction = true
        defer { isRunningGitAction = false }
        do {
            let status = try await clientFactory().gitAction(path: targetPath, action: action, files: targetFiles)
            // 写动作成功后直接采用服务端返回的新状态，避免前端本地推断 Git index。
            gitStatusByPath[targetPath] = status
            gitStatusErrorByPath.removeValue(forKey: targetPath)
            gitActionErrorByPath.removeValue(forKey: targetPath)
        } catch {
            gitActionErrorByPath[targetPath] = error.localizedDescription
        }
    }

    func performSelectedGitPatchAction(_ action: GitActionKind, patch: String) async {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await performGitPatchAction(path: path, action: action, patch: patch)
    }

    func performGitPatchAction(path: String, action: GitActionKind, patch: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetPatch = patch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty, !targetPatch.isEmpty else {
            return
        }

        isRunningGitAction = true
        defer { isRunningGitAction = false }
        do {
            let status = try await clientFactory().gitPatchAction(path: targetPath, action: action, patch: targetPatch)
            // hunk 操作同样以服务端返回为准，避免本地解析 patch 后再二次推断状态。
            gitStatusByPath[targetPath] = status
            gitStatusErrorByPath.removeValue(forKey: targetPath)
            gitActionErrorByPath.removeValue(forKey: targetPath)
        } catch {
            gitActionErrorByPath[targetPath] = error.localizedDescription
        }
    }

    func commitSelectedGitChanges(message: String) async {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await commitGitChanges(path: path, message: message)
    }

    func commitGitChanges(path: String, message: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let commitMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty, !commitMessage.isEmpty else {
            return
        }

        isCommittingGitChanges = true
        defer { isCommittingGitChanges = false }
        do {
            let status = try await clientFactory().gitCommit(path: targetPath, message: commitMessage)
            // commit 只提交已暂存内容；成功后用服务端状态清理 staged diff 和文件列表。
            gitStatusByPath[targetPath] = status
            gitStatusErrorByPath.removeValue(forKey: targetPath)
            gitActionErrorByPath.removeValue(forKey: targetPath)
        } catch {
            gitActionErrorByPath[targetPath] = error.localizedDescription
        }
    }

    func pushSelectedGitBranch(remote: String? = nil) async {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await pushGitBranch(path: path, remote: remote)
    }

    func pushGitBranch(path: String, remote: String? = nil) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetRemote = remote?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            return
        }

        isPushingGitBranch = true
        defer { isPushingGitBranch = false }
        do {
            let response = try await clientFactory().gitPush(path: targetPath, remote: targetRemote?.isEmpty == true ? nil : targetRemote)
            gitStatusByPath[targetPath] = response.status
            gitStatusErrorByPath.removeValue(forKey: targetPath)
            gitActionErrorByPath.removeValue(forKey: targetPath)
        } catch {
            gitActionErrorByPath[targetPath] = error.localizedDescription
        }
    }

    @discardableResult
    func quickPublishSelectedGitChanges(message: String, remote: String? = nil) async -> Bool {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return false
        }
        return await quickPublishGitChanges(path: path, message: message, remote: remote)
    }

    @discardableResult
    func quickPublishGitChanges(path: String, message: String, remote: String? = nil) async -> Bool {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let commitMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetRemote = remote?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty, !commitMessage.isEmpty else {
            return false
        }

        isQuickPublishingGitChanges = true
        defer { isQuickPublishingGitChanges = false }
        do {
            let response = try await clientFactory().gitQuickPublish(
                path: targetPath,
                message: commitMessage,
                remote: targetRemote?.isEmpty == true ? nil : targetRemote,
                confirmed: true
            )
            gitQuickPublishResultByPath[targetPath] = response
            gitStatusByPath[targetPath] = response.status
            gitStatusErrorByPath.removeValue(forKey: targetPath)
            gitActionErrorByPath.removeValue(forKey: targetPath)
            await refreshGitTestFlightStatus(path: targetPath)
            return true
        } catch {
            gitActionErrorByPath[targetPath] = error.localizedDescription
            // 组合动作可能已经完成本地 commit 但在 push 阶段失败，失败后必须重新读取真实 Git 状态。
            await refreshGitStatus(path: targetPath)
            return false
        }
    }

    func refreshSelectedGitTestFlightStatus() async {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await refreshGitTestFlightStatus(path: path)
    }

    func refreshGitTestFlightStatus(path: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            return
        }
        isRefreshingGitTestFlightStatus = true
        defer { isRefreshingGitTestFlightStatus = false }
        do {
            gitTestFlightStatusByPath[targetPath] = try await clientFactory().gitTestFlightStatus(path: targetPath)
            gitTestFlightErrorByPath.removeValue(forKey: targetPath)
        } catch {
            gitTestFlightErrorByPath[targetPath] = error.localizedDescription
        }
    }

    @discardableResult
    func startSelectedGitTestFlightRelease(whatToTest: String) async -> Bool {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return false
        }
        return await startGitTestFlightRelease(path: path, whatToTest: whatToTest)
    }

    @discardableResult
    func startGitTestFlightRelease(path: String, whatToTest: String) async -> Bool {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            return false
        }
        isStartingGitTestFlightRelease = true
        defer { isStartingGitTestFlightRelease = false }
        do {
            gitTestFlightStatusByPath[targetPath] = try await clientFactory().gitTestFlightRun(
                path: targetPath,
                whatToTest: whatToTest.trimmingCharacters(in: .whitespacesAndNewlines),
                confirmed: true
            )
            gitTestFlightErrorByPath.removeValue(forKey: targetPath)
            return true
        } catch {
            gitTestFlightErrorByPath[targetPath] = error.localizedDescription
            return false
        }
    }

    func pollSelectedGitTestFlightRelease() async {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        while !Task.isCancelled {
            await refreshGitTestFlightStatus(path: path)
            guard gitTestFlightStatusByPath[path]?.job?.isRunning == true else {
                return
            }
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
        }
    }

    func createSelectedPullRequest(title: String, body: String = "", draft: Bool = true) async {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await createPullRequest(path: path, title: title, body: body, draft: draft)
    }

    func createPullRequest(path: String, title: String, body: String = "", draft: Bool = true) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let prTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty, !prTitle.isEmpty else {
            return
        }

        isCreatingPullRequest = true
        defer { isCreatingPullRequest = false }
        do {
            let response = try await clientFactory().gitCreatePullRequest(path: targetPath, title: prTitle, body: body, draft: draft)
            if let url = response.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
                pullRequestURLByPath[targetPath] = url
                pullRequestStatusByPath[targetPath] = GitPullRequestStatusResponse(
                    path: targetPath,
                    branch: response.branch,
                    exists: true,
                    title: prTitle,
                    url: url,
                    isDraft: draft
                )
            }
            pullRequestStatusErrorByPath.removeValue(forKey: targetPath)
            gitActionErrorByPath.removeValue(forKey: targetPath)
        } catch {
            gitActionErrorByPath[targetPath] = error.localizedDescription
        }
    }

    func refreshSelectedPullRequestStatus() async {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await refreshPullRequestStatus(path: path)
    }

    func refreshPullRequestStatus(path: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            return
        }

        isRefreshingPullRequestStatus = true
        defer { isRefreshingPullRequestStatus = false }
        do {
            let response = try await clientFactory().gitPullRequestStatus(path: targetPath)
            pullRequestStatusByPath[targetPath] = response
            if let url = response.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
                pullRequestURLByPath[targetPath] = url
            }
            pullRequestStatusErrorByPath.removeValue(forKey: targetPath)
        } catch {
            pullRequestStatusErrorByPath[targetPath] = error.localizedDescription
        }
    }

    func forgetWorkspace(_ project: AgentProject) {
        let next = recentWorkspaceStore.forget(id: project.id, endpoint: appStore.endpoint)
        setRecentWorkspacesIfChanged(next)
        removeExpandedProjectID(project.id)
        removeShowingAllSessionProjectID(project.id)
        sessionPageCursorByProjectID.removeValue(forKey: project.id)
        sessionHasMoreByProjectID.removeValue(forKey: project.id)
        sessionPageRequestTokenByProjectID.removeValue(forKey: project.id)
        sessionPageLoadingTokenByProjectID.removeValue(forKey: project.id)
        clearSessionReminders(forProjectID: project.id)
        sessions = sessions.filter { $0.projectID != project.id }
        clearWorkspaceUnavailable(project.id)
        if selectedProjectID == project.id {
            setSelectedProjectID(nil)
            setSelectedSessionID(nil)
            disconnectWebSocket()
        }
        setStatusMessage("已从当前设备移除 \(project.name)")
    }

    func toggleSessionPinned(_ session: AgentSession) {
        if pinnedSessionIDs.contains(session.id) {
            pinnedSessionIDs.remove(session.id)
            setStatusMessage("已取消置顶 \(session.title)")
        } else {
            archivedSessionIDs.remove(session.id)
            pinnedSessionIDs.insert(session.id)
            setStatusMessage("已置顶 \(session.title)")
        }
        saveSessionListPreferences()
        rebuildSessionIndexes()
    }

    func toggleSessionArchived(_ session: AgentSession) {
        if archivedSessionIDs.contains(session.id) {
            archivedSessionIDs.remove(session.id)
            setStatusMessage("已取消归档 \(session.title)")
        } else {
            archivedSessionIDs.insert(session.id)
            pinnedSessionIDs.remove(session.id)
            setStatusMessage("已归档 \(session.title)")
        }
        saveSessionListPreferences()
        rebuildSessionIndexes()
    }

    @discardableResult
    func toggleSessionArchivedRemote(_ session: AgentSession) async -> Bool {
        let shouldArchive = !archivedSessionIDs.contains(session.id)
        toggleSessionArchived(session)
        do {
            try await clientFactory().setSessionArchived(id: session.id, archived: shouldArchive)
            setStatusMessage(shouldArchive ? "已归档远端会话 \(session.title)" : "已取消远端归档 \(session.title)")
            return true
        } catch {
            setStatusMessage(
                shouldArchive
                    ? "已在本地归档，远端归档失败：\(error.localizedDescription)"
                    : "已在本地取消归档，远端取消失败：\(error.localizedDescription)"
            )
            return false
        }
    }

    func supportsCodexThreadManagement(_ session: AgentSession) -> Bool {
        Self.normalizedRuntimeProvider(session.runtimeProvider ?? session.source) == "codex"
    }

    @discardableResult
    func renameSession(_ session: AgentSession, name: String) async -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard supportsCodexThreadManagement(session), !normalized.isEmpty else {
            setStatusMessage("会话名称不能为空")
            return false
        }
        guard normalized.utf8.count <= 256 else {
            setStatusMessage("会话名称不能超过 256 bytes")
            return false
        }
        do {
            let client = try clientFactory()
            try await client.setThreadName(threadID: session.id, name: normalized)
            // 名称由 app-server 持久化；再读一次权威 thread，立即刷新侧栏，不维护第二份本地标题。
            if let refreshed = try? await client.session(id: session.id, afterSeq: nil) {
                upsert(refreshed.session)
            }
            setStatusMessage("已重命名会话为 \(normalized)")
            return true
        } catch {
            setStatusMessage("重命名失败：\(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func compactSessionContext(_ session: AgentSession) async -> Bool {
        guard supportsCodexThreadManagement(session) else {
            setStatusMessage("当前运行通道不支持手动压缩")
            return false
        }
        guard !session.isRunning else {
            setStatusMessage("请等待当前 Turn 完成后再压缩上下文")
            return false
        }
        do {
            try await clientFactory().compactThread(threadID: session.id)
            setStatusMessage("已开始压缩 \(session.title) 的上下文")
            return true
        } catch {
            setStatusMessage("上下文压缩失败：\(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func startReview(_ session: AgentSession, target: CodexAppServerReviewTarget) async -> Bool {
        let latestSession = sessionsByID[session.id] ?? session
        guard supportsCodexThreadManagement(latestSession) else {
            setStatusMessage("当前运行通道不支持 Codex Review")
            return false
        }
        guard !latestSession.isRunning else {
            setStatusMessage("请等待当前 Turn 完成后再开始 Review")
            return false
        }

        let normalizedTarget: CodexAppServerReviewTarget
        do {
            normalizedTarget = try target.validatedInlineTarget()
        } catch {
            setStatusMessage("Review 目标无效：\(error.localizedDescription)")
            return false
        }

        do {
            _ = try await clientFactory().startReview(
                threadID: latestSession.id,
                target: normalizedTarget,
                // 产品入口始终在原会话内执行，不能由调用方切换成 detached。
                delivery: .inline
            )
            setStatusMessage("已开始审查 \(latestSession.title)：\(reviewTargetDescription(normalizedTarget))")
            return true
        } catch {
            setStatusMessage("Review 启动失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 保留旧入口，避免已有调用方在 UI 升级期间产生行为变化。
    @discardableResult
    func reviewUncommittedChanges(_ session: AgentSession) async -> Bool {
        await startReview(session, target: .uncommittedChanges)
    }

    func reviewTargetDescription(_ target: CodexAppServerReviewTarget) -> String {
        switch target {
        case .uncommittedChanges:
            return "未提交改动"
        case .baseBranch(let branch):
            return "相对 \(branch) 的改动"
        case .commit(let sha, _):
            return "提交 \(sha)"
        case .custom:
            // validatedInlineTarget 已拒绝 custom；保留分支是为了让枚举扩展时编译器继续提示。
            return "自定义目标"
        }
    }

    func sessionReminder(for sessionID: SessionID) -> SessionReminder? {
        sessionRemindersByID[sessionID]
    }

    func scheduleSessionReminder(_ session: AgentSession, after interval: TimeInterval, now: Date = Date()) async {
        guard interval > 0 else {
            // 非法或已过的目标时间不能被 max(60, interval) 悄悄改成新的提醒；同时清掉同会话旧状态。
            let removed = sessionRemindersByID.removeValue(forKey: session.id) != nil
            if removed {
                saveSessionReminders()
            }
            sessionReminderScheduler.cancel(sessionID: session.id)
            setStatusMessage("提醒时间已过，未保存提醒 \(session.title)")
            return
        }
        let boundedInterval = max(60, interval)
        let reminder = SessionReminder(
            sessionID: session.id,
            title: session.title,
            fireAt: now.addingTimeInterval(boundedInterval),
            createdAt: now
        )
        guard !reminder.isDue(now: now) else {
            sessionRemindersByID.removeValue(forKey: session.id)
            saveSessionReminders()
            sessionReminderScheduler.cancel(sessionID: session.id)
            setStatusMessage("提醒时间已过，未保存提醒 \(session.title)")
            return
        }
        sessionRemindersByID[session.id] = reminder
        saveSessionReminders()

        do {
            // 先持久化，再尽力交给系统通知；即使用户未授权通知，侧栏仍能显示提醒状态。
            let route = SessionNotificationRoute.current(
                profileID: appStore.notificationRoutingProfileID,
                projectID: session.projectID,
                sessionID: session.id
            )
            switch try await sessionReminderScheduler.schedule(reminder, route: route) {
            case .scheduled:
                setStatusMessage("已设置提醒 \(session.title)")
            case .permissionDenied:
                setStatusMessage("已保存 App 内提醒；系统通知未开启，请在 iOS“设置 > 通知 > Mimi Remote”中开启")
            }
        } catch {
            setStatusMessage("已保存提醒，但通知调度失败：\(error.localizedDescription)")
        }
    }

    func clearSessionReminder(_ session: AgentSession) {
        sessionRemindersByID.removeValue(forKey: session.id)
        saveSessionReminders()
        sessionReminderScheduler.cancel(sessionID: session.id)
        setStatusMessage("已清除提醒 \(session.title)")
    }

    func isWorkspaceUnavailable(_ projectID: String) -> Bool {
        unavailableWorkspaceIDs.contains(projectID)
    }

    // 用户在 Mac 上恢复目录或修好配置后，点“重试”重新校验并加载；resolve 通过即自动清除不可用标记。
    func retryWorkspace(_ project: AgentProject) async {
        clearWorkspaceUnavailable(project.id)
        setErrorMessage(nil)
        await refreshSessions(forProjectID: project.id)
    }

    func toggleProjectExpansion(_ project: AgentProject) async {
        let workspace = ensureWorkspace(for: project)
        if expandedProjectIDs.contains(workspace.id) {
            removeExpandedProjectID(workspace.id)
            removeShowingAllSessionProjectID(workspace.id)
            return
        }

        insertExpandedProjectID(workspace.id)
        if selectedProjectID != workspace.id {
            setSelectedProjectID(workspace.id)
            setSelectedSessionID(nil)
            setErrorMessage(nil)
            disconnectWebSocket()
        }
#if DEBUG
        guard !isDebugWorkbenchUISeedActive else {
            setStatusMessage("Debug UI 样例已展开 \(project.name)")
            return
        }
#endif
        await refreshSessions(forProjectID: workspace.id)
    }

    func toggleSessionListExpansion(projectID: String) async {
        let currentLimit = sessionVisibleLimit(forProjectID: projectID)
        let loadedCount = sessions(forProjectID: projectID).count
        let isFullyExpanded = currentLimit > Self.sessionPreviewLimit &&
            currentLimit >= loadedCount &&
            !canLoadMoreSessions(projectID: projectID)

        if isFullyExpanded {
            setSessionVisibleLimit(nil, forProjectID: projectID)
            return
        }

        let nextLimit = currentLimit + Self.sessionExpansionStep
        setSessionVisibleLimit(nextLimit, forProjectID: projectID)
        if canLoadMoreSessions(projectID: projectID), nextLimit >= loadedCount {
            await loadMoreSessions(projectID: projectID)
        }
    }

    func loadMoreSessions(projectID: String) async {
        var projectID = projectID
        guard let workspace = ensureWorkspaceForKnownProjectID(projectID) else {
            return
        }
        projectID = workspace.id
        guard let cursor = sessionPageCursorByProjectID[projectID],
              canLoadMoreSessions(projectID: projectID),
              sessionPageLoadingTokenByProjectID[projectID] == nil
        else {
            return
        }
        var requestToken: Int?
        do {
            let client = try clientFactory()
            requestToken = beginSessionPageRequest(projectID: projectID)
            defer { finishSessionPageRequest(projectID: projectID, token: requestToken ?? 0) }
            let page = try await client.sessionsPage(workspace: workspace, cursor: cursor, limit: Self.expandedSessionPageLimit)
            guard isCurrentSessionPageRequest(projectID: projectID, token: requestToken ?? 0) else {
                return
            }
            mergeSessionPage(sessions(page.sessions, in: workspace))
            updateSessionPageState(projectID: projectID, page: page)
            clearWorkspaceUnavailable(projectID)
            setErrorMessage(nil)
        } catch {
            if let requestToken, !isCurrentSessionPageRequest(projectID: projectID, token: requestToken) {
                return
            }
            setErrorMessage(error.localizedDescription)
        }
    }

    func refreshSelectedProjectSessions(showLoading: Bool = true) async {
        guard let selectedProjectID else {
            return
        }
        await refreshSessions(forProjectID: selectedProjectID, showLoading: showLoading)
    }

    /// 为单一全局侧栏加载跨工作区轻量索引。只取 thread/list 首屏，不读取任何消息历史。
    func refreshSessionLibraryIndex() async {
#if DEBUG
        guard !isDebugWorkbenchUISeedActive else { return }
#endif
        defer { lastSessionLibraryIndexRefreshAt = sessionListNow() }
        // 全局“最近历史”最终只展示 8 条，但“进行中”不能沿用这个数量限制。
        // 每个工作区读取标准 20 条轻量索引，不加载消息正文，在可见性和弱网成本间取 MVP 平衡。
        let workspaces = recentWorkspaces.filter { workspace in
            // 当前工作区已经由 refreshAll/轮询维护完整首屏时，会话库直接复用本地投影。
            // 再发一次相同 thread/list 只会重复占用 gateway 预算。
            !(workspace.id == selectedProjectID && !sessions(forProjectID: workspace.id).isEmpty)
        }
        guard !workspaces.isEmpty else { return }
        let generation = appStore.connectionGeneration

        // 两个一组并发，兼顾首屏速度和本机 app-server 压力；底层继续复用 single-flight/短缓存。
        for start in stride(from: 0, to: workspaces.count, by: 2) {
            guard generation == appStore.connectionGeneration, !Task.isCancelled else { return }
            let first = workspaces[start]
            if start + 1 < workspaces.count {
                let second = workspaces[start + 1]
                async let firstResult = sessionLibraryPage(workspace: first)
                async let secondResult = sessionLibraryPage(workspace: second)
                let results = await [firstResult, secondResult]
                mergeSessionLibraryPages(results, generation: generation)
            } else {
                let result = await sessionLibraryPage(workspace: first)
                mergeSessionLibraryPages([result], generation: generation)
            }
        }
    }

    func applyNetworkReachabilityStatus(_ update: NetworkPathStatusUpdate) {
        // MainActor 上只接收最新观察序号。即使旧 Task 晚到，也不能把较新的在线状态覆盖成离线。
        guard update.sequence > lastAppliedNetworkPathSequence else {
            return
        }
        lastAppliedNetworkPathSequence = update.sequence
        let status = update.status
        guard status != networkReachabilityStatus else {
            return
        }
        let previousStatus = networkReachabilityStatus
        networkReachabilityStatus = status
        networkPathGeneration += 1
        let generation = networkPathGeneration
        networkRecoveryTask?.cancel()
        networkRecoveryTask = nil

        if status == .unsatisfied {
            // 网络已明确不可用时立即结束搜索 loading，并用 generation 阻止 transport 的迟到响应落地。
            cancelRemoteSessionSearchRequestsPreservingResults()
            cancelWebSocketReconnect(resetAttempts: false)
            // 访问码失效是更高优先级的确定性终态，离线提示不能覆盖重新配对指引。
            guard connectionTermination == nil, !appStore.requiresRePairing else {
                return
            }
            stopAllQueuedSessionMonitoring()
            suspendWebSocketForNetworkLoss()
            setStatusMessage("网络不可用，恢复后自动重连")
            return
        }

        let shouldRecover = previousStatus == .unsatisfied
            || (previousStatus == .unknown
                && (networkSuspendedSessionID != nil || errorMessage != nil))
        guard status == .satisfied,
              shouldRecover,
              !isAppInBackground,
              connectionTermination == nil,
              !appStore.requiresRePairing else {
            return
        }
        // unknown 是 NWPathMonitor 首次回调前的正常状态；只有已经存在传输错误或挂起会话时
        // 才复用现有单次恢复任务，避免健康冷启动额外刷新，也不引入常驻 timer。
        setStatusMessage("网络已恢复，正在重新连接")
        let connectionGeneration = appStore.connectionGeneration
        networkRecoveryTask = Task { [weak self] in
            await self?.recoverAfterNetworkBecameAvailable(
                pathGeneration: generation,
                connectionGeneration: connectionGeneration
            )
        }
    }

    func suspendWebSocketForNetworkLoss(sessionID: SessionID? = nil) {
        let reconnectSessionID = sessionID
            ?? connectedSessionID
            ?? (webSocketReconnectTask == nil ? nil : selectedSessionID)
            ?? appLifecycleSuspendedSessionID
        if let reconnectSessionID, sessionsByID[reconnectSessionID] != nil {
            networkSuspendedSessionID = reconnectSessionID
            appLifecycleSuspendedSessionID = nil
        }
        cancelWebSocketReconnect(resetAttempts: false)
        webSocketConnectionGeneration += 1
        let socket = webSocket
        webSocket = nil
        connectedSessionID = nil
        socket?.disconnect()
        if let reconnectSessionID {
            markDispatchingQueuedTurnsNeedsConfirmation(
                sessionID: reconnectSessionID,
                message: "网络中断，发送结果需要确认"
            )
        }
        // 离线只是暂停传输：不清本地消息、running turn 排队、审批或补充信息状态。
        setWebSocketStatus(.disconnected)
    }

    func recoverAfterNetworkBecameAvailable(
        pathGeneration: Int,
        connectionGeneration: Int
    ) async {
        guard pathGeneration == networkPathGeneration,
              connectionGeneration == appStore.connectionGeneration,
              networkReachabilityStatus == .satisfied,
              !isAppInBackground,
              connectionTermination == nil,
              !appStore.requiresRePairing else {
            return
        }

        let reconnectSessionID = networkSuspendedSessionID
        networkSuspendedSessionID = nil
        if let reconnectSessionID,
           selectedSessionID == reconnectSessionID,
           let session = sessionsByID[reconnectSessionID] {
            // 恢复事件按 path generation 去重；这里只发起一次即时连接，失败后再进入 jitter 退避。
            connectWebSocket(session, isReconnectAttempt: true, allowNonRunning: true)
        }

        await reconcilePersistedQueuedTurns()
        ensureAllQueuedSessionMonitoring()

        guard pathGeneration == networkPathGeneration,
              connectionGeneration == appStore.connectionGeneration,
              networkReachabilityStatus == .satisfied,
              connectionTermination == nil,
              !appStore.requiresRePairing,
              selectedProjectID != nil else {
            return
        }
        // 可见轮询在离线期间不会发 REST；恢复后补一次轻量刷新，不等待原轮询 sleep 到期。
        await refreshSelectedProjectSessions(showLoading: false)
    }

    func pollSelectedProjectSessionsWhileVisible() async {
        while !Task.isCancelled {
            if connectionTermination != nil || appStore.requiresRePairing {
                return
            }
            await sessionListSleep(sessionListPollingDelayNanoseconds())
            if Task.isCancelled {
                return
            }
#if DEBUG
            guard !isDebugWorkbenchUISeedActive else {
                continue
            }
#endif
            guard !isNetworkUnavailable,
                  appStore.isConfigured,
                  selectedProjectID != nil else {
                continue
            }
            await refreshSelectedProjectSessions(showLoading: false)
            await refreshSessionLibraryIndexIfStale()
        }
    }

    func refreshSessionLibraryIndexIfStale() async {
        if let lastSessionLibraryIndexRefreshAt,
           sessionListNow().timeIntervalSince(lastSessionLibraryIndexRefreshAt) < sessionLibraryIndexPollingInterval {
            return
        }
        await refreshSessionLibraryIndex()
    }

    func sessionListPollingDelayNanoseconds() -> UInt64 {
        webSocketStatus == .connected
            ? sessionListConnectedPollingDelayNanoseconds
            : sessionListDisconnectedPollingDelayNanoseconds
    }

}
