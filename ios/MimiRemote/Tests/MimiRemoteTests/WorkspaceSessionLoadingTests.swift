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

    func testWorkspaceSessionRefreshScopeTracksHostGenerationWithSameWorkspaceSelection() {
        let firstHostScope = HostScope(
            profileID: "profile-a",
            installationID: "installation-a",
            generation: 1
        )
        let reconnectedHostScope = HostScope(
            profileID: "profile-a",
            installationID: "installation-a",
            generation: 2
        )

        XCTAssertNotEqual(
            WorkspaceSessionRefreshScope(hostScope: firstHostScope, workspaceID: "workspace-a"),
            WorkspaceSessionRefreshScope(hostScope: reconnectedHostScope, workspaceID: "workspace-a"),
            "同一 workspace 在连接代次变化后必须重新触发精确首屏"
        )
    }

    func testSparseWorkspaceCacheStillLoadsOneAuthoritativeFirstPage() async throws {
        for sparseCount in [1, 4] {
            let project = makeProject(id: "workspace_sparse_\(sparseCount)")
            let completePage = (0..<20).map { index in
                makeSession(
                    id: "thread_sparse_\(sparseCount)_\(index)",
                    projectID: project.id,
                    title: "会话 \(index)",
                    status: "history",
                    source: index.isMultiple(of: 2) ? "codex" : "claude",
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
                )
            }
            let client = MutableSessionPageClient(
                projects: [project],
                page: SessionsPage(sessions: completePage, nextCursor: "older", hasMore: true)
            )
            let store = SessionStore(
                appStore: AppStore(),
                conversationStore: ConversationStore(),
                logStore: LogStore(),
                clientFactory: { client }
            )
            store.projects = [project]
            store.sessions = Array(completePage.prefix(sparseCount))

            XCTAssertEqual(store.sessions(forProjectID: project.id).count, sparseCount, "稀疏缓存必须先保持可见")
            XCTAssertTrue(store.needsAuthoritativeWorkspaceSessionFirstPage(projectID: project.id))

            try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)
            try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)

            XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), completePage.map(\.id))
            XCTAssertEqual(client.requestedSessionListConsistencies, [.authoritative])
            XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
            XCTAssertFalse(store.needsAuthoritativeWorkspaceSessionFirstPage(projectID: project.id))
            XCTAssertEqual(store.sessionPageCursorByProjectID[project.id], "older")
        }
    }

    func testFastIndexedFirstPageCannotShrinkCompletedAuthoritativeWindowOrCursor() async throws {
        let project = makeProject(id: "workspace_authoritative_priority")
        let completePage = (0..<20).map { index in
            makeSession(
                id: "thread_authoritative_\(index)",
                projectID: project.id,
                title: "精确会话 \(index)",
                status: index == 0 ? "running" : "history",
                source: "codex",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
            )
        }
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: completePage, nextCursor: "authoritative-older", hasMore: true)
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]

        try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)
        let staleExisting = makeSession(
            id: completePage[0].id,
            projectID: project.id,
            title: "过期稀疏标题",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let supplementalSession = makeSession(
            id: "thread_fast_supplemental",
            projectID: project.id,
            title: "弱页补充会话",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        client.page = SessionsPage(
            sessions: [staleExisting, supplementalSession],
            nextCursor: "sparse-older",
            hasMore: true
        )

        await store.refreshSessions(
            forProjectID: project.id,
            showLoading: false,
            reuseRecent: false,
            consistency: .fastIndexed,
            activatesProject: false
        )

        XCTAssertEqual(
            Set(store.sessions(forProjectID: project.id).map(\.id)),
            Set(completePage.map(\.id) + [supplementalSession.id])
        )
        XCTAssertEqual(store.sessionsByID[completePage[0].id]?.title, completePage[0].title)
        XCTAssertEqual(store.sessionsByID[completePage[0].id]?.status, completePage[0].status)
        XCTAssertEqual(store.sessionPageCursorByProjectID[project.id], "authoritative-older")
        XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
        XCTAssertEqual(client.requestedSessionListConsistencies, [.authoritative, .fastIndexed])
    }

    func testAuthoritativeFirstPageWaitsOutCooldownInsteadOfPromotingFastCache() async throws {
        let project = makeProject(id: "workspace_authoritative_cooldown")
        let sparse = makeSession(
            id: "thread_authoritative_cooldown_sparse",
            projectID: project.id,
            title: "稀疏缓存",
            status: "history",
            source: "codex"
        )
        let completePage = (0..<20).map { index in
            makeSession(
                id: "thread_authoritative_cooldown_\(index)",
                projectID: project.id,
                title: "精确会话 \(index)",
                status: "history",
                source: "codex",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
            )
        }
        let client = MutableSessionPageClient(
            projects: [project],
            page: SessionsPage(sessions: [sparse], nextCursor: "sparse-cursor", hasMore: true)
        )
        var now = Date(timeIntervalSince1970: 1_780_000_000)
        var requestedSleeps: [UInt64] = []
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            sessionListNow: { now },
            sessionListSleep: { nanoseconds in
                requestedSleeps.append(nanoseconds)
                now = now.addingTimeInterval(Double(nanoseconds) / 1_000_000_000)
            }
        )
        store.projects = [project]

        await store.refreshSessions(
            forProjectID: project.id,
            showLoading: false,
            reuseRecent: false,
            consistency: .fastIndexed,
            activatesProject: false
        )
        let workspace = try XCTUnwrap(store.workspacesByID[project.id])
        store.sessionListCooldownUntilByBudgetKey[store.sessionListBudgetKey(for: workspace)] = now.addingTimeInterval(15)
        client.page = SessionsPage(
            sessions: completePage,
            nextCursor: "authoritative-cursor",
            hasMore: true
        )

        try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)

        XCTAssertEqual(requestedSleeps, [15_000_000_000])
        XCTAssertEqual(client.requestedSessionListConsistencies, [.fastIndexed, .authoritative])
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), completePage.map(\.id))
        XCTAssertEqual(store.sessionPageCursorByProjectID[project.id], "authoritative-cursor")
        XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
    }

    func testForgottenWorkspaceRejectsLateAuthoritativeLibraryCompletion() throws {
        let project = makeProject(id: "workspace_forgotten_late_page")
        let workspace = AgentWorkspace(project: project)
        let lateSession = makeSession(
            id: "thread_forgotten_late_page",
            projectID: project.id,
            title: "迟到会话",
            status: "history",
            source: "codex"
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [], sessions: []) }
        )
        store.recentWorkspaces = [workspace]

        store.forgetWorkspace(project)
        store.mergeSessionLibraryPages(
            [(workspace: workspace, page: SessionsPage(sessions: [lateSession]))],
            generation: store.appStore.connectionGeneration,
            consistency: .authoritative
        )

        XCTAssertTrue(store.sessions.isEmpty, "移除后的迟到响应不能复活会话")
        XCTAssertTrue(store.workspaceSessionFirstPageCompletionByKey.isEmpty)
        store.recentWorkspaces = [workspace]
        XCTAssertTrue(store.needsAuthoritativeWorkspaceSessionFirstPage(projectID: project.id))
    }

    func testLateFastLibraryPageOnlyAddsMissingSessionsAfterAuthoritativeCompletion() throws {
        let project = makeProject(id: "workspace_late_fast_library")
        let workspace = AgentWorkspace(project: project)
        let authoritativeSession = makeSession(
            id: "thread_library_shared",
            projectID: project.id,
            title: "权威标题",
            status: "running",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let staleExisting = makeSession(
            id: authoritativeSession.id,
            projectID: project.id,
            title: "过期索引标题",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let supplementalSession = makeSession(
            id: "thread_library_supplemental",
            projectID: project.id,
            title: "补充会话",
            status: "history",
            source: "codex"
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [], sessions: []) }
        )
        store.recentWorkspaces = [workspace]
        store.applyWorkspaceSessionFirstPage(
            workspace: workspace,
            page: SessionsPage(
                sessions: [authoritativeSession],
                nextCursor: "authoritative-library-cursor",
                hasMore: true
            ),
            consistency: .authoritative
        )

        store.mergeSessionLibraryPages(
            [(
                workspace: workspace,
                page: SessionsPage(
                    sessions: [staleExisting, supplementalSession],
                    nextCursor: "stale-library-cursor",
                    hasMore: true
                )
            )],
            generation: store.appStore.connectionGeneration,
            consistency: .fastIndexed
        )

        XCTAssertEqual(store.sessionsByID[authoritativeSession.id]?.title, authoritativeSession.title)
        XCTAssertEqual(store.sessionsByID[authoritativeSession.id]?.status, authoritativeSession.status)
        XCTAssertNotNil(store.sessionsByID[supplementalSession.id])
        XCTAssertEqual(store.sessionPageCursorByProjectID[project.id], "authoritative-library-cursor")
        XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
    }

    func testRestoreFailureCannotReviveWorkspaceForgottenWhileFirstPageIsInFlight() async {
        let project = makeProject(id: "workspace_restore_forgotten_in_flight")
        let workspace = AgentWorkspace(project: project)
        let snapshotSession = makeSession(
            id: "thread_restore_forgotten_in_flight",
            projectID: project.id,
            title: "旧恢复快照",
            status: "history",
            source: "codex"
        )
        let client = BlockingSessionListRefreshClient(
            projects: [project],
            page: SessionsPage(sessions: []),
            blockOnCall: 1,
            blockedError: CancellationError()
        )
        let appStore = AppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.recentWorkspaces = [workspace]
        let snapshot = SessionRestoreSnapshot(endpoint: appStore.endpoint, session: snapshotSession)

        let restore = Task { @MainActor in
            await store.resolveSessionForRestore(snapshot)
        }
        await client.waitForBlockedSessionListRefresh()
        store.forgetWorkspace(project)
        client.releaseBlockedSessionListRefresh()
        let resolved = await restore.value

        XCTAssertNil(resolved)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(store.sessionPageCursorByProjectID.isEmpty)
        XCTAssertTrue(store.workspaceSessionFirstPageCompletionByKey.isEmpty)
        XCTAssertTrue(store.recentWorkspaces.isEmpty)
    }

    func testConcurrentWorkspaceFirstPageWaitersShareNetworkAndBothObserveCompletion() async throws {
        let project = makeProject(id: "workspace_concurrent_authoritative")
        let completePage = (0..<20).map { index in
            makeSession(
                id: "thread_concurrent_authoritative_\(index)",
                projectID: project.id,
                title: "并发会话 \(index)",
                status: "history",
                source: "codex"
            )
        }
        let client = BlockingSessionListRefreshClient(
            projects: [project],
            page: SessionsPage(sessions: completePage),
            blockOnCall: 1
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]
        store.sessions = [completePage[0]]

        let first = Task { @MainActor in
            try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)
        }
        await client.waitForBlockedSessionListRefresh()
        let second = Task { @MainActor in
            try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(client.sessionsPageCallCount, 1)
        client.releaseBlockedSessionListRefresh()
        try await first.value
        try await second.value

        XCTAssertEqual(store.sessions(forProjectID: project.id).count, completePage.count)
        XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
        XCTAssertTrue(store.sessionFirstPageLoadingConsistencyByProjectID.isEmpty)
        XCTAssertTrue(store.sessionFirstPageWaiterCountByProjectID.isEmpty)
    }

    func testFastIndexedWaiterJoiningAuthoritativeRequestCannotDowngradeCompletion() async throws {
        let project = makeProject(id: "workspace_authoritative_then_fast")
        let completePage = (0..<20).map { index in
            makeSession(
                id: "thread_authoritative_then_fast_\(index)",
                projectID: project.id,
                title: "会话 \(index)",
                status: index == 0 ? "running" : "history",
                source: "codex",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
            )
        }
        let client = BlockingSessionListRefreshClient(
            projects: [project],
            page: SessionsPage(
                sessions: completePage,
                nextCursor: "authoritative-older",
                hasMore: true
            ),
            blockOnCall: 1
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]

        let authoritative = Task { @MainActor in
            try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)
        }
        await client.waitForBlockedSessionListRefresh()
        let fastIndexed = Task { @MainActor in
            await store.refreshSessions(
                forProjectID: project.id,
                showLoading: false,
                reuseRecent: false,
                consistency: .fastIndexed,
                activatesProject: false
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(client.sessionsPageCallCount, 1)
        client.releaseBlockedSessionListRefresh()
        try await authoritative.value
        await fastIndexed.value

        XCTAssertEqual(client.requestedSessionListConsistencies, [.authoritative])
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), completePage.map(\.id))
        XCTAssertEqual(store.sessionPageCursorByProjectID[project.id], "authoritative-older")
        XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
    }

    func testAuthoritativeWaitsForInFlightFastIndexedThenPerformsExactlyOnePreciseRequest() async throws {
        let project = makeProject(id: "workspace_fast_then_authoritative")
        let sparsePage = SessionsPage(
            sessions: [
                makeSession(
                    // 与权威页首行使用同一 ID，确保无论谁先提交，断言都聚焦字段优先级而非补行时序。
                    id: "thread_precise_0",
                    projectID: project.id,
                    title: "稀疏缓存",
                    status: "history",
                    source: "codex",
                    updatedAt: Date(timeIntervalSince1970: 10)
                )
            ],
            nextCursor: "fast-cursor",
            hasMore: true
        )
        let authoritativeSessions = (0..<20).map { index in
            makeSession(
                id: "thread_precise_\(index)",
                projectID: project.id,
                title: "精确会话 \(index)",
                status: index == 0 ? "running" : "history",
                source: index.isMultiple(of: 2) ? "codex" : "claude",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
            )
        }
        let authoritativePage = SessionsPage(
            sessions: authoritativeSessions,
            nextCursor: "authoritative-cursor",
            hasMore: true
        )
        let client = FastThenAuthoritativeSessionListClient(
            projects: [project],
            fastOutcome: .page(sparsePage),
            authoritativePage: authoritativePage
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]

        let fastIndexed = Task { @MainActor in
            await store.refreshSessions(
                forProjectID: project.id,
                showLoading: false,
                reuseRecent: false,
                consistency: .fastIndexed,
                activatesProject: false
            )
        }
        await client.waitForBlockedFastRequest()
        let authoritative = Task { @MainActor in
            try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)
        }
        try await waitForAuthoritativeFirstPageWaiter(in: store, projectID: project.id)

        var clientSnapshot = await client.snapshot()
        XCTAssertEqual(clientSnapshot.sessionsPageCallCount, 1, "fastIndexed 未结束前不能并发启动 authoritative")
        XCTAssertEqual(clientSnapshot.maximumConcurrentRequestCount, 1)
        XCTAssertEqual(store.sessionFirstPageLoadingConsistencyByProjectID[project.id], .authoritative)
        XCTAssertEqual(store.sessionFirstPageWaiterCountByProjectID[project.id], 2)

        await client.releaseFastRequest()
        // 故意先等 authoritative：fast owner 此时可能尚未恢复清理 key，正是生产竞态的关键顺序。
        try await awaitFastThenAuthoritativeTask(authoritative)
        await fastIndexed.value

        clientSnapshot = await client.snapshot()
        XCTAssertEqual(clientSnapshot.sessionsPageCallCount, 2)
        XCTAssertEqual(clientSnapshot.requestedSessionListConsistencies, [.fastIndexed, .authoritative])
        XCTAssertEqual(clientSnapshot.maximumConcurrentRequestCount, 1)
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), authoritativeSessions.map(\.id))
        XCTAssertEqual(store.sessionPageCursorByProjectID[project.id], "authoritative-cursor")
        XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
        XCTAssertTrue(store.sessionFirstPageLoadingConsistencyByProjectID.isEmpty)
        XCTAssertTrue(store.sessionFirstPageWaiterCountByProjectID.isEmpty)
    }

    func testAuthoritativeStillRunsAfterInFlightFastIndexedFails() async throws {
        let project = makeProject(id: "workspace_failed_fast_then_authoritative")
        let authoritativeSession = makeSession(
            id: "thread_after_failed_fast",
            projectID: project.id,
            title: "精确恢复",
            status: "history",
            source: "codex"
        )
        let client = FastThenAuthoritativeSessionListClient(
            projects: [project],
            fastOutcome: .failure,
            authoritativePage: SessionsPage(
                sessions: [authoritativeSession],
                nextCursor: "authoritative-after-failure",
                hasMore: true
            )
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]

        let fastIndexed = Task { @MainActor in
            await store.refreshSessions(
                forProjectID: project.id,
                showLoading: false,
                reportErrorOnFailure: false,
                reuseRecent: false,
                consistency: .fastIndexed,
                activatesProject: false
            )
        }
        await client.waitForBlockedFastRequest()
        let authoritative = Task { @MainActor in
            try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)
        }

        try await waitForAuthoritativeFirstPageWaiter(in: store, projectID: project.id)
        var clientSnapshot = await client.snapshot()
        XCTAssertEqual(clientSnapshot.sessionsPageCallCount, 1, "fastIndexed 失败前 authoritative 必须仍复用同一条 in-flight")
        XCTAssertEqual(clientSnapshot.maximumConcurrentRequestCount, 1)
        XCTAssertEqual(store.sessionFirstPageLoadingConsistencyByProjectID[project.id], .authoritative)
        XCTAssertEqual(store.sessionFirstPageWaiterCountByProjectID[project.id], 2)

        await client.releaseFastRequest()
        try await awaitFastThenAuthoritativeTask(authoritative)
        await fastIndexed.value

        clientSnapshot = await client.snapshot()
        XCTAssertEqual(clientSnapshot.sessionsPageCallCount, 2)
        XCTAssertEqual(clientSnapshot.requestedSessionListConsistencies, [.fastIndexed, .authoritative])
        XCTAssertEqual(clientSnapshot.maximumConcurrentRequestCount, 1)
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [authoritativeSession.id])
        XCTAssertEqual(store.sessionPageCursorByProjectID[project.id], "authoritative-after-failure")
        XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
        XCTAssertTrue(store.sessionFirstPageLoadingConsistencyByProjectID.isEmpty)
        XCTAssertTrue(store.sessionFirstPageWaiterCountByProjectID.isEmpty)
    }

    func testAuthoritativeStillRunsAfterInFlightFastIndexedIsCancelled() async throws {
        let project = makeProject(id: "workspace_cancelled_fast_then_authoritative")
        let authoritativeSession = makeSession(
            id: "thread_after_cancelled_fast",
            projectID: project.id,
            title: "取消后精确恢复",
            status: "history",
            source: "codex"
        )
        let client = FastThenAuthoritativeSessionListClient(
            projects: [project],
            fastOutcome: .cancellation,
            authoritativePage: SessionsPage(sessions: [authoritativeSession])
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]

        let fastIndexed = Task { @MainActor in
            await store.refreshSessions(
                forProjectID: project.id,
                showLoading: false,
                reportErrorOnFailure: false,
                reuseRecent: false,
                consistency: .fastIndexed,
                activatesProject: false
            )
        }
        await client.waitForBlockedFastRequest()
        let authoritative = Task { @MainActor in
            try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)
        }

        try await waitForAuthoritativeFirstPageWaiter(in: store, projectID: project.id)
        var clientSnapshot = await client.snapshot()
        XCTAssertEqual(clientSnapshot.sessionsPageCallCount, 1, "fastIndexed 取消前 authoritative 必须仍复用同一条 in-flight")
        XCTAssertEqual(clientSnapshot.maximumConcurrentRequestCount, 1)
        XCTAssertEqual(store.sessionFirstPageLoadingConsistencyByProjectID[project.id], .authoritative)
        XCTAssertEqual(store.sessionFirstPageWaiterCountByProjectID[project.id], 2)

        await client.releaseFastRequest()
        try await awaitFastThenAuthoritativeTask(authoritative)
        await fastIndexed.value

        clientSnapshot = await client.snapshot()
        XCTAssertEqual(clientSnapshot.sessionsPageCallCount, 2)
        XCTAssertEqual(clientSnapshot.requestedSessionListConsistencies, [.fastIndexed, .authoritative])
        XCTAssertEqual(clientSnapshot.maximumConcurrentRequestCount, 1)
        XCTAssertEqual(store.sessions(forProjectID: project.id).map(\.id), [authoritativeSession.id])
        XCTAssertEqual(store.workspaceSessionFirstPageConsistency(projectID: project.id), .authoritative)
        XCTAssertTrue(store.sessionFirstPageLoadingConsistencyByProjectID.isEmpty)
        XCTAssertTrue(store.sessionFirstPageWaiterCountByProjectID.isEmpty)
    }

    func testWorkspaceIdentityRemapStopsAuthoritativeUpgradeAfterFastRequest() async throws {
        let project = makeProject(id: "workspace_identity_remap_upgrade")
        let remappedProject = AgentProject(
            id: project.id,
            name: project.name,
            path: "/tmp/workspace_identity_remap_upgrade_moved"
        )
        let client = FastThenAuthoritativeSessionListClient(
            projects: [project],
            fastOutcome: .page(SessionsPage(sessions: [])),
            authoritativePage: SessionsPage(sessions: [])
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )
        store.projects = [project]

        let fastIndexed = Task { @MainActor in
            await store.refreshSessions(
                forProjectID: project.id,
                showLoading: false,
                reuseRecent: false,
                consistency: .fastIndexed,
                activatesProject: false
            )
        }
        await client.waitForBlockedFastRequest()
        let authoritative = Task { @MainActor in
            try await store.ensureAuthoritativeWorkspaceSessionFirstPage(projectID: project.id)
        }
        try await waitForAuthoritativeFirstPageWaiter(in: store, projectID: project.id)

        store.recentWorkspaces = [AgentWorkspace(project: remappedProject)]
        await client.releaseFastRequest()
        do {
            try await awaitFastThenAuthoritativeTask(authoritative)
            XCTFail("工作区同 ID 换路径后，旧 waiter 不能继续启动 authoritative 请求")
        } catch is CancellationError {
            // 预期：identity guard 取消旧升级。
        }
        await fastIndexed.value

        let clientSnapshot = await client.snapshot()
        XCTAssertEqual(clientSnapshot.sessionsPageCallCount, 1)
        XCTAssertEqual(clientSnapshot.requestedSessionListConsistencies, [.fastIndexed])
        XCTAssertEqual(clientSnapshot.maximumConcurrentRequestCount, 1)
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

private enum FastThenAuthoritativeTestError: Error {
    case fastIndexedFailed
    case timedOut
}

private enum FastRequestOutcome {
    case page(SessionsPage)
    case failure
    case cancellation
}

private struct FastThenAuthoritativeClientSnapshot {
    let sessionsPageCallCount: Int
    let requestedSessionListConsistencies: [SessionListConsistency]
    let maximumConcurrentRequestCount: Int
}

/// mock 的请求计数和 continuation 全部由 actor 隔离，避免测试读写本身制造数据竞争。
private actor FastThenAuthoritativeClientState {
    let projectsResult: [AgentProject]
    let fastOutcome: FastRequestOutcome
    let authoritativePage: SessionsPage

    private var sessionsPageCallCount = 0
    private var requestedSessionListConsistencies: [SessionListConsistency] = []
    private var activeRequestCount = 0
    private var maximumConcurrentRequestCount = 0
    private var fastContinuation: CheckedContinuation<SessionsPage, Error>?
    private var fastRequestWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        projects: [AgentProject],
        fastOutcome: FastRequestOutcome,
        authoritativePage: SessionsPage
    ) {
        self.projectsResult = projects
        self.fastOutcome = fastOutcome
        self.authoritativePage = authoritativePage
    }

    func projects() -> [AgentProject] {
        projectsResult
    }

    func sessionsPage(consistency: SessionListConsistency) async throws -> SessionsPage {
        sessionsPageCallCount += 1
        requestedSessionListConsistencies.append(consistency)
        activeRequestCount += 1
        maximumConcurrentRequestCount = max(maximumConcurrentRequestCount, activeRequestCount)
        defer { activeRequestCount -= 1 }

        if consistency == .fastIndexed {
            return try await withCheckedThrowingContinuation { continuation in
                fastContinuation = continuation
                let waiters = fastRequestWaiters
                fastRequestWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        return authoritativePage
    }

    func waitForBlockedFastRequest() async {
        guard fastContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            guard fastContinuation == nil else {
                continuation.resume()
                return
            }
            fastRequestWaiters.append(continuation)
        }
    }

    func releaseFastRequest() {
        guard let continuation = fastContinuation else { return }
        fastContinuation = nil
        switch fastOutcome {
        case .page(let page):
            continuation.resume(returning: page)
        case .failure:
            continuation.resume(throwing: FastThenAuthoritativeTestError.fastIndexedFailed)
        case .cancellation:
            continuation.resume(throwing: CancellationError())
        }
    }

    func snapshot() -> FastThenAuthoritativeClientSnapshot {
        FastThenAuthoritativeClientSnapshot(
            sessionsPageCallCount: sessionsPageCallCount,
            requestedSessionListConsistencies: requestedSessionListConsistencies,
            maximumConcurrentRequestCount: maximumConcurrentRequestCount
        )
    }
}

/// 精确模拟冷启动顺序：第一条 fastIndexed 持续占用 transport，authoritative 只能在其结束后启动。
private final class FastThenAuthoritativeSessionListClient: SessionStoreAPIClient {
    private let state: FastThenAuthoritativeClientState

    init(
        projects: [AgentProject],
        fastOutcome: FastRequestOutcome,
        authoritativePage: SessionsPage
    ) {
        state = FastThenAuthoritativeClientState(
            projects: projects,
            fastOutcome: fastOutcome,
            authoritativePage: authoritativePage
        )
    }

    func projects() async throws -> [AgentProject] {
        await state.projects()
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        state.authoritativePage.sessions
    }

    func sessionsPage(
        workspace: AgentWorkspace,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage {
        try await state.sessionsPage(consistency: consistency)
    }

    func waitForBlockedFastRequest() async {
        await state.waitForBlockedFastRequest()
    }

    func releaseFastRequest() async {
        await state.releaseFastRequest()
    }

    func snapshot() async -> FastThenAuthoritativeClientSnapshot {
        await state.snapshot()
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw MockError.unimplemented
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        throw MockError.unimplemented
    }

    func stopSession(id: String) async throws {
        throw MockError.unimplemented
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        []
    }
}

/// 先等待 authoritative 才能覆盖“fast task 已结束、owner 尚未清 key”的真实调度窗口；超时会取消底层任务，避免测试永久挂住。
private func awaitFastThenAuthoritativeTask(
    _ task: Task<Void, Error>,
    timeoutNanoseconds: UInt64 = 1_000_000_000
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            try await task.value
        }
        group.addTask {
            try await Task.sleep(nanoseconds: timeoutNanoseconds)
            throw FastThenAuthoritativeTestError.timedOut
        }
        do {
            _ = try await group.next()
            group.cancelAll()
        } catch {
            task.cancel()
            group.cancelAll()
            throw error
        }
    }
}

/// 不依赖固定 sleep；只有 authoritative 已登记为第二个 waiter 后才释放 fast 请求。
@MainActor
private func waitForAuthoritativeFirstPageWaiter(
    in store: SessionStore,
    projectID: String,
    attempts: Int = 100
) async throws {
    for _ in 0..<attempts {
        if store.sessionFirstPageLoadingConsistencyByProjectID[projectID] == .authoritative,
           store.sessionFirstPageWaiterCountByProjectID[projectID] == 2 {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw FastThenAuthoritativeTestError.timedOut
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
