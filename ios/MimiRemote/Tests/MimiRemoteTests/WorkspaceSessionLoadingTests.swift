import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testWorkspaceCatalogCoordinatorRollsCurrentCancellationBackWithoutLeavingLoading() {
        var coordinator = WorkspaceCatalogLoadCoordinator()

        let emptyInvocation = coordinator.begin()
        XCTAssertEqual(coordinator.state, .loading)
        XCTAssertTrue(coordinator.complete(emptyInvocation, result: .cancelled, hasCachedProjects: false))
        XCTAssertEqual(coordinator.state, .idle)

        let cachedInvocation = coordinator.begin()
        XCTAssertTrue(coordinator.complete(cachedInvocation, result: .cancelled, hasCachedProjects: true))
        XCTAssertEqual(coordinator.state, .loaded)
    }

    func testWorkspaceCatalogCoordinatorRejectsOldFailureAndCancellationAfterNewInvocation() {
        var coordinator = WorkspaceCatalogLoadCoordinator()
        let first = coordinator.begin()
        let latest = coordinator.begin()

        XCTAssertFalse(coordinator.complete(first, result: .cancelled, hasCachedProjects: false))
        XCTAssertEqual(coordinator.state, .loading, "旧取消不能替最新 invocation 回退状态")
        XCTAssertTrue(coordinator.complete(latest, result: .loaded, hasCachedProjects: true))
        XCTAssertFalse(coordinator.complete(first, result: .failed("旧请求失败"), hasCachedProjects: false))
        XCTAssertEqual(coordinator.state, .loaded, "旧失败不能覆盖最新成功")
    }

    func testWorkspaceCatalogRefreshScopeTracksCredentialSuspensionWithoutChangingHost() {
        let hostScope = AppStore().activeHostScope

        XCTAssertNotEqual(
            WorkspaceCatalogRefreshScope(hostScope: hostScope, credentialsSuspended: false),
            WorkspaceCatalogRefreshScope(hostScope: hostScope, credentialsSuspended: true)
        )
    }

    func testCancelledWorkspaceCatalogRequestCannotCommitLateProjects() async {
        let staleProject = makeProject(id: "stale-catalog-project")
        let gate = WorkspaceProjectsGate()
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            projectsHandler: { await gate.projects() }
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        let refresh = Task { @MainActor in
            try await store.refreshWorkspaceCatalog()
        }
        await gate.waitUntilStarted()
        refresh.cancel()
        await gate.succeed(with: [staleProject])

        do {
            try await refresh.value
            XCTFail("已取消的 catalog 调用应拒绝提交")
        } catch {
            XCTAssertTrue(isCancellationError(error))
        }
        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertTrue(store.sidebarProjects.isEmpty)
    }

    func testWorkspaceCancellationClassifierDoesNotHideRealNetworkFailures() {
        XCTAssertTrue(isCancellationError(CancellationError()))
        XCTAssertTrue(isCancellationError(URLError(.cancelled)))
        XCTAssertFalse(isCancellationError(URLError(.timedOut)))
        XCTAssertFalse(isCancellationError(URLError(.notConnectedToInternet)))
        XCTAssertFalse(isCancellationError(AgentAPIError.server(status: 500, message: "server failed")))
    }

    func testWorkspaceSessionLoadFailureDispositionUsesFallbackOnlyForExplicitCancellation() {
        XCTAssertEqual(
            workspaceSessionLoadFailureDisposition(URLError(.cancelled)),
            .cancelled
        )

        let timeout = URLError(.timedOut)
        XCTAssertEqual(
            workspaceSessionLoadFailureDisposition(timeout),
            .failed(timeout.localizedDescription),
            "超时仍必须进入可重试的真实失败态"
        )
    }

    func testOpenWorkspaceCancellationReturnsNeutralOutcomeWithoutPublishingError() async {
        let path = "/Users/me/cancelled-workspace"
        for error in [CancellationError(), URLError(.cancelled)] as [Error] {
            let client = MockSessionStoreClient(
                projects: [],
                sessions: [],
                resolveResults: [path: .failure(error)]
            )
            let store = SessionStore(
                appStore: AppStore(),
                conversationStore: ConversationStore(),
                logStore: LogStore(),
                clientFactory: { client }
            )

            let outcome = await store.openWorkspaceOutcome(path: path)
            XCTAssertEqual(outcome, .cancelled)
            XCTAssertNil(store.errorMessage)
            XCTAssertTrue(store.sidebarProjects.isEmpty)
        }
    }

    func testOpenWorkspaceRealFailureRemainsUserVisible() async {
        let path = "/Users/me/forbidden-workspace"
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            resolveResults: [path: .failure(AgentAPIError.server(status: 403, message: "forbidden"))]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        guard case .failed(let message) = await store.openWorkspaceOutcome(path: path) else {
            return XCTFail("403 必须保持为可展示失败")
        }
        XCTAssertTrue(message.contains("403"))
        XCTAssertEqual(store.errorMessage, message)
    }

    func testWorkspaceLoadCancellationSkipsAvailabilityProbeAndGlobalErrorMutation() async {
        let workspace = AgentWorkspace(project: makeProject(id: "workspace-cancelled-load"))
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            resolveResults: [workspace.path: .success(workspace)]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.handleWorkspaceLoadFailure(workspace: workspace, error: CancellationError())

        XCTAssertTrue(client.requestedResolvePaths.isEmpty, "取消不应再发 availability probe")
        XCTAssertNil(store.errorMessage)
    }

    func testOpenWorkspaceLosingSelectionIntentBeforeResolveReturnsCannotPersistStaleWorkspace() async {
        let project = makeProject(id: "workspace-stale-open")
        let workspace = AgentWorkspace(project: project)
        let gate = WorkspaceResolveGate()
        let client = MockSessionStoreClient(
            projects: [],
            sessions: [],
            resolveWorkspaceHandler: { _ in try await gate.resolve() }
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        let opening = Task { @MainActor in
            await store.openWorkspaceOutcome(path: workspace.path)
        }
        await gate.waitUntilStarted()
        store.setSelectedProjectID("newer-selection")
        await gate.succeed(with: workspace)

        let outcome = await opening.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(store.sidebarProjects.isEmpty, "失去 ownership 的 resolve 结果不能写入最近工作区")
        XCTAssertEqual(store.selectedProjectID, "newer-selection")
    }

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

private actor WorkspaceResolveGate {
    private var continuation: CheckedContinuation<AgentWorkspace, Error>?
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func resolve() async throws -> AgentWorkspace {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            didStart = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func succeed(with workspace: AgentWorkspace) {
        continuation?.resume(returning: workspace)
        continuation = nil
    }
}

private actor WorkspaceProjectsGate {
    private var continuation: CheckedContinuation<[AgentProject], Never>?
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func projects() async -> [AgentProject] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            didStart = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func succeed(with projects: [AgentProject]) {
        continuation?.resume(returning: projects)
        continuation = nil
    }
}
