import XCTest
import Combine
import Security
import SwiftUI
import UIKit
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testRecentSessionSortUsesUserRecencyInsteadOfAgentUpdatedAt() {
        let project = makeProject(id: "proj_recency_sort")
        let first = makeSession(
            id: "session_first",
            projectID: project.id,
            title: "用户刚操作",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 20),
            recencyAt: Date(timeIntervalSince1970: 200)
        )
        var noisy = makeSession(
            id: "session_noisy",
            projectID: project.id,
            title: "后台持续输出",
            status: "running",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 300),
            recencyAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(SessionIndexStore.sortedSessions([noisy, first]).map(\.id), [first.id, noisy.id])

        noisy.updatedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            SessionIndexStore.sortedSessions([noisy, first]).map(\.id),
            [first.id, noisy.id],
            "Agent 输出只能推进 updatedAt，不能改变最近用户活动顺序"
        )
    }

    func testRecentActivityProjectionSurvivesTemporaryIDAndStaleListPage() throws {
        let project = makeProject(id: "proj_recent_projection")
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: []) }
        )
        let temporaryID = "local:\(project.id):message-1"
        let realID = "thread-real"
        store.sessions = [makeSession(
            id: temporaryID,
            projectID: project.id,
            title: "刚创建",
            status: "running",
            source: SessionStore.optimisticSessionSource
        )]

        store.setSessionRecentActivityProjection(sessionID: temporaryID, clientMessageID: "message-1")
        let localRecency = try XCTUnwrap(store.sessionsByID[temporaryID]?.recencyAt)
        store.moveSessionRecentActivityProjection(from: temporaryID, to: realID, clientMessageID: "message-1")
        store.upsert(makeSession(
            id: realID,
            projectID: project.id,
            title: "刚创建",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 10),
            recencyAt: Date(timeIntervalSince1970: 10)
        ))
        store.removeSession(temporaryID)

        XCTAssertEqual(store.sessions.map(\.id), [realID])
        XCTAssertEqual(store.sessionsByID[realID]?.recencyAt, localRecency)
        XCTAssertNotNil(store.recentActivityProjectionBySessionID[realID])

        let stalePage = store.pageSessionsPreservingLoadedWindow([], projectID: project.id)
        XCTAssertEqual(stalePage.map(\.id), [realID], "旧缓存或旧 single-flight 响应不能删除刚创建的会话")

        let acknowledged = makeSession(
            id: realID,
            projectID: project.id,
            title: "刚创建",
            status: "history",
            source: "codex",
            updatedAt: localRecency.addingTimeInterval(1),
            recencyAt: localRecency.addingTimeInterval(1)
        )
        let confirmedPage = store.pageSessionsPreservingLoadedWindow([acknowledged], projectID: project.id)
        store.replaceSessionsIfChanged(with: confirmedPage, projectID: project.id)

        XCTAssertNil(store.recentActivityProjectionBySessionID[realID])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(store.sessionsByID[realID]?.recencyAt), localRecency)
    }

    func testAssistantPreviewProjectionDoesNotChangeUserRecency() throws {
        let project = makeProject(id: "proj_assistant_projection")
        let session = makeSession(
            id: "thread-projection",
            projectID: project.id,
            title: "会话",
            status: "running",
            source: "codex",
            recencyAt: Date(timeIntervalSince1970: 100)
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [session]) }
        )
        store.sessions = [session]
        store.setSessionListProjection(
            sessionID: session.id,
            preview: "用户输入",
            source: .localUser,
            clientMessageID: "message-user"
        )
        let userRecency = try XCTUnwrap(store.sessionsByID[session.id]?.recencyAt)

        store.setSessionListProjection(
            sessionID: session.id,
            preview: "Agent 后台完成",
            source: .localAssistant,
            clientMessageID: nil
        )

        XCTAssertEqual(store.sessionsByID[session.id]?.recencyAt, userRecency)
        XCTAssertEqual(store.recentActivityProjectionBySessionID[session.id]?.clientMessageID, "message-user")

        store.clearSessionRecentActivityProjection(sessionID: session.id, clientMessageID: "message-user")
        XCTAssertEqual(
            store.sessionsByID[session.id]?.recencyAt,
            Date(timeIntervalSince1970: 100),
            "明确发送失败时应恢复用户操作前的最近顺序"
        )
    }

    func testWorktreeDescriptorKeepsUnknownGitStateFailClosedForLegacyServer() throws {
        let current = try JSONDecoder().decode(
            WorktreeDescriptor.self,
            from: Data(#"{"path":"/tmp/wt","repository_path":"/tmp/repo","base":"main","git_state":"clean","dirty":false,"root_project_id":"repo","root_project_name":"Repo","root_project_path":"/tmp/repo"}"#.utf8)
        )
        XCTAssertEqual(current.gitState, "clean")
        XCTAssertFalse(current.dirty)

        let legacy = try JSONDecoder().decode(
            WorktreeDescriptor.self,
            from: Data(#"{"path":"/tmp/wt","repository_path":"/tmp/repo","base":"main","dirty":false,"root_project_id":"repo","root_project_name":"Repo","root_project_path":"/tmp/repo"}"#.utf8)
        )
        XCTAssertEqual(legacy.gitState, "unknown", "旧服务缺少 git_state 时不能把 dirty=false 当成已证明干净")
    }

    func testSessionStoreRefreshesWorktreeBranches() async {
        let project = makeProject(id: "proj_1")
        let response = WorktreeBranchListResponse(
            path: project.path,
            defaultBase: "main",
            currentBranch: "main",
            branches: [
                WorktreeBranchItem(name: "main", kind: "local", isCurrent: true, isDefault: true),
                WorktreeBranchItem(name: "origin/main", kind: "remote")
            ]
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            worktreeBranchResults: [project.path: .success(response)]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshWorktreeBranches(path: " \(project.path) ")

        XCTAssertEqual(client.requestedWorktreeBranchPaths, [project.path])
        XCTAssertEqual(store.worktreeBranches(path: project.path), response)
        XCTAssertNil(store.worktreeBranchError(path: project.path))
    }

    func testSessionStoreCreatesWorktreeAndOpensReturnedWorkspace() async {
        let project = makeProject(id: "proj_1")
        let workspace = AgentWorkspace(
            id: "ws_worktree",
            name: "feature-review",
            path: "/tmp/worktrees/proj_1/feature-review",
            rootProjectID: project.id,
            rootProjectName: project.name,
            rootProjectPath: project.path
        )
        let worktreeSession = makeSession(
            id: "codex_worktree",
            projectID: workspace.id,
            title: "Worktree 会话",
            status: "history",
            source: "codex",
            resumeID: "worktree"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectSessions: [project.id: [worktreeSession]],
            worktreeCreateResults: [
                project.path: .success(WorktreeCreateResponse(
                    workspace: workspace,
                    worktree: WorktreeDescriptor(
                        path: workspace.path,
                        repositoryPath: project.path,
                        base: "main",
                        branch: "mimi/feature-review",
                        rootProjectID: project.id,
                        rootProjectName: project.name,
                        rootProjectPath: project.path
                    )
                ))
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        let opened = await store.createWorktreeAndOpen(
            project: project,
            name: " feature-review ",
            base: " main ",
            branch: " mimi/feature-review "
        )

        XCTAssertTrue(opened)
        XCTAssertEqual(client.requestedWorktreeCreates, [
            RequestedWorktreeCreate(path: project.path, name: "feature-review", base: "main", branch: "mimi/feature-review")
        ])
        XCTAssertEqual(store.selectedProjectID, workspace.id)
        XCTAssertEqual(store.selectedProject?.path, workspace.path)
        XCTAssertEqual(client.requestedWorkspaceIDs.last, workspace.id)
        XCTAssertEqual(store.filteredSidebarProjects.map(\.id).contains(workspace.id), true)
        XCTAssertEqual(store.managedWorktrees.map(\.workspace.id), [workspace.id])
    }

    func testSessionStoreHandoffsSessionWithNativeForkWhenAvailable() async {
        let project = makeProject(id: "proj_1")
        let source = makeSession(
            id: "codex_source",
            projectID: project.id,
            title: "审核修复",
            status: "history",
            source: "codex",
            resumeID: "thread_source"
        )
        let workspace = AgentWorkspace(
            id: "ws_handoff",
            name: "audit-handoff",
            path: "/tmp/worktrees/proj_1/audit-handoff",
            rootProjectID: project.id,
            rootProjectName: project.name,
            rootProjectPath: project.path
        )
        let forked = makeSession(
            id: "thread_forked",
            projectID: workspace.id,
            title: "Forked",
            status: "history",
            source: "codex",
            resumeID: "thread_forked"
        )
        let descriptor = WorktreeDescriptor(
            path: workspace.path,
            repositoryPath: project.path,
            base: "main",
            branch: "mimi/audit-handoff",
            rootProjectID: project.id,
            rootProjectName: project.name,
            rootProjectPath: project.path
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [source],
            sessionForkResults: [
                "thread_source": .success(forked)
            ],
            worktreeCreateResults: [
                project.path: .success(WorktreeCreateResponse(workspace: workspace, worktree: descriptor))
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        let handedOff = await store.handoffSessionToWorktree(source, name: "audit handoff")

        XCTAssertTrue(handedOff)
        XCTAssertEqual(client.requestedSessionForks, [
            RequestedSessionFork(threadID: "thread_source", workspaceID: workspace.id)
        ])
        XCTAssertTrue(client.createPayloads.isEmpty)
        XCTAssertEqual(store.selectedProjectID, workspace.id)
        XCTAssertEqual(store.selectedSessionID, forked.id)
        XCTAssertEqual(store.managedWorktrees.map(\.workspace.id), [workspace.id])
    }

    func testSessionStoreHandoffsSessionToNewWorktree() async throws {
        let project = makeProject(id: "proj_1")
        let source = makeSession(
            id: "codex_source",
            projectID: project.id,
            title: "审核修复",
            status: "history",
            source: "codex",
            resumeID: "thread_source",
            preview: "继续处理审核问题"
        )
        let workspace = AgentWorkspace(
            id: "ws_handoff",
            name: "audit-handoff",
            path: "/tmp/worktrees/proj_1/audit-handoff",
            rootProjectID: project.id,
            rootProjectName: project.name,
            rootProjectPath: project.path
        )
        let created = makeSession(
            id: "codex_handoff",
            projectID: workspace.id,
            title: "Worktree Handoff",
            status: "running",
            source: "codex"
        )
        let descriptor = WorktreeDescriptor(
            path: workspace.path,
            repositoryPath: project.path,
            base: "main",
            branch: "mimi/audit-handoff",
            rootProjectID: project.id,
            rootProjectName: project.name,
            rootProjectPath: project.path
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [source],
            createSessionResponse: try makeCreateSessionResponse(session: created),
            worktreeCreateResults: [
                project.path: .success(WorktreeCreateResponse(workspace: workspace, worktree: descriptor))
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        let handedOff = await store.handoffSessionToWorktree(
            source,
            name: " audit handoff ",
            base: " main ",
            branch: " mimi/audit-handoff "
        )

        XCTAssertTrue(handedOff)
        XCTAssertEqual(client.requestedWorktreeCreates, [
            RequestedWorktreeCreate(path: project.path, name: "audit handoff", base: "main", branch: "mimi/audit-handoff")
        ])
        XCTAssertEqual(client.requestedSessionForks, [
            RequestedSessionFork(threadID: "thread_source", workspaceID: workspace.id)
        ])
        XCTAssertEqual(client.createPayloads.count, 1)
        guard let payload = client.createPayloads.first else {
            return XCTFail("handoff 应创建一个新会话")
        }
        XCTAssertEqual(payload.projectID, workspace.id)
        XCTAssertEqual(payload.projectPath, workspace.path)
        XCTAssertEqual(payload.rootProjectID, project.id)
        XCTAssertEqual(payload.resumeID, "")
        XCTAssertEqual(payload.turnOptions.sessionStartSource, "mimi_remote_worktree_handoff")
        XCTAssertEqual(payload.turnOptions.threadSource, "worktree_handoff")
        XCTAssertTrue(payload.prompt.contains("线程 ID：thread_source"))
        XCTAssertTrue(payload.prompt.contains("原工作区：\(project.path)"))
        XCTAssertTrue(payload.prompt.contains("路径：\(workspace.path)"))
        XCTAssertEqual(store.selectedProjectID, workspace.id)
        XCTAssertEqual(store.selectedSessionID, created.id)
        XCTAssertEqual(store.managedWorktrees.map(\.workspace.id), [workspace.id])
    }

    func testSessionStoreRejectsRunningSessionWorktreeHandoff() async {
        let project = makeProject(id: "proj_1")
        let running = makeSession(
            id: "codex_running",
            projectID: project.id,
            title: "运行中",
            status: "running",
            source: "codex"
        )
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        let handedOff = await store.handoffSessionToWorktree(running)

        XCTAssertFalse(handedOff)
        XCTAssertTrue(client.requestedWorktreeCreates.isEmpty)
        XCTAssertEqual(store.errorMessage, L10n.text("ui.running_sessions_cannot_go_directly_to_worktree_please"))
    }

    func testSessionStoreRefreshesOpensAndDeletesManagedWorktree() async {
        let project = makeProject(id: "proj_1")
        let workspace = AgentWorkspace(
            id: "ws_worktree",
            name: "feature-review",
            path: "/tmp/worktrees/proj_1/feature-review",
            rootProjectID: project.id,
            rootProjectName: project.name,
            rootProjectPath: project.path
        )
        let item = WorktreeListItem(
            workspace: workspace,
            worktree: WorktreeDescriptor(
                path: workspace.path,
                repositoryPath: project.path,
                base: "HEAD",
                branch: "mimi/feature-review",
                rootProjectID: project.id,
                rootProjectName: project.name,
                rootProjectPath: project.path
            )
        )
        let worktreeSession = makeSession(
            id: "codex_worktree",
            projectID: workspace.id,
            title: "Worktree 会话",
            status: "history",
            source: "codex",
            resumeID: "worktree"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            workspaceSessions: [workspace.id: [worktreeSession]],
            worktreeListResult: .success([item]),
            worktreeDeleteResults: [
                workspace.path: .success(WorktreeDeleteResponse(
                    deletedPath: workspace.path,
                    worktrees: [],
                    workspace: nil,
                    worktree: nil
                ))
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        await store.refreshManagedWorktrees()
        let opened = await store.openManagedWorktree(item)
        let deleted = await store.deleteManagedWorktree(item)

        XCTAssertTrue(opened)
        XCTAssertTrue(deleted)
        XCTAssertEqual(client.worktreeListCallCount, 1)
        XCTAssertEqual(client.requestedWorkspaceIDs.last, workspace.id)
        XCTAssertEqual(client.requestedWorktreeDeletes, [
            RequestedWorktreeDelete(path: workspace.path, force: false)
        ])
        XCTAssertTrue(store.managedWorktrees.isEmpty)
        XCTAssertNil(store.selectedProjectID)
        XCTAssertFalse(store.filteredSidebarProjects.map(\.id).contains(workspace.id))
    }

    func testSessionStoreDoesNotDeleteRunningManagedWorktree() async {
        let project = makeProject(id: "proj_1")
        let workspace = AgentWorkspace(
            id: "ws_worktree",
            name: "feature-review",
            path: "/tmp/worktrees/proj_1/feature-review",
            rootProjectID: project.id,
            rootProjectName: project.name,
            rootProjectPath: project.path
        )
        let item = WorktreeListItem(
            workspace: workspace,
            worktree: WorktreeDescriptor(
                path: workspace.path,
                repositoryPath: project.path,
                base: "HEAD",
                branch: "mimi/feature-review",
                rootProjectID: project.id,
                rootProjectName: project.name,
                rootProjectPath: project.path
            )
        )
        let runningSession = makeSession(
            id: "codex_running_worktree",
            projectID: workspace.id,
            title: "运行中",
            status: "running",
            source: "codex",
            resumeID: "running"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            workspaceSessions: [workspace.id: [runningSession]],
            worktreeListResult: .success([item])
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        await store.refreshManagedWorktrees()
        _ = await store.openManagedWorktree(item)
        let deleted = await store.deleteManagedWorktree(item)

        XCTAssertFalse(deleted)
        XCTAssertTrue(client.requestedWorktreeDeletes.isEmpty)
        XCTAssertEqual(store.worktreeErrorMessage, L10n.text("ui.this_worktree_also_has_a_running_session_stop"))
    }

    func testSessionStoreAppliesDeletedWorktreeBeforeRegistryCleanupWarning() async {
        let project = makeProject(id: "proj_delete_registry_warning")
        let workspace = makeChildWorkspace(id: "ws_delete_registry_warning", name: "deleted-checkout", root: project)
        let item = WorktreeListItem(
            workspace: workspace,
            worktree: WorktreeDescriptor(
                path: workspace.path,
                repositoryPath: project.path,
                base: "main",
                branch: "mimi/deleted-checkout",
                rootProjectID: project.id,
                rootProjectName: project.name,
                rootProjectPath: project.path
            )
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            worktreeListResult: .success([item]),
            worktreeDeleteResults: [
                workspace.path: .success(WorktreeDeleteResponse(
                    deletedPath: workspace.path,
                    worktrees: [item],
                    workspace: workspace,
                    worktree: item.worktree,
                    registryCleanupError: "registry 文件只读"
                ))
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshManagedWorktrees()
        let deleted = await store.deleteManagedWorktree(item)

        XCTAssertTrue(deleted, "checkout 已删除时 registry 收尾失败仍应返回成功")
        XCTAssertTrue(store.managedWorktrees.isEmpty, "陈旧的 response.worktrees 不能把已删除 checkout 放回 UI")
        XCTAssertEqual(
            store.statusMessage,
            L10n.format("ui.git_worktree_value_has_been_deleted_but_the", workspace.name)
        )
        XCTAssertEqual(
            store.worktreeErrorMessage,
            L10n.format(
                "ui.git_worktree_was_deleted_but_cleanup_management_registration",
                "registry 文件只读"
            )
        )
    }

    func testSessionStorePrunesMissingManagedWorktreeRegistry() async {
        let project = makeProject(id: "proj_1")
        let workspace = AgentWorkspace(
            id: "ws_worktree",
            name: "feature-review",
            path: "/tmp/worktrees/proj_1/feature-review",
            rootProjectID: project.id,
            rootProjectName: project.name,
            rootProjectPath: project.path
        )
        let item = WorktreeListItem(
            workspace: workspace,
            worktree: WorktreeDescriptor(
                path: workspace.path,
                repositoryPath: project.path,
                base: "main",
                branch: "mimi/feature-review",
                rootProjectID: project.id,
                rootProjectName: project.name,
                rootProjectPath: project.path
            )
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            worktreeListResult: .success([item]),
            worktreePruneResult: .success(WorktreePruneResponse(prunedPaths: [workspace.path], worktrees: []))
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        await store.refreshManagedWorktrees()
        let prunedCount = await store.pruneMissingManagedWorktrees()

        XCTAssertEqual(prunedCount, 1)
        XCTAssertEqual(client.worktreePruneCallCount, 1)
        XCTAssertTrue(store.managedWorktrees.isEmpty)
        XCTAssertNil(store.worktreeErrorMessage)
    }

    func testSessionStoreAppliesPrunedPathsBeforeReportingPartialRegistryFailure() async {
        let project = makeProject(id: "proj_prune_partial")
        let prunedWorkspace = makeChildWorkspace(id: "ws_pruned", name: "missing-pruned", root: project)
        let failedWorkspace = makeChildWorkspace(id: "ws_failed", name: "missing-failed", root: project)
        let prunedItem = WorktreeListItem(
            workspace: prunedWorkspace,
            worktree: WorktreeDescriptor(
                path: prunedWorkspace.path,
                repositoryPath: project.path,
                base: "main",
                branch: "mimi/missing-pruned",
                rootProjectID: project.id,
                rootProjectName: project.name,
                rootProjectPath: project.path
            )
        )
        let failedItem = WorktreeListItem(
            workspace: failedWorkspace,
            worktree: WorktreeDescriptor(
                path: failedWorkspace.path,
                repositoryPath: project.path,
                base: "main",
                branch: "mimi/missing-failed",
                rootProjectID: project.id,
                rootProjectName: project.name,
                rootProjectPath: project.path
            )
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            worktreeListResult: .success([prunedItem, failedItem]),
            worktreePruneResult: .success(WorktreePruneResponse(
                prunedPaths: [prunedWorkspace.path],
                worktrees: [failedItem],
                failedPaths: [failedWorkspace.path: "registry 文件只读"]
            ))
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshManagedWorktrees()
        let prunedCount = await store.pruneMissingManagedWorktrees()

        XCTAssertEqual(prunedCount, 1, "返回值只统计已经成功 prune 的路径")
        XCTAssertEqual(store.managedWorktrees.map(\.workspace.id), [failedWorkspace.id])
        XCTAssertEqual(
            store.statusMessage,
            L10n.format(
                "ui.git_worktree_cleanup_partial_success",
                L10n.plural("ui.worktree_registrations_cleaned_count", count: 1)
            )
        )
        XCTAssertEqual(
            store.worktreeErrorMessage,
            L10n.format(
                "ui.value_missing_worktree_entries_cleaned_up_but_value",
                L10n.plural("ui.worktree_registrations_cleaned_count", count: 1),
                L10n.plural("ui.worktree_cleanup_failures_count", count: 1),
                L10n.format("ui.labeled_value", failedWorkspace.path, "registry 文件只读")
            )
        )
    }

    func testSessionStoreReportsIncompleteCleanupWhenNoRegistryCanBePruned() async {
        let project = makeProject(id: "proj_prune_failed")
        let failedWorkspace = makeChildWorkspace(id: "ws_prune_failed", name: "missing-failed", root: project)
        let failedItem = WorktreeListItem(
            workspace: failedWorkspace,
            worktree: WorktreeDescriptor(
                path: failedWorkspace.path,
                repositoryPath: project.path,
                base: "main",
                branch: "mimi/missing-failed",
                rootProjectID: project.id,
                rootProjectName: project.name,
                rootProjectPath: project.path
            )
        )
        let failureDetail = "registry 文件只读"
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            worktreeListResult: .success([failedItem]),
            worktreePruneResult: .success(WorktreePruneResponse(
                prunedPaths: [],
                worktrees: [failedItem],
                failedPaths: [failedWorkspace.path: failureDetail]
            ))
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshManagedWorktrees()
        let prunedCount = await store.pruneMissingManagedWorktrees()

        XCTAssertEqual(prunedCount, 0)
        XCTAssertEqual(store.managedWorktrees.map(\.workspace.id), [failedWorkspace.id])
        XCTAssertEqual(
            store.statusMessage,
            L10n.text("ui.worktree_registration_cleanup_not_completed")
        )
        XCTAssertEqual(
            store.worktreeErrorMessage,
            L10n.format(
                "ui.value_missing_worktree_entries_cleaned_up_but_value",
                L10n.plural("ui.worktree_registrations_cleaned_count", count: 0),
                L10n.plural("ui.worktree_cleanup_failures_count", count: 1),
                L10n.format("ui.labeled_value", failedWorkspace.path, failureDetail)
            )
        )
    }

    func testSessionStorePreviewsAndExecutesOnlyEligibleWorktreeCleanup() async throws {
        let project = makeProject(id: "proj_cleanup")
        let eligible = makeWorktreeCleanupItem(
            project: project,
            workspaceID: "ws_old",
            name: "old-clean",
            eligible: true
        )
        let blocked = makeWorktreeCleanupItem(
            project: project,
            workspaceID: "ws_dirty",
            name: "dirty",
            eligible: false,
            blockers: [WorktreeCleanupBlocker(rawValue: "git_dirty")]
        )
        let preview = makeWorktreeCleanupResponse(
            items: [eligible, blocked],
            candidatePaths: [eligible.worktree.path]
        )
        let executed = makeWorktreeCleanupResponse(
            items: [blocked],
            candidatePaths: [],
            deletedPaths: [eligible.worktree.path]
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            worktreeListResult: .success([]),
            worktreeCleanupPreviewResult: .success(preview),
            worktreeCleanupExecutionResult: .success(executed)
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        let loadedPreview = try await store.previewManagedWorktreeCleanup()
        let response = try await store.cleanupManagedWorktrees(
            paths: [eligible.worktree.path],
            preview: loadedPreview
        )

        XCTAssertEqual(client.worktreeCleanupPreviewCallCount, 1)
        XCTAssertEqual(client.requestedWorktreeCleanupPaths, [[eligible.worktree.path]])
        XCTAssertEqual(client.requestedWorktreeCleanupPlanIDs, ["wtc_test_plan"])
        XCTAssertEqual(response.deletedPaths, [eligible.worktree.path])
        XCTAssertEqual(client.worktreeListCallCount, 1, "执行后应刷新 managed Worktree 列表")
        XCTAssertEqual(store.statusMessage, L10n.plural("ui.git_worktrees_cleaned_count", count: 1))
        XCTAssertNil(store.worktreeErrorMessage)
    }

    func testSessionStoreRejectsBlockedWorktreeWithoutCallingCleanupAPI() async {
        let project = makeProject(id: "proj_cleanup_blocked")
        let blocked = makeWorktreeCleanupItem(
            project: project,
            workspaceID: "ws_running",
            name: "running",
            eligible: false,
            blockers: [WorktreeCleanupBlocker(rawValue: "session_running")]
        )
        let preview = makeWorktreeCleanupResponse(items: [blocked], candidatePaths: [])
        let client = MockSessionStoreClient(projects: [project], sessions: [])
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        do {
            _ = try await store.cleanupManagedWorktrees(paths: [blocked.worktree.path], preview: preview)
            XCTFail("包含 blocker 的路径不能进入清理 API")
        } catch {
            XCTAssertEqual(error as? WorktreeCleanupSelectionError, .containsBlockedPath)
        }
        XCTAssertTrue(client.requestedWorktreeCleanupPaths.isEmpty)
    }

    func testSessionStoreRefreshesDeletedWorktreesBeforeReportingPartialCleanupFailure() async throws {
        let project = makeProject(id: "proj_cleanup_partial")
        let first = makeWorktreeCleanupItem(
            project: project,
            workspaceID: "ws_cleanup_first",
            name: "old-first",
            eligible: true
        )
        let second = makeWorktreeCleanupItem(
            project: project,
            workspaceID: "ws_cleanup_second",
            name: "old-second",
            eligible: true
        )
        let preview = makeWorktreeCleanupResponse(
            items: [first, second],
            candidatePaths: [first.worktree.path, second.worktree.path]
        )
        let executed = makeWorktreeCleanupResponse(
            items: [first, second],
            candidatePaths: [first.worktree.path, second.worktree.path],
            deletedPaths: [first.worktree.path],
            failedPath: second.worktree.path,
            error: "git worktree remove 失败"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            worktreeListResult: .success([]),
            worktreeCleanupExecutionResult: .success(executed)
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        let response = try await store.cleanupManagedWorktrees(
            paths: [second.worktree.path, first.worktree.path],
            preview: preview
        )

        XCTAssertTrue(response.hasPartialFailure)
        XCTAssertEqual(client.requestedWorktreeCleanupPaths, [[first.worktree.path, second.worktree.path].sorted()])
        XCTAssertEqual(client.worktreeListCallCount, 1, "部分成功也必须刷新 managed Worktree 列表")
        XCTAssertEqual(
            store.statusMessage,
            L10n.format(
                "ui.git_worktree_cleanup_partial_success",
                L10n.plural("ui.git_worktrees_cleaned_count", count: 1)
            )
        )
        XCTAssertEqual(store.worktreeErrorMessage, response.partialFailureMessage)
    }

    func testSessionStoreProjectIndexKeepsPreviousSelectionAfterRefresh() async {
        let firstProject = makeProject(id: "proj_1")
        let secondProject = makeProject(id: "proj_2")
        let client = MockSessionStoreClient(projects: [firstProject, secondProject], sessions: [])
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = secondProject.id
        await store.refreshAll(autoAttach: false)

        XCTAssertEqual(store.selectedProject?.id, secondProject.id)
        XCTAssertEqual(store.selectedProjectID, secondProject.id)
    }

    func testRepeatedProjectRefreshDoesNotPublishUnchangedProjections() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史", status: "history", source: "codex", resumeID: "history")
        let client = MockSessionStoreClient(projects: [project], sessions: [history])
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        var publishCount = 0
        var cancellables: Set<AnyCancellable> = []
        store.objectWillChange
            .sink { _ in publishCount += 1 }
            .store(in: &cancellables)

        await store.refreshAll(autoAttach: false)

        // 相同 projects/sessions/status 不应重复下发；这里只保留 loading true/false 两次真实状态变化。
        XCTAssertEqual(publishCount, 2)
        XCTAssertEqual(store.projects.map(\.id), [project.id])
        XCTAssertEqual(store.filteredSessions.map(\.id), [history.id])
    }

    func testSessionStoreProjectRefreshKeepsOtherProjectSessions() {
        let firstProject = makeProject(id: "proj_1")
        let secondProject = makeProject(id: "proj_2")
        let staleSession = makeSession(id: "codex_stale", projectID: firstProject.id, title: "旧缓存", status: "history", source: "codex", resumeID: "stale")
        let freshHistory = makeSession(id: "codex_fresh", projectID: firstProject.id, title: "刷新后的历史", status: "history", source: "codex", resumeID: "fresh")
        let otherProjectSession = makeSession(id: "codex_other", projectID: secondProject.id, title: "其他项目", status: "history", source: "codex", resumeID: "other")

        let sessions = SessionStore.replacingSessions([staleSession, otherProjectSession], with: [freshHistory], projectID: firstProject.id)

        XCTAssertEqual(sessions.map(\.id), [freshHistory.id, otherProjectSession.id])
    }

    func testAgentSessionDropsStalePendingApprovalOutsideWaitingStatus() {
        let approval = ApprovalSummary(id: "approval-stale", title: "运行 xcodebuild", kind: "command", count: 1)

        let running = AgentSession(
            id: "codex_running",
            projectID: "proj_1",
            project: "proj_1",
            dir: "/tmp/proj_1",
            title: "运行中",
            status: "running",
            source: "codex",
            resumeID: "running",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            pendingApproval: approval
        )
        XCTAssertNil(running.pendingApproval)

        let waiting = AgentSession(
            id: "codex_waiting",
            projectID: "proj_1",
            project: "proj_1",
            dir: "/tmp/proj_1",
            title: "等待审批",
            status: "waiting_for_approval",
            source: "codex",
            resumeID: "waiting",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            pendingApproval: approval
        )
        XCTAssertEqual(waiting.pendingApproval?.id, approval.id)
    }

    func testSessionStoreProjectExpansionCanCollapseAndReloadProjectSessions() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史", status: "history", source: "codex", resumeID: "history")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectSessions: [project.id: [history]]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.toggleProjectExpansion(project)
        XCTAssertTrue(store.isProjectExpanded(project.id))
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [history.id])

        await store.toggleProjectExpansion(project)
        XCTAssertFalse(store.isProjectExpanded(project.id))
    }

    func testSelectingSessionRevealsOwningProjectInSidebar() async {
        let firstProject = makeProject(id: "proj_1")
        let secondProject = makeProject(id: "proj_2")
        let secondSession = makeSession(id: "sess_second", projectID: secondProject.id, title: "第二项目会话", status: "closed", source: "codex")
        let client = MockSessionStoreClient(
            projects: [firstProject, secondProject],
            sessions: [],
            projectSessions: [
                firstProject.id: [],
                secondProject.id: [secondSession]
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        await store.toggleProjectExpansion(secondProject)
        await store.toggleProjectExpansion(secondProject)
        XCTAssertFalse(store.isProjectExpanded(secondProject.id))

        await store.selectSession(secondSession)

        XCTAssertEqual(store.selectedProjectID, secondProject.id)
        XCTAssertEqual(store.selectedSessionID, secondSession.id)
        XCTAssertTrue(store.isProjectExpanded(secondProject.id))
    }

    func testSessionStoreOnlyShowsFiveProjectSessionsByDefault() async {
        let project = makeProject(id: "proj_1")
        let sessions = (0..<7).map { index in
            makeSession(
                id: "codex_\(index)",
                projectID: project.id,
                title: "历史 \(index)",
                status: "history",
                source: "codex",
                resumeID: "history_\(index)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(10 - index))
            )
        }
        let client = MockSessionStoreClient(projects: [project], sessions: sessions)
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)

        XCTAssertEqual(store.visibleSessions(forProjectID: project.id).map(\.id), ["codex_0", "codex_1", "codex_2", "codex_3", "codex_4"])
        XCTAssertEqual(store.hiddenSessionCount(forProjectID: project.id), 2)
        var snapshot = store.sessionListSnapshot(forProjectID: project.id)
        XCTAssertFalse(snapshot.isShowingAll)
        XCTAssertEqual(snapshot.visibleSessions.map(\.id), ["codex_0", "codex_1", "codex_2", "codex_3", "codex_4"])
        XCTAssertEqual(snapshot.allSessionCount, 7)
        XCTAssertEqual(snapshot.hiddenCount, 2)
        XCTAssertTrue(snapshot.shouldShowActionRow)
        XCTAssertEqual(snapshot.actionTitle, L10n.text("ui.show_more"))

        await store.toggleSessionListExpansion(projectID: project.id)
        XCTAssertEqual(store.visibleSessions(forProjectID: project.id).count, 7)
        XCTAssertEqual(store.hiddenSessionCount(forProjectID: project.id), 0)
        snapshot = store.sessionListSnapshot(forProjectID: project.id)
        XCTAssertTrue(snapshot.isShowingAll)
        XCTAssertEqual(snapshot.visibleSessions.count, 7)
        XCTAssertTrue(snapshot.shouldShowActionRow)
        XCTAssertEqual(snapshot.actionTitle, L10n.text("ui.show_less"))

        await store.toggleSessionListExpansion(projectID: project.id)
        XCTAssertEqual(store.visibleSessions(forProjectID: project.id).map(\.id), ["codex_0", "codex_1", "codex_2", "codex_3", "codex_4"])
        snapshot = store.sessionListSnapshot(forProjectID: project.id)
        XCTAssertFalse(snapshot.isShowingAll)
        XCTAssertEqual(snapshot.visibleSessions.map(\.id), ["codex_0", "codex_1", "codex_2", "codex_3", "codex_4"])
    }

    func testCollapsedProjectPreviewNeverHidesActiveSessionBehindHistory() async {
        let project = makeProject(id: "proj_active_preview")
        let history = (0..<6).map { index in
            makeSession(
                id: "history_\(index)",
                projectID: project.id,
                title: "历史 \(index)",
                status: SessionStatus.history.rawValue,
                source: "codex",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
            )
        }
        let active = makeSession(
            id: "active_older",
            projectID: project.id,
            title: "较早开始但仍在执行",
            status: SessionStatus.running.rawValue,
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let client = MockSessionStoreClient(projects: [project], sessions: history + [active])
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)

        XCTAssertEqual(
            store.sessionListSnapshot(forProjectID: project.id).visibleSessions.map(\.id),
            [active.id, history[0].id, history[1].id, history[2].id, history[3].id]
        )
        XCTAssertEqual(store.hiddenSessionCount(forProjectID: project.id), 2)
    }

    func testSessionStoreExpandsProjectSessionsInSmallSteps() async {
        let project = makeProject(id: "proj_step_expand")
        let sessions = (0..<12).map { index in
            makeSession(
                id: "codex_step_\(index)",
                projectID: project.id,
                title: "历史 \(index)",
                status: "history",
                source: "codex",
                resumeID: "history_step_\(index)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
            )
        }
        let client = MockSessionStoreClient(projects: [project], sessions: sessions)
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        XCTAssertEqual(store.visibleSessions(forProjectID: project.id).count, SessionStore.sessionPreviewLimit)

        await store.toggleSessionListExpansion(projectID: project.id)
        var snapshot = store.sessionListSnapshot(forProjectID: project.id)
        XCTAssertEqual(snapshot.visibleSessions.count, SessionStore.sessionPreviewLimit + SessionStore.sessionExpansionStep)
        XCTAssertEqual(snapshot.hiddenCount, 2)
        XCTAssertEqual(snapshot.actionTitle, L10n.text("ui.show_more"))

        await store.toggleSessionListExpansion(projectID: project.id)
        snapshot = store.sessionListSnapshot(forProjectID: project.id)
        XCTAssertEqual(snapshot.visibleSessions.count, 12)
        XCTAssertEqual(snapshot.hiddenCount, 0)
        XCTAssertEqual(snapshot.actionTitle, L10n.text("ui.show_less"))
    }

    func testSessionStoreLoadsNextSessionPageWhenExpanded() async {
        let project = makeProject(id: "proj_1")
        let firstPage = (0..<3).map { index in
            makeSession(
                id: "codex_first_\(index)",
                projectID: project.id,
                title: "第一页 \(index)",
                status: "history",
                source: "codex",
                resumeID: "first_\(index)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(20 - index))
            )
        }
        let secondPage = (0..<2).map { index in
            makeSession(
                id: "codex_second_\(index)",
                projectID: project.id,
                title: "第二页 \(index)",
                status: "history",
                source: "codex",
                resumeID: "second_\(index)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(10 - index))
            )
        }
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectPages: [
                project.id: SessionsPage(sessions: firstPage, nextCursor: "cursor_1", hasMore: true)
            ],
            cursorPages: [
                "cursor_1": SessionsPage(sessions: secondPage, hasMore: false)
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        XCTAssertTrue(store.canLoadMoreSessions(projectID: project.id))
        XCTAssertEqual(store.visibleSessions(forProjectID: project.id).map(\.id), firstPage.map(\.id))
        var snapshot = store.sessionListSnapshot(forProjectID: project.id)
        XCTAssertFalse(snapshot.isShowingAll)
        XCTAssertTrue(snapshot.canLoadMore)
        XCTAssertTrue(snapshot.shouldShowActionRow)
        XCTAssertEqual(snapshot.actionTitle, L10n.text("ui.show_more"))

        await store.toggleSessionListExpansion(projectID: project.id)

        XCTAssertFalse(store.canLoadMoreSessions(projectID: project.id))
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), (firstPage + secondPage).map(\.id))
        XCTAssertEqual(store.visibleSessions(forProjectID: project.id).count, 5)
        snapshot = store.sessionListSnapshot(forProjectID: project.id)
        XCTAssertTrue(snapshot.isShowingAll)
        XCTAssertFalse(snapshot.canLoadMore)
        XCTAssertEqual(snapshot.allSessionCount, 5)
        XCTAssertEqual(snapshot.visibleSessions.count, 5)
        XCTAssertFalse(snapshot.shouldShowActionRow)
        XCTAssertEqual(snapshot.actionTitle, L10n.text("ui.show_less"))
    }

    func testSessionStoreKeepsNewestVisibleAfterLoadingOlderPageAndRefreshing() async {
        let project = makeProject(id: "proj_sidebar_paging")
        let firstPage = (0..<8).map { index in
            makeSession(
                id: "codex_latest_\(index)",
                projectID: project.id,
                title: "最近会话 \(index)",
                status: "history",
                source: "codex",
                resumeID: "latest_\(index)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
            )
        }
        let olderPage = [
            makeSession(
                id: "codex_older_0",
                projectID: project.id,
                title: "更早会话",
                status: "history",
                source: "codex",
                resumeID: "older_0",
                updatedAt: Date(timeIntervalSince1970: 90)
            )
        ]
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: firstPage, nextCursor: "cursor_older", hasMore: true),
            cursorPages: ["cursor_older": SessionsPage(sessions: olderPage, hasMore: false)]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.toggleSessionListExpansion(projectID: project.id)

        var snapshot = store.sessionListSnapshot(forProjectID: project.id)
        XCTAssertEqual(snapshot.visibleSessions.map(\.id), (firstPage + olderPage).map(\.id))
        XCTAssertEqual(snapshot.visibleSessions.first?.id, firstPage.first?.id)
        XCTAssertEqual(snapshot.visibleSessions.last?.id, olderPage.first?.id)

        // 后台首屏刷新只能更新最新页状态，不能把用户已展开加载出的旧页收回。
        await store.refreshSelectedProjectSessions(showLoading: false)

        snapshot = store.sessionListSnapshot(forProjectID: project.id)
        XCTAssertEqual(snapshot.visibleSessions.map(\.id), (firstPage + olderPage).map(\.id))
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), (firstPage + olderPage).map(\.id))
    }

    func testWorkspaceRefreshPreservesPagesLoadedOutsideSidebarExpansion() async throws {
        let project = makeProject(id: "proj_workspace_all_sessions")
        let firstPage = (0..<8).map { index in
            makeSession(
                id: "workspace_recent_\(index)",
                projectID: project.id,
                title: "最近会话 \(index)",
                status: "history",
                source: "codex",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
            )
        }
        let olderPage = [
            makeSession(
                id: "workspace_older_0",
                projectID: project.id,
                title: "更早会话",
                status: "history",
                source: "codex",
                updatedAt: Date(timeIntervalSince1970: 10)
            )
        ]
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: firstPage, nextCursor: "workspace_cursor", hasMore: true),
            cursorPages: ["workspace_cursor": SessionsPage(sessions: olderPage, hasMore: false)]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.loadMoreSessions(projectID: project.id)
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), (firstPage + olderPage).map(\.id))
        XCTAssertFalse(store.isShowingAllSessions(projectID: project.id), "工作区翻页不应改变侧栏 5 条预览状态")

        try await store.refreshWorkspaceSessions(projectID: project.id)

        XCTAssertEqual(
            store.sessions(forProjectID: project.id).map(\.id),
            (firstPage + olderPage).map(\.id),
            "工作区下拉刷新首屏后必须保留已经加载的旧页"
        )
    }

    func testWorkspaceManualRefreshUsesAuthoritativeSessionList() async throws {
        let project = makeProject(id: "proj_workspace_authoritative_refresh")
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: [])
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]

        try await store.refreshWorkspaceSessions(projectID: project.id)

        XCTAssertEqual(
            client.requestedSessionListConsistencies,
            [.authoritative],
            "用户主动刷新工作区时必须绕过可能滞后的 State DB 快速索引"
        )
    }

    func testSessionListSnapshotUpdatesWhenPaginationStateChangesWithoutSessionDiff() async {
        let project = makeProject(id: "proj_1")
        let firstPage = (0..<3).map { index in
            makeSession(
                id: "codex_first_\(index)",
                projectID: project.id,
                title: "第一页 \(index)",
                status: "history",
                source: "codex",
                resumeID: "first_\(index)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(20 - index))
            )
        }
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: firstPage, nextCursor: "cursor_1", hasMore: true)
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        var snapshot = store.sessionListSnapshot(forProjectID: project.id)
        XCTAssertTrue(snapshot.canLoadMore)
        XCTAssertTrue(snapshot.shouldShowActionRow)
        XCTAssertEqual(snapshot.actionTitle, L10n.text("ui.show_more"))

        client.page = SessionsPage(sessions: firstPage, hasMore: false)
        await store.refreshAll(autoAttach: false)

        snapshot = store.sessionListSnapshot(forProjectID: project.id)
        XCTAssertFalse(snapshot.canLoadMore)
        XCTAssertFalse(snapshot.shouldShowActionRow)
        XCTAssertEqual(snapshot.visibleSessions.map(\.id), firstPage.map(\.id))
    }

    func testSessionStoreDerivedSessionIndexesStaySortedAfterUpsert() async throws {
        let project = makeProject(id: "proj_1")
        let older = makeSession(
            id: "codex_older",
            projectID: project.id,
            title: "旧历史",
            status: "history",
            source: "codex",
            resumeID: "older",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = makeSession(
            id: "codex_newer",
            projectID: project.id,
            title: "新历史",
            status: "history",
            source: "codex",
            resumeID: "newer",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let created = makeSession(id: "sess_created", projectID: project.id, title: "刚创建", status: "closed", source: "codex")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectSessions: [project.id: [older, newer]],
            createSessionResponse: try makeCreateSessionResponse(session: created)
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        XCTAssertEqual(store.visibleSessions(forProjectID: project.id).map(\.id), [newer.id, older.id])

        // upsert 只发布一次 sessions，同时必须重建派生索引；否则侧栏会继续显示旧排序。
        await store.startNewSession(in: project)

        XCTAssertEqual(store.selectedSession?.id, created.id)
        XCTAssertEqual(store.visibleSessions(forProjectID: project.id).map(\.id), [created.id, newer.id, older.id])
        XCTAssertEqual(store.filteredSessions.map(\.id), [created.id, newer.id, older.id])
    }

    func testStartingEmptyInteractiveSessionDoesNotAutoLoadHistory() async throws {
        let project = makeProject(id: "proj_1")
        let created = makeSession(id: "sess_created_running", projectID: project.id, title: "刚创建", status: "running", source: "codex")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [created],
            createSessionResponse: try makeCreateSessionResponse(session: created),
            messagesError: AgentAPIError.server(status: 504, message: "thread/read timeout")
        )
        let conversationStore = ConversationStore()
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        await store.startNewSession(in: project)

        XCTAssertEqual(client.createPayloads.count, 1)
        XCTAssertTrue(client.requestedMessageSessionIDs.isEmpty)
        XCTAssertEqual(store.selectedSession?.id, created.id)
        XCTAssertNil(store.selectedHistorySavingsNotice)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(conversationStore.messages(for: created.id).map(\.content), [L10n.text("ui.an_interactive_session_has_been_started")])
        XCTAssertEqual(sockets.count, 1)

        // 回前台会再次 refreshAll；空 thread 已记录空快照后，不能在首个 turn 前读取不存在的 rollout。
        await store.refreshAll(autoAttach: true)
        XCTAssertTrue(client.requestedMessageSessionIDs.isEmpty)
        XCTAssertNil(store.selectedHistorySavingsNotice)
    }

    func testStartingEmptyInteractiveSessionPublishesOptimisticSessionBeforeBackendReturns() async throws {
        let project = makeProject(id: "proj_empty_optimistic")
        let created = makeSession(
            id: "sess_empty_optimistic",
            projectID: project.id,
            title: "新会话",
            status: "running",
            source: "codex"
        )
        let client = DelayedCreateSessionClient(projects: [project], sessions: [])
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        let createTask = Task { await store.startNewSession(in: project) }
        await client.waitForCreateRequestCount(1)

        // 空会话也必须先发布本地占位，让弹窗可以立即关闭并进入会话页；不能等 thread/start 返回。
        let optimisticSessionID = try XCTUnwrap(store.selectedSessionID)
        XCTAssertTrue(optimisticSessionID.hasPrefix("local:"))
        XCTAssertEqual(store.selectedSession?.title, L10n.text("ui.new_session"))
        XCTAssertEqual(store.selectedSession?.source, "local")
        XCTAssertEqual(client.modelOptionsCallCount, 0, "空会话没有 turn/start，不应先请求 model/list")

        client.resolveCreate(with: .success(try makeCreateSessionResponse(session: created)))
        await createTask.value

        XCTAssertEqual(store.selectedSessionID, created.id)
        XCTAssertFalse(store.sessions.contains { $0.id == optimisticSessionID })
    }

    // 回归：新建会话在创建瞬间就绑定 runtime。入口显式选择 Claude 时，createSession 请求必须
    // 携带 runtimeProvider=claude，否则空线程会落在默认 Codex 通道上且事后无法迁移。
    func testWorkspaceSessionRuntimeChoicesExposeClaudeProviderOnlyWhenAvailable() {
        XCTAssertEqual(
            WorkspaceSessionRuntimeChoice.available(claudeChannelAvailable: false),
            [.codex],
            "Claude 通道不可用时，工作区入口只能创建 Codex 会话"
        )
        XCTAssertEqual(
            WorkspaceSessionRuntimeChoice.available(claudeChannelAvailable: true),
            [.codex, .claude],
            "Claude 通道可用时，工作区入口必须显式暴露 Claude 会话动作"
        )
        XCTAssertNil(WorkspaceSessionRuntimeChoice.codex.runtimeProvider)
        XCTAssertEqual(WorkspaceSessionRuntimeChoice.claude.runtimeProvider, "claude")
        XCTAssertEqual(WorkspaceSessionRuntimeChoice.codex.brandAssetName, "ChatGPT")
        XCTAssertEqual(WorkspaceSessionRuntimeChoice.claude.brandAssetName, "Claude")
    }

    func testWorkspaceStripUsesViewportWidthToCenterSmallCardGroups() {
        XCTAssertEqual(WorkspaceStripLayout.minimumContentWidth(viewportWidth: 1_400), 1_352)
        XCTAssertEqual(WorkspaceStripLayout.minimumContentWidth(viewportWidth: 40), 0)
    }

    func testStartNewSessionWithClaudeRuntimeCarriesRuntimeProviderInCreatePayload() async throws {
        let project = makeProject(id: "proj_claude_entry")
        let created = makeSession(id: "claude_created", projectID: project.id, title: "Claude 会话", status: "closed", source: "claude")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            createSessionResponse: try makeCreateSessionResponse(session: created)
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.startNewSession(in: project, runtimeProvider: "claude")

        XCTAssertEqual(client.createPayloads.count, 1)
        let payload = try XCTUnwrap(client.createPayloads.first)
        XCTAssertEqual(
            CodexAppServerSessionRuntime.normalizedRuntimeProvider(payload.turnOptions.runtimeProvider),
            "claude",
            "显式 Claude 入口创建的空线程必须路由到 Claude runtime"
        )
        XCTAssertEqual(store.selectedSession?.id, created.id)

        // 默认入口保持 Codex 主线行为：不显式携带 claude runtimeProvider。
        await store.startNewSession(in: project)
        XCTAssertEqual(client.createPayloads.count, 2)
        let defaultPayload = try XCTUnwrap(client.createPayloads.last)
        XCTAssertNotEqual(
            CodexAppServerSessionRuntime.normalizedRuntimeProvider(defaultPayload.turnOptions.runtimeProvider),
            "claude",
            "默认新建会话不能被 Claude 修复改变通道"
        )
    }

    func testSessionStoreUsesIDTieBreakerForMatchingBackendCursorOrder() async {
        let project = makeProject(id: "proj_1")
        let sameUpdatedAt = Date(timeIntervalSince1970: 20)
        let sessions = [
            makeSession(id: "codex_alpha", projectID: project.id, title: "Z Title", status: "history", source: "codex", resumeID: "alpha", updatedAt: sameUpdatedAt),
            makeSession(id: "codex_beta", projectID: project.id, title: "A Title", status: "history", source: "codex", resumeID: "beta", updatedAt: sameUpdatedAt),
            makeSession(id: "codex_gamma", projectID: project.id, title: "M Title", status: "history", source: "codex", resumeID: "gamma", updatedAt: sameUpdatedAt)
        ]
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            projectSessions: [project.id: sessions]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)

        // Go 后端 cursor 按 updated_at desc + id desc；Swift 派生索引必须保持同序，
        // 否则分页合并后本地会按标题重排，出现侧栏跳动。
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), ["codex_gamma", "codex_beta", "codex_alpha"])
    }

    func testSessionStoreFreezesProjectOrderWhileSessionIsRunning() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(
            id: "codex_history",
            projectID: project.id,
            title: "历史",
            status: "history",
            source: "codex",
            resumeID: "history",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let running = makeSession(
            id: "sess_running",
            projectID: project.id,
            title: "运行中",
            status: "running",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let client = MutableSessionPageClient(projects: [project], page: SessionsPage(sessions: [history, running]))
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [history.id, running.id])

        client.page = SessionsPage(sessions: [
            history,
            makeSession(
                id: running.id,
                projectID: project.id,
                title: running.title,
                status: "running",
                source: running.source,
                updatedAt: Date(timeIntervalSince1970: 30)
            )
        ])
        await store.refreshSelectedProjectSessions()

        // running 输出刷新会更新 updatedAt；侧栏保持用户正在看的相对顺序，避免列表来回跳。
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [history.id, running.id])

        client.page = SessionsPage(sessions: [
            history,
            makeSession(
                id: running.id,
                projectID: project.id,
                title: running.title,
                status: "closed",
                source: running.source,
                updatedAt: Date(timeIntervalSince1970: 30)
            )
        ])
        await store.refreshSelectedProjectSessions()

        // 没有 running session 后释放冻结顺序，恢复 updatedAt 排序。
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [running.id, history.id])
    }

    func testWorkspaceRecentWindowKeepsKnownRunningSessionWhenFirstPageIsStale() async throws {
        let project = makeProject(id: "proj_workspace_running_window")
        let running = makeSession(
            id: "thread_running_outside_prefix",
            projectID: project.id,
            title: "旧会话重新运行",
            status: "running",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let history = (0..<6).map { index in
            makeSession(
                id: "thread_recent_history_\(index)",
                projectID: project.id,
                title: "最近历史 \(index)",
                status: "history",
                source: "codex",
                resumeID: "recent-history-\(index)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 + index))
            )
        }
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: history + [running])
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        XCTAssertFalse(store.sessions(forProjectID: project.id).prefix(5).contains { $0.id == running.id })
        XCTAssertTrue(
            SessionStore.lifecycleVisibleSessions(store.sessions(forProjectID: project.id), limit: 5)
                .contains { $0.id == running.id },
            "工作区最近窗口必须像会话侧栏一样优先保留运行态"
        )

        client.page = SessionsPage(sessions: history)
        try await store.refreshWorkspaceSessions(projectID: project.id)

        XCTAssertTrue(
            store.sessions(forProjectID: project.id).contains { $0.id == running.id },
            "索引短暂缺失不能删除本地已经确认的运行会话"
        )
    }

    func testMissingRunningSessionUsesAuthoritativeReadAfterTwoRefreshes() async throws {
        let project = makeProject(id: "proj_running_reconciliation")
        let running = makeSession(
            id: "thread_running_reconciliation",
            projectID: project.id,
            title: "错过完成事件",
            status: "running",
            source: "codex"
        )
        let completed = makeSession(
            id: running.id,
            projectID: project.id,
            title: running.title,
            status: "history",
            source: running.source,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            sessionResponses: [running.id: SessionResponse(session: completed)]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]
        store.replaceSessionsIfChanged(with: [running], projectID: project.id)

        try await store.refreshWorkspaceSessions(projectID: project.id)
        XCTAssertEqual(store.sessionsByID[running.id]?.status, "running")
        XCTAssertTrue(client.requestedSessionIDs.isEmpty, "首次缺失只做短暂保留，避免额外请求")

        try await store.refreshWorkspaceSessions(projectID: project.id)
        for _ in 0..<20 {
            guard store.sessionsByID[running.id]?.isRunning == true else { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(client.requestedSessionIDs, [running.id])
        XCTAssertEqual(store.sessionsByID[running.id]?.status, "history")
        XCTAssertFalse(store.sessions.contains(where: \.isRunning), "thread/read 终态必须释放排序冻结")
    }

    func testRunningSessionReappearingInFreshPageResetsMissingCounter() {
        let project = makeProject(id: "proj_running_reappears")
        let running = makeSession(
            id: "thread_running_reappears",
            projectID: project.id,
            title: "短暂漏出首屏",
            status: "running",
            source: "codex"
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: []) }
        )
        store.projects = [project]
        store.replaceSessionsIfChanged(with: [running], projectID: project.id)

        store.recordRunningSessionsMissingFromFreshPage(freshIDs: [], projectID: project.id)
        XCTAssertEqual(
            store.missingRunningSessionStateByID[running.id]?.consecutiveRefreshMisses,
            1
        )

        store.recordRunningSessionsMissingFromFreshPage(
            freshIDs: [running.id],
            projectID: project.id
        )
        XCTAssertNil(store.missingRunningSessionStateByID[running.id])

        store.recordRunningSessionsMissingFromFreshPage(freshIDs: [], projectID: project.id)
        XCTAssertEqual(
            store.missingRunningSessionStateByID[running.id]?.consecutiveRefreshMisses,
            1,
            "会话重新出现后，下一次缺失必须从首轮宽限重新计数"
        )
    }

    func testAuthoritativeRunningSessionReadRestartsMissingGracePeriod() async throws {
        let project = makeProject(id: "proj_running_authoritative")
        let running = makeSession(
            id: "thread_running_authoritative",
            projectID: project.id,
            title: "仍在其他客户端运行",
            status: "running",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [],
            sessionResponses: [running.id: SessionResponse(session: running)]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]
        store.replaceSessionsIfChanged(with: [running], projectID: project.id)

        try await store.refreshWorkspaceSessions(projectID: project.id)
        try await store.refreshWorkspaceSessions(projectID: project.id)
        for _ in 0..<20 {
            if client.requestedSessionIDs == [running.id],
               store.missingRunningSessionReconciliationTasksByID[running.id] == nil {
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(client.requestedSessionIDs, [running.id])
        XCTAssertTrue(store.sessionsByID[running.id]?.isRunning == true)
        XCTAssertNil(store.missingRunningSessionStateByID[running.id])

        try await store.refreshWorkspaceSessions(projectID: project.id)

        XCTAssertEqual(client.requestedSessionIDs, [running.id], "权威读取确认仍在运行后，不应下一轮立即重复读取")
        XCTAssertEqual(
            store.missingRunningSessionStateByID[running.id]?.consecutiveRefreshMisses,
            1
        )
    }

    func testUnverifiedMissingRunningSessionIsNotRetainedForever() async throws {
        let project = makeProject(id: "proj_running_reconciliation_failure")
        let running = makeSession(
            id: "thread_unverified_running",
            projectID: project.id,
            title: "无法校准的旧运行态",
            status: "running",
            source: "codex"
        )
        let client = MockSessionStoreClient(projects: [project], sessions: [])
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]
        store.replaceSessionsIfChanged(with: [running], projectID: project.id)

        for _ in 0..<SessionStore.maximumUnverifiedRunningSessionMisses {
            try await store.refreshWorkspaceSessions(projectID: project.id)
            for _ in 0..<20 {
                guard store.missingRunningSessionReconciliationTasksByID[running.id] != nil else { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        XCTAssertNotNil(store.sessionsByID[running.id], "宽限期内继续展示，等待 thread/read 校准")

        try await store.refreshWorkspaceSessions(projectID: project.id)

        XCTAssertNil(store.sessionsByID[running.id], "列表持续缺失且权威读取失败时不能永久保留幽灵运行态")
        XCTAssertEqual(client.requestedSessionIDs, [running.id, running.id])
    }

    func testLocalSendUpdatesSessionPreviewAfterRemoteMacPreview() async throws {
        let project = makeProject(id: "proj_projection_send")
        let remoteUpdatedAt = Date(timeIntervalSince1970: 20)
        let running = makeSession(
            id: "sess_projection_send",
            projectID: project.id,
            title: "混合端会话",
            status: "running",
            source: "codex",
            preview: "Mac 端刚回复的摘要",
            updatedAt: remoteUpdatedAt
        )
        let client = MutableSessionPageClient(projects: [project], page: SessionsPage(sessions: [running]))
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let didSend = await store.sendPrompt("iPad 继续下一步")
        XCTAssertTrue(didSend)

        XCTAssertEqual(store.selectedSession?.preview, "iPad 继续下一步")
        XCTAssertEqual(store.sessions(forProjectID: project.id).first?.preview, "iPad 继续下一步")
    }

    func testStaleRemoteSnapshotDoesNotOverwriteLocalProjection() async throws {
        let project = makeProject(id: "proj_projection_stale")
        let remoteUpdatedAt = Date(timeIntervalSince1970: 20)
        let running = makeSession(
            id: "sess_projection_stale",
            projectID: project.id,
            title: "混合端会话",
            status: "running",
            source: "codex",
            preview: "Mac 端旧摘要",
            updatedAt: remoteUpdatedAt
        )
        let client = MutableSessionPageClient(projects: [project], page: SessionsPage(sessions: [running]))
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        let didSend = await store.sendPrompt("iPad 新输入")
        XCTAssertTrue(didSend)

        client.page = SessionsPage(sessions: [
            makeSession(
                id: running.id,
                projectID: project.id,
                title: running.title,
                status: "running",
                source: running.source,
                preview: "Mac 端旧摘要",
                updatedAt: remoteUpdatedAt
            )
        ])
        await store.refreshSelectedProjectSessions()

        XCTAssertEqual(store.selectedSession?.preview, "iPad 新输入")
    }

    func testFreshRemoteSnapshotClearsLocalProjection() async throws {
        let project = makeProject(id: "proj_projection_fresh")
        let remoteUpdatedAt = Date(timeIntervalSince1970: 20)
        let running = makeSession(
            id: "sess_projection_fresh",
            projectID: project.id,
            title: "混合端会话",
            status: "running",
            source: "codex",
            preview: "Mac 端旧摘要",
            updatedAt: remoteUpdatedAt
        )
        let client = MutableSessionPageClient(projects: [project], page: SessionsPage(sessions: [running]))
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        let didSend = await store.sendPrompt("iPad 新输入")
        XCTAssertTrue(didSend)

        client.page = SessionsPage(sessions: [
            makeSession(
                id: running.id,
                projectID: project.id,
                title: running.title,
                status: "running",
                source: running.source,
                preview: "后端已经追上的摘要",
                updatedAt: Date(timeIntervalSince1970: 21)
            )
        ])
        await store.refreshSelectedProjectSessions()

        for _ in 0..<80 where store.selectedSession?.preview != "后端已经追上的摘要" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.selectedSession?.preview, "后端已经追上的摘要")
    }

    func testFailedSocketSendRevertsLocalProjection() async throws {
        let project = makeProject(id: "proj_projection_fail")
        let running = makeSession(
            id: "sess_projection_fail",
            projectID: project.id,
            title: "失败回滚",
            status: "running",
            source: "codex",
            preview: "远端摘要",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let client = MutableSessionPageClient(projects: [project], page: SessionsPage(sessions: [running]))
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                socket.sendTurnResult = false
                sockets.append(socket)
                return socket
            }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let didSend = await store.sendPrompt("会失败的新输入")
        XCTAssertTrue(didSend, "消息已安全保存到本机队列，即使即时传输未就绪")
        XCTAssertEqual(store.selectedSession?.preview, "远端摘要")
        XCTAssertEqual(store.selectedQueuedTurns.map(\.previewText), ["会失败的新输入"])
        XCTAssertEqual(store.selectedQueuedTurns.first?.dispatchState, .waiting)
    }

    func testAssistantFinalUpdatesSessionPreview() async throws {
        let project = makeProject(id: "proj_projection_assistant")
        let running = makeSession(
            id: "sess_projection_assistant",
            projectID: project.id,
            title: "助手摘要",
            status: "running",
            source: "codex",
            preview: "旧摘要"
        )
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: []) },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        sockets[0].emitEvent(.messageCompleted(
            AgentMessage(id: "assistant-final", sessionID: running.id, role: .assistant, content: "助手最终回复摘要", revision: 1),
            AgentEventMetadata(seq: 1, sessionID: running.id, turnID: "turn-1", itemID: "item-1", messageID: "assistant-final", clientMessageID: nil, revision: 1, createdAt: nil)
        ))
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(store.selectedSession?.preview, "助手最终回复摘要")
    }

    func testObservingRunningSessionBlocksSendTurn() async {
        let project = makeProject(id: "proj_observing")
        let running = makeSession(id: "sess_observing", projectID: project.id, title: "Mac 运行中", status: "running", source: "codex")
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: []) },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(running)

        XCTAssertTrue(store.isSelectedSessionObserving)
        let didSend = await store.sendPrompt("不应该发送")
        XCTAssertFalse(didSend)
        XCTAssertTrue(sockets.isEmpty)
        XCTAssertEqual(
            store.errorMessage,
            L10n.text("ui.this_session_is_running_on_another_client_please_c95578ac")
        )
    }

    func testTakenOverRunningSessionAllowsSendTurn() async throws {
        let project = makeProject(id: "proj_takeover")
        let running = makeSession(id: "sess_takeover", projectID: project.id, title: "接管运行中", status: "running", source: "codex")
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: []) },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)

        let didSend = await store.sendPrompt("接管后发送")
        XCTAssertTrue(didSend)
        XCTAssertEqual(sockets[0].sentTurns.map { $0.payload.previewText }, ["接管后发送"])
    }

    func testHistorySessionContinueMarksTakenOver() async throws {
        let project = makeProject(id: "proj_history_takeover")
        let history = makeSession(
            id: "sess_history_takeover",
            projectID: project.id,
            title: "历史",
            status: "history",
            source: "codex",
            resumeID: "sess_history_takeover"
        )
        let resumed = makeSession(
            id: history.id,
            projectID: project.id,
            title: history.title,
            status: "running",
            source: "codex",
            resumeID: history.id
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            createSessionResponse: try makeCreateSessionResponse(session: resumed)
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(history)

        let didSend = await store.sendPrompt("继续历史")
        XCTAssertTrue(didSend)
        XCTAssertEqual(store.controlState(for: resumed), .takenOver)
        XCTAssertTrue(store.canControlSession(store.selectedSession))
    }

    func testHistorySessionContinueSuppressesBufferedMessageReplayAfterHistoryLoad() async throws {
        let project = makeProject(id: "proj_history_resume_replay")
        let history = makeSession(
            id: "sess_history_resume_replay",
            projectID: project.id,
            title: "历史",
            status: "history",
            source: "codex",
            resumeID: "sess_history_resume_replay"
        )
        let resumed = makeSession(
            id: history.id,
            projectID: project.id,
            title: history.title,
            status: "running",
            source: "codex",
            resumeID: history.id
        )
        let historyMessages = [
            CodexHistoryMessage(
                id: "appserver:turn-resume:item-1",
                role: "system",
                kind: .reasoningSummary,
                content: "历史中已有的过程卡",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: "turn-resume",
                itemID: "item-1"
            )
        ]
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            createSessionResponse: try makeCreateSessionResponse(session: resumed),
            historyPages: [resumed.id: HistoryMessagesPage(messages: historyMessages)]
        )
        var sockets: [MockWebSocketClient] = []
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(history)

        let didSend = await store.sendPrompt("继续历史")

        XCTAssertTrue(didSend)
        XCTAssertEqual(client.requestedMessageSessionIDs, [resumed.id])
        // 选中历史会话时就建立事件订阅（sockets[0]），resume 成功后切到运行连接（sockets[1]）；
        // 两次连接都已有 canonical 历史快照，都不应要求完整回放。
        XCTAssertEqual(sockets.count, 2)
        XCTAssertEqual(sockets.map(\.replayBufferedEventsByConnect), [[false], [false]])
        XCTAssertTrue(conversationStore.hasLoadedHistory(sessionID: resumed.id))
        XCTAssertEqual(conversationStore.messages(for: resumed.id).filter { $0.kind == .reasoningSummary }.map(\.content), ["历史中已有的过程卡"])
    }

    func testRuntimeEventsDoNotBecomeSessionPreview() async throws {
        let project = makeProject(id: "proj_runtime_preview")
        let running = makeSession(
            id: "sess_runtime_preview",
            projectID: project.id,
            title: "运行日志",
            status: "running",
            source: "codex",
            preview: "用户可见摘要"
        )
        var sockets: [MockWebSocketClient] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [project], sessions: [running], messagesResult: []) },
            webSocketFactory: {
                let socket = MockWebSocketClient()
                sockets.append(socket)
                return socket
            }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)
        await store.selectSession(running)
        sockets[0].emitStatus(.connected)
        try await waitForWebSocketStatus(.connected, store: store)
        sockets[0].emitEvent(.logDelta(
            LogDelta(text: "tool output should stay in log", stream: "stdout"),
            AgentEventMetadata(seq: 1, sessionID: running.id, turnID: "turn-1", itemID: "cmd-1", messageID: nil, clientMessageID: nil, revision: 1, createdAt: nil)
        ))
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(store.selectedSession?.preview, "用户可见摘要")
    }

    func testUTCBoundaryDisplaysUsingLocalDate() throws {
        let message = try AgentAPIClient.decoder.decode(
            CodexHistoryMessage.self,
            from: Data("""
            {
              "id": "utc-boundary",
              "role": "user",
              "content": "跨 UTC 午夜",
              "created_at": "2026-06-28T16:02:16Z"
            }
            """.utf8)
        )
        let createdAt = try XCTUnwrap(message.createdAt)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        XCTAssertEqual(formatter.string(from: createdAt), "2026-06-29 00:02:16")
    }

    func testSessionStoreIndexedUpsertReplacesExistingSessionWithoutDuplicate() async throws {
        let project = makeProject(id: "proj_1")
        let running = makeSession(
            id: "sess_running",
            projectID: project.id,
            title: "运行中",
            status: "running",
            source: "codex"
        )
        let closed = makeSession(
            id: running.id,
            projectID: project.id,
            title: running.title,
            status: "closed",
            source: running.source,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [running],
            sessionResponses: [
                running.id: try makeSessionResponse(session: closed, recentOutput: nil)
            ]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        await store.selectSession(running)
        await store.refreshCurrentContext()
        try await Task.sleep(nanoseconds: 50_000_000)

        // session 高频状态更新走 ID->index 投影替换，不能退化成重复追加。
        XCTAssertEqual(store.sessions.filter { $0.id == running.id }.count, 1)
        XCTAssertEqual(store.selectedSession?.status, "closed")
    }

    func testRefreshCurrentContextReloadsSelectedHistoryMessages() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史", status: "history", source: "codex", resumeID: "history")
        let client = MockSessionStoreClient(projects: [project], sessions: [history])
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        await store.selectSession(history)
        await store.refreshCurrentContext()

        XCTAssertEqual(client.requestedMessageSessionIDs, [history.id, history.id])
        XCTAssertFalse(store.isRefreshingSelectedSession)
        XCTAssertTrue(conversationStore.messages(for: history.id).contains { $0.content == "历史回答" })
    }

    func testRefreshCurrentContextReusesRecentSessionListWithoutWaiting() async throws {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史", status: "history", source: "codex", resumeID: "history")
        let client = BlockingSessionListRefreshClient(projects: [project], page: SessionsPage(sessions: [history]))
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)
        await store.selectSession(history)

        var refreshFinished = false
        let refreshTask = Task { @MainActor in
            await store.refreshCurrentContext()
            refreshFinished = true
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        let finishedBeforeListRelease = refreshFinished
        await refreshTask.value

        XCTAssertTrue(finishedBeforeListRelease)
        XCTAssertEqual(client.sessionsPageCallCount, 1, "刚完成 refreshAll 时，历史刷新校准应复用首屏短缓存")
        XCTAssertEqual(client.requestedMessageCursors, [nil, nil])
    }

    func testCompletionReconciliationBypassesRecentSessionListCache() async {
        let project = makeProject(id: "proj_reconciliation_cache")
        let history = makeSession(
            id: "thread_reconciliation_cache",
            projectID: project.id,
            title: "待对账",
            status: "history",
            source: "codex"
        )
        let client = BlockingSessionListRefreshClient(
            projects: [project],
            page: SessionsPage(sessions: [history])
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.selectedProjectID = project.id
        await store.refreshAll(autoAttach: false)

        let reconciliation = Task { @MainActor in
            await store.refreshSessions(
                forProjectID: project.id,
                showLoading: false,
                clearErrorOnSuccess: false,
                updateStatusMessage: false,
                reportErrorOnFailure: false,
                reuseRecent: false
            )
        }
        await client.waitForBlockedSessionListRefresh()

        XCTAssertEqual(client.sessionsPageCallCount, 2, "完成后的对账不能复用完成前的两秒短缓存")
        client.releaseBlockedSessionListRefresh()
        await reconciliation.value
    }

    func testBackgroundReconciliationDoesNotChangeSelectedProject() async {
        let firstProject = makeProject(id: "proj_background_first")
        let selectedProject = makeProject(id: "proj_background_selected")
        let refreshed = makeSession(
            id: "thread_background_refresh",
            projectID: firstProject.id,
            title: "后台刷新",
            status: "history",
            source: "codex"
        )
        let client = MockSessionStoreClient(
            projects: [firstProject, selectedProject],
            sessions: [],
            projectSessions: [firstProject.id: [refreshed]]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [firstProject, selectedProject]
        store.recentWorkspaces = [AgentWorkspace(project: firstProject), AgentWorkspace(project: selectedProject)]
        store.sidebarProjects = [firstProject, selectedProject]
        store.selectedProjectID = selectedProject.id

        await store.refreshSessions(
            forProjectID: firstProject.id,
            showLoading: false,
            clearErrorOnSuccess: false,
            updateStatusMessage: false,
            reportErrorOnFailure: false,
            reuseRecent: false,
            activatesProject: false
        )

        XCTAssertEqual(store.selectedProjectID, selectedProject.id)
        XCTAssertEqual(store.sessions(forProjectID: firstProject.id).map(\.id), [refreshed.id])
    }

    func testSelectingHistoryWhileInitialPageLoadingDoesNotDuplicateRequest() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史", status: "history", source: "codex", resumeID: "history")
        let client = OrderedHistoryPageClient(projects: [project], page: SessionsPage(sessions: [history]))
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        let firstSelectTask = Task { await store.selectSession(history) }
        await client.waitForHistoryRequestCount(1)

        store.returnToSessionList()
        let secondSelectTask = Task { await store.selectSession(history) }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(client.requestedMessageCursors, [nil])
        XCTAssertEqual(client.requestedMessageLimits, [20])
        XCTAssertEqual(client.requestedMessageLoadModes, [.full])
        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .loadingFull)

        client.resolveHistoryRequest(
            at: 0,
            with: HistoryMessagesPage(
                messages: [
                    CodexHistoryMessage(id: "rollout:100", role: "assistant", content: "首屏历史", createdAt: Date(timeIntervalSince1970: 10))
                ]
            )
        )
        await firstSelectTask.value
        await secondSelectTask.value

        XCTAssertEqual(conversationStore.messages(for: history.id).map(\.content), ["首屏历史"])
        XCTAssertNil(store.selectedHistorySavingsNotice)
    }

    func testConcurrentRunningHistoryFirstPageLoadsCoalesceRequest() async {
        let project = makeProject(id: "proj_1")
        let running = makeSession(id: "codex_running", projectID: project.id, title: "运行中", status: "running", source: "codex")
        let client = OrderedHistoryPageClient(projects: [project], page: SessionsPage(sessions: [running]))
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { MockWebSocketClient() }
        )

        await store.refreshAll(autoAttach: false)
        store.takeOverSession(running)

        let firstSelectTask = Task { await store.selectSession(running) }
        await client.waitForHistoryRequestCount(1)
        let secondSelectTask = Task { await store.selectSession(running) }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(client.requestedMessageCursors, [nil])
        XCTAssertEqual(client.requestedMessageLimits, [20])
        XCTAssertEqual(client.requestedMessageLoadModes, [.full])
        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .loadingFull)

        client.resolveHistoryRequest(
            at: 0,
            with: HistoryMessagesPage(
                messages: [
                    CodexHistoryMessage(id: "rollout:101", role: "assistant", content: "合并首屏历史", createdAt: Date(timeIntervalSince1970: 10))
                ]
            )
        )
        await firstSelectTask.value
        await secondSelectTask.value

        XCTAssertEqual(client.requestedMessageCursors, [nil])
        XCTAssertEqual(conversationStore.messages(for: running.id).map(\.content), ["合并首屏历史"])
        XCTAssertNil(store.selectedHistorySavingsNotice)
    }

    func testQuietHistoryRefreshFailureKeepsCachedMessagesWithoutShowingFailureBanner() async throws {
        let project = makeProject(id: "proj_quiet_history")
        let history = makeSession(
            id: "codex_quiet_history",
            projectID: project.id,
            title: "安静刷新",
            status: "history",
            source: "codex",
            resumeID: "quiet-history",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let client = OrderedHistoryPageClient(projects: [project], page: SessionsPage(sessions: [history]))
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { MockWebSocketClient() }
        )

        await store.refreshAll(autoAttach: false)
        let firstSelectTask = Task { await store.selectSession(history) }
        await client.waitForHistoryRequestCount(1)
        client.resolveHistoryRequest(
            at: 0,
            with: HistoryMessagesPage(messages: [
                CodexHistoryMessage(id: "rollout:cached", role: "assistant", content: "已缓存历史", createdAt: Date(timeIntervalSince1970: 10))
            ])
        )
        await firstSelectTask.value

        store.returnToSessionList()
        // 测试进程可能继承 Debug Simulator 的连接错误；先清掉基线，只验证 quiet 请求不制造新错误。
        store.dismissErrorMessage()
        let updated = makeSession(
            id: history.id,
            projectID: project.id,
            title: history.title,
            status: "history",
            source: "codex",
            resumeID: history.resumeID,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        await store.selectSession(updated)
        await client.waitForHistoryRequestCount(2)

        // 后台补拉不能把“正在加载完整历史”或失败横幅盖到已有会话上。
        XCTAssertNil(store.selectedHistorySavingsNotice)
        client.failHistoryRequest(at: 1, with: MockError.timeout)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertNil(store.selectedHistorySavingsNotice)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(conversationStore.messages(for: history.id).map(\.content), ["已缓存历史"])
    }

    func testManualRefreshJoiningQuietHistoryFailureStillReportsForegroundError() async throws {
        let project = makeProject(id: "proj_quiet_joined_by_manual")
        let history = makeSession(
            id: "codex_quiet_joined_by_manual",
            projectID: project.id,
            title: "前台加入静默刷新",
            status: "history",
            source: "codex",
            resumeID: "quiet-joined-by-manual",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let client = OrderedHistoryPageClient(projects: [project], page: SessionsPage(sessions: [history]))
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { MockWebSocketClient() }
        )

        await store.refreshAll(autoAttach: false)
        let firstSelectTask = Task { await store.selectSession(history) }
        await client.waitForHistoryRequestCount(1)
        client.resolveHistoryRequest(
            at: 0,
            with: HistoryMessagesPage(messages: [
                CodexHistoryMessage(id: "rollout:manual-join-cached", role: "assistant", content: "已缓存历史", createdAt: Date(timeIntervalSince1970: 10))
            ])
        )
        await firstSelectTask.value

        store.returnToSessionList()
        let updated = makeSession(
            id: history.id,
            projectID: project.id,
            title: history.title,
            status: "history",
            source: "codex",
            resumeID: history.resumeID,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        await store.selectSession(updated)
        await client.waitForHistoryRequestCount(2)

        let manualRefreshTask = Task { await store.refreshCurrentContext() }
        for _ in 0..<100 {
            if store.isRefreshingSelectedSession {
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(store.isRefreshingSelectedSession)

        // 手动刷新应加入已有 quiet job，不增加请求；但共享 job 必须升级为前台反馈。
        XCTAssertEqual(client.requestedMessageLoadModes, [.full, .full])
        client.failHistoryRequest(at: 1, with: MockError.timeout)
        await manualRefreshTask.value

        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .fullFailed)
        XCTAssertTrue(store.statusMessage?.contains("完整历史加载失败") == true)
        XCTAssertFalse(store.isRefreshingSelectedSession)
        XCTAssertEqual(conversationStore.messages(for: history.id).map(\.content), ["已缓存历史"])
    }

    func testSummaryHistoryIsOnlyLoadedAfterUserChoosesIt() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_large", projectID: project.id, title: "大历史", status: "history", source: "codex", resumeID: "large")
        let client = OrderedHistoryPageClient(projects: [project], page: SessionsPage(sessions: [history]))
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        let fullTask = Task { await store.selectSession(history) }
        await client.waitForHistoryRequestCount(1)

        XCTAssertEqual(client.requestedMessageLoadModes, [.full])
        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .loadingFull)

        let firstSummaryTask = Task { await store.loadSummaryHistoryForSelectedSession() }
        await client.waitForHistoryRequestCount(2)
        let secondSummaryTask = Task { await store.loadSummaryHistoryForSelectedSession() }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(client.requestedMessageLoadModes, [.full, .economy])
        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .loadingSummary)

        client.resolveHistoryRequest(
            at: 1,
            with: HistoryMessagesPage(
                messages: [
                    CodexHistoryMessage(id: "rollout:summary", role: "assistant", content: "缩略历史", createdAt: Date(timeIntervalSince1970: 20))
                ],
                loadMode: .economy,
                notice: "当前显示缩略历史。"
            )
        )
        await firstSummaryTask.value
        await secondSummaryTask.value

        XCTAssertEqual(conversationStore.messages(for: history.id).map(\.content), ["缩略历史"])
        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .summaryLoaded)

        client.resolveHistoryRequest(
            at: 0,
            with: HistoryMessagesPage(
                messages: [
                    CodexHistoryMessage(id: "rollout:full", role: "assistant", content: "迟到完整历史", createdAt: Date(timeIntervalSince1970: 10))
                ]
            )
        )
        await fullTask.value

        XCTAssertEqual(conversationStore.messages(for: history.id).map(\.content), ["缩略历史"])

        let reloadFullTask = Task { await store.loadFullHistoryForSelectedSession() }
        await client.waitForHistoryRequestCount(3)
        XCTAssertEqual(client.requestedMessageLoadModes, [.full, .economy, .full])
        client.resolveHistoryRequest(
            at: 2,
            with: HistoryMessagesPage(
                messages: [
                    CodexHistoryMessage(id: "rollout:full-current", role: "assistant", content: "完整历史", createdAt: Date(timeIntervalSince1970: 30))
                ]
            )
        )
        await reloadFullTask.value

        XCTAssertEqual(conversationStore.messages(for: history.id).map(\.content), ["完整历史"])
        XCTAssertNil(store.selectedHistorySavingsNotice)
    }

    func testFullHistoryPolicyFailureAutomaticallyLoadsSummaryHistory() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_auto_summary", projectID: project.id, title: "大历史自动降级", status: "history", source: "codex", resumeID: "large")
        let client = OrderedHistoryPageClient(projects: [project], page: SessionsPage(sessions: [history]))
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        let selectTask = Task { await store.selectSession(history) }
        await client.waitForHistoryRequestCount(1)

        XCTAssertEqual(client.requestedMessageLimits, [20])
        XCTAssertEqual(client.requestedMessageLoadModes, [.full])
        client.failHistoryRequest(at: 0, with: historyPolicyError(reason: "history_response_too_large"))

        await client.waitForHistoryRequestCount(2)
        XCTAssertEqual(client.requestedMessageLimits, [20, 60])
        XCTAssertEqual(client.requestedMessageLoadModes, [.full, .economy])
        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .loadingSummary)

        client.resolveHistoryRequest(
            at: 1,
            with: HistoryMessagesPage(
                messages: [
                    CodexHistoryMessage(id: "rollout:auto-summary", role: "assistant", content: "自动缩略历史", createdAt: Date(timeIntervalSince1970: 20))
                ],
                loadMode: .economy,
                notice: "当前显示缩略历史。"
            )
        )
        await selectTask.value

        XCTAssertEqual(conversationStore.messages(for: history.id).map(\.content), ["自动缩略历史"])
        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .summaryLoaded)
    }

    func testSummaryHistoryPolicyFailureRetriesOnceAfterRetryAfter() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_summary_retry", projectID: project.id, title: "缩略重试", status: "history", source: "codex", resumeID: "summary-retry")
        let client = OrderedHistoryPageClient(projects: [project], page: SessionsPage(sessions: [history]))
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        let selectTask = Task { await store.selectSession(history) }
        await client.waitForHistoryRequestCount(1)

        client.failHistoryRequest(at: 0, with: historyPolicyError(reason: "history_response_too_large"))
        await client.waitForHistoryRequestCount(2)

        client.failHistoryRequest(at: 1, with: historyPolicyError(reason: "history_budget_limited", retryAfterMs: 1))
        await client.waitForHistoryRequestCount(3)

        XCTAssertEqual(client.requestedMessageLoadModes, [.full, .economy, .economy])
        XCTAssertEqual(client.requestedMessageLimits, [20, 60, 60])
        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .loadingSummary)

        client.resolveHistoryRequest(
            at: 2,
            with: HistoryMessagesPage(
                messages: [
                    CodexHistoryMessage(id: "rollout:summary-retry", role: "assistant", content: "重试后的缩略历史", createdAt: Date(timeIntervalSince1970: 30))
                ],
                loadMode: .economy,
                notice: "当前显示缩略历史。"
            )
        )
        await selectTask.value

        XCTAssertEqual(conversationStore.messages(for: history.id).map(\.content), ["重试后的缩略历史"])
        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .summaryLoaded)
    }

    func testSummaryHistoryTerminalFailureShowsFailedNotice() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_summary_dead", projectID: project.id, title: "缩略失败", status: "history", source: "codex", resumeID: "summary-dead")
        let client = OrderedHistoryPageClient(projects: [project], page: SessionsPage(sessions: [history]))
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        let selectTask = Task { await store.selectSession(history) }
        await client.waitForHistoryRequestCount(1)

        client.failHistoryRequest(at: 0, with: historyPolicyError(reason: "history_response_too_large"))
        await client.waitForHistoryRequestCount(2)

        client.failHistoryRequest(at: 1, with: historyPolicyError(reason: "history_budget_limited", retryAfterMs: 1))
        await client.waitForHistoryRequestCount(3)

        // 重试额度用尽后再次失败：横幅必须离开“正在加载”，进入可重试的失败态。
        client.failHistoryRequest(at: 2, with: historyPolicyError(reason: "history_budget_limited", retryAfterMs: 1))
        await selectTask.value

        XCTAssertEqual(client.requestedMessageLoadModes, [.full, .economy, .economy])
        XCTAssertEqual(store.selectedHistorySavingsNotice?.kind, .summaryFailed)
        XCTAssertNotNil(store.errorMessage)
    }

    func testLoadEarlierHistoryMergesOlderMessagePage() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史", status: "history", source: "codex", resumeID: "history")
        let newer = [
            CodexHistoryMessage(id: "rollout:200", role: "user", content: "较新的问题", createdAt: Date(timeIntervalSince1970: 20)),
            CodexHistoryMessage(id: "rollout:300", role: "assistant", content: "较新的回答", createdAt: Date(timeIntervalSince1970: 30))
        ]
        let older = [
            CodexHistoryMessage(id: "rollout:10", role: "user", content: "更早的问题", createdAt: Date(timeIntervalSince1970: 10))
        ]
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            historyPages: [
                history.id: HistoryMessagesPage(messages: newer, previousCursor: "older_cursor", hasMoreBefore: true)
            ],
            historyCursorPages: [
                "older_cursor": HistoryMessagesPage(messages: older, hasMoreBefore: false)
            ]
        )
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        await store.selectSession(history)

        XCTAssertTrue(store.canLoadEarlierHistory(sessionID: history.id))
        XCTAssertEqual(conversationStore.messages(for: history.id).map(\.content), ["较新的问题", "较新的回答"])

        await store.loadEarlierHistoryForSelectedSession()

        XCTAssertFalse(store.canLoadEarlierHistory(sessionID: history.id))
        XCTAssertEqual(client.requestedMessageCursors, [nil, "older_cursor"])
        XCTAssertEqual(conversationStore.messages(for: history.id).map(\.content), ["更早的问题", "较新的问题", "较新的回答"])
    }

    func testSessionStoreIngestsHistoryPageContextOnInitialLoadEarlierAndRefresh() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_context_history", projectID: project.id, title: "历史 context", status: "history", source: "codex", resumeID: "history")
        let initialContext = SessionContextSnapshot(
            sessionID: history.id,
            threadID: "thr_context_history",
            status: SessionContextStatus(type: "notLoaded"),
            tasks: [SessionContextTask(id: "cmd_initial", kind: "command", title: "go test ./...", subtitle: project.path, status: "completed")],
            sources: [SessionContextSource(id: "session_source", kind: "session", label: "vscode")]
        )
        let earlierContext = SessionContextSnapshot(
            sessionID: history.id,
            tasks: [SessionContextTask(id: "sub_earlier", kind: "subagent", title: "Zeno", subtitle: "review", status: "completed")],
            subagents: [SessionContextSubagent(id: "thr_child", parentThreadID: "thr_context_history", nickname: "Zeno", role: "review", status: "completed")]
        )
        let refreshContext = SessionContextSnapshot(
            sessionID: history.id,
            status: SessionContextStatus(type: "active"),
            tasks: [SessionContextTask(id: "web_refresh", kind: "web_search", title: "网络搜索：SwiftUI", status: "completed")]
        )
        let newer = [
            CodexHistoryMessage(id: "rollout:200", role: "assistant", content: "较新的回答", createdAt: Date(timeIntervalSince1970: 20))
        ]
        let older = [
            CodexHistoryMessage(id: "rollout:10", role: "user", content: "更早的问题", createdAt: Date(timeIntervalSince1970: 10))
        ]
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: [history]),
            historyPages: [
                history.id: HistoryMessagesPage(
                    messages: newer,
                    previousCursor: "older_cursor",
                    hasMoreBefore: true,
                    context: initialContext
                )
            ],
            historyCursorPages: [
                "older_cursor": HistoryMessagesPage(messages: older, hasMoreBefore: false, context: earlierContext)
            ]
        )
        let contextStore = SessionContextStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            contextStore: contextStore,
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        await store.selectSession(history)
        XCTAssertEqual(contextStore.context(for: history.id)?.tasks.map(\.id), ["cmd_initial"])
        XCTAssertEqual(contextStore.context(for: history.id)?.sources.first?.label, "vscode")

        await store.loadEarlierHistoryForSelectedSession()
        let taskIDsAfterEarlier = contextStore.context(for: history.id)?.tasks.map(\.id) ?? []
        XCTAssertEqual(Array(taskIDsAfterEarlier.prefix(2)), ["sub_earlier", "cmd_initial"])
        XCTAssertEqual(contextStore.context(for: history.id)?.subagents.first?.displayName, "Zeno")

        client.historyPages[history.id] = HistoryMessagesPage(messages: newer, hasMoreBefore: false, context: refreshContext)
        await store.refreshCurrentContext()

        let refreshed = contextStore.context(for: history.id)
        XCTAssertTrue(refreshed?.tasks.contains { $0.id == "web_refresh" && $0.kind == "web_search" } == true)
    }

}
