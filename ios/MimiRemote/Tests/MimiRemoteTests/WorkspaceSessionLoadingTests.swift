import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testWorkspaceSessionLoadInvocationTokensKeepOnlyLatestABAReturnEligible() {
        var tokens = WorkspaceSessionLoadInvocationTokens()
        let firstA = tokens.begin(for: "workspace-a")
        let firstB = tokens.begin(for: "workspace-b")
        let latestA = tokens.begin(for: "workspace-a")

        XCTAssertFalse(
            tokens.isCurrent(firstA, for: "workspace-a"),
            "A → B → A 后，旧 A waiter 的取消或失败不能再回写"
        )
        XCTAssertTrue(tokens.isCurrent(firstB, for: "workspace-b"), "其他工作区的 invocation 必须彼此隔离")
        XCTAssertTrue(tokens.isCurrent(latestA, for: "workspace-a"))

        tokens.remove(for: "workspace-a")
        XCTAssertFalse(tokens.isCurrent(latestA, for: "workspace-a"))
        XCTAssertTrue(tokens.isCurrent(firstB, for: "workspace-b"))
    }

    func testCancelledWorkspaceSessionWaiterRejoinsSingleFlightAndAppliesResult() async throws {
        let project = makeProject(id: "proj_workspace_cancelled_waiter")
        let session = makeSession(
            id: "thread_workspace_cancelled_waiter",
            projectID: project.id,
            title: "切回后可见",
            status: "history",
            source: "codex"
        )
        let client = BlockingSessionListRefreshClient(
            projects: [project],
            page: SessionsPage(sessions: [session]),
            blockOnCall: 1
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]

        let firstA = Task { @MainActor in
            try await store.refreshWorkspaceSessions(projectID: project.id)
        }
        await client.waitForBlockedSessionListRefresh()
        firstA.cancel()

        let latestA = Task { @MainActor in
            try await store.refreshWorkspaceSessions(projectID: project.id)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(
            client.sessionsPageCallCount,
            1,
            "取消旧 waiter 后重新加入同一工作区，仍只能产生一次底层 thread/list"
        )

        client.releaseBlockedSessionListRefresh()
        _ = await firstA.result
        try await latestA.value

        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [session.id])
    }

    func testMultiRuntimeWorkspaceSessionListPropagatesClaudeFailureAfterCodexSuccess() async throws {
        let project = AgentProject(id: "proj_multi_list_failure", name: "Multi List", path: "/tmp/multi-list")
        let workspace = AgentWorkspace(project: project)
        let config = makeDirectAppServerConfig(project: project, channels: [makeClaudeChannelMetadata()])
        let codexTransport = FakeCodexAppServerTransport()
        let claudeTransport = FakeCodexAppServerTransport()
        let client = MultiRuntimeSessionAPIClient(
            codexRuntime: CodexAppServerSessionRuntime(
                endpoint: "http://127.0.0.1:8787",
                token: "outer-token",
                runtimeProvider: "codex",
                transportFactory: { codexTransport },
                configProvider: { config }
            ),
            claudeRuntime: CodexAppServerSessionRuntime(
                endpoint: "http://127.0.0.1:8787",
                token: "outer-token",
                runtimeProvider: "claude",
                transportFactory: { claudeTransport },
                configProvider: { config }
            )
        )

        let listTask = Task {
            try await client.sessionsPage(
                workspace: workspace,
                cursor: nil,
                limit: 20,
                consistency: .authoritative
            )
        }
        let codexInitialize = try await waitForFakeAppServerRequest(codexTransport, method: "initialize")
        transportResponse(codexTransport, id: codexInitialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let codexList = try await waitForFakeAppServerRequest(codexTransport, method: "thread/list", after: 1)
        transportResponse(
            codexTransport,
            id: codexList.id,
            result: appServerThreadListResult([
                appServerThreadJSON(
                    id: "codex-visible-before-claude-failure",
                    cwd: project.path,
                    source: "appServer",
                    updatedAt: 1_780_493_000
                )
            ], nextCursor: nil)
        )

        let claudeInitialize = try await waitForFakeAppServerRequest(claudeTransport, method: "initialize")
        transportResponse(claudeTransport, id: claudeInitialize.id, result: #"{"userAgent":"fake-claude","platformFamily":"macos"}"#)
        let claudeList = try await waitForFakeAppServerRequest(claudeTransport, method: "thread/list", after: 1)
        transportErrorResponse(
            claudeTransport,
            id: claudeList.id,
            code: -32000,
            message: "Claude workspace list failed"
        )

        do {
            _ = try await listTask.value
            XCTFail("Claude 列表失败必须向 WorkspaceRootView 抛出，才能显示 failed 状态和重试入口")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Claude workspace list failed"))
        }
    }
}
