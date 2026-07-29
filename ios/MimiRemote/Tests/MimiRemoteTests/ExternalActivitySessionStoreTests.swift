import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testExternalActivityResponseDecodesOnlyReadOnlyIdentityAndRevisionFields() throws {
        let data = Data(#"""
        {
          "activities": [{
            "thread_id": "thread-1",
            "project_id": "project-1",
            "source": "codex_desktop",
            "state": "running",
            "turn_id": "turn-1",
            "revision": "rev-1",
            "last_activity_at": "2026-07-28T14:00:00.123Z"
          }],
          "scanned_at": "2026-07-28T14:00:01Z"
        }
        """#.utf8)

        let response = try AgentAPIClient.decoder.decode(ExternalActivityResponse.self, from: data)

        XCTAssertEqual(response.activities.count, 1)
        XCTAssertEqual(response.activities[0].threadID, "thread-1")
        XCTAssertEqual(response.activities[0].projectID, "project-1")
        XCTAssertEqual(response.activities[0].turnID, "turn-1")
        XCTAssertEqual(response.activities[0].revision, "rev-1")
    }

    func testExternalActivityMovesSessionBetweenActiveAndHistoryAndDeduplicatesRevision() async throws {
        let project = makeProject(id: "proj_external_activity")
        let threadID = "thread-external"
        let history = makeSession(
            id: threadID,
            projectID: project.id,
            title: "Mac 会话",
            status: SessionStatus.history.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID
        )
        let firstActivity = makeExternalActivity(
            threadID: threadID,
            projectID: project.id,
            turnID: "turn-1",
            revision: "rev-1"
        )
        let revisedActivity = makeExternalActivity(
            threadID: threadID,
            projectID: project.id,
            turnID: "turn-1",
            revision: "rev-2"
        )
        let responses = [
            ExternalActivityResponse(activities: [firstActivity], scannedAt: Date()),
            ExternalActivityResponse(activities: [firstActivity], scannedAt: Date()),
            ExternalActivityResponse(activities: [revisedActivity], scannedAt: Date()),
            ExternalActivityResponse(activities: [], scannedAt: Date())
        ].map(Optional.some)
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            workspacePages: [project.id: SessionsPage(sessions: [history])],
            historyPages: [
                threadID: HistoryMessagesPage(messages: [
                    CodexHistoryMessage(role: "assistant", content: "Mac 输出", createdAt: Date())
                ])
            ],
            externalActivityResponses: responses
        )
        let store = makeExternalActivityStore(project: project, session: history, client: client)
        store.selectedProjectID = project.id
        store.selectedSessionID = threadID

        let firstRefresh = await store.refreshExternalActivities(client: client)
        XCTAssertTrue(firstRefresh)
        let activePartition = SessionListPartition(sessions: store.sessions)
        XCTAssertEqual(activePartition.active.map(\.id), [threadID])
        XCTAssertTrue(activePartition.history.isEmpty)
        XCTAssertEqual(store.sessionsByID[threadID]?.activeTurnID, "turn-1")
        XCTAssertEqual(store.externalActivityPollingDelayNanoseconds(), 5_000_000_000)
        XCTAssertEqual(client.requestedMessageSessionIDs.count, 1)

        let duplicateRefresh = await store.refreshExternalActivities(client: client)
        XCTAssertTrue(duplicateRefresh)
        XCTAssertEqual(
            client.requestedMessageSessionIDs.count,
            1,
            "相同 revision 不应重复拉取历史"
        )

        let revisedRefresh = await store.refreshExternalActivities(client: client)
        XCTAssertTrue(revisedRefresh)
        XCTAssertEqual(client.requestedMessageSessionIDs.count, 2)

        let completedRefresh = await store.refreshExternalActivities(client: client)
        XCTAssertTrue(completedRefresh)
        let completedPartition = SessionListPartition(sessions: store.sessions)
        XCTAssertTrue(completedPartition.active.isEmpty)
        XCTAssertEqual(completedPartition.history.map(\.id), [threadID])
        XCTAssertEqual(store.sessionsByID[threadID]?.status, SessionStatus.history.rawValue)
        XCTAssertNil(store.externalActivityBySessionID[threadID])
        XCTAssertFalse(store.isExternalReadOnlySession(try XCTUnwrap(store.sessionsByID[threadID])))
        XCTAssertEqual(store.externalActivityPollingDelayNanoseconds(), 8_000_000_000)
        XCTAssertEqual(
            client.requestedMessageSessionIDs.count,
            3,
            "terminal 快照应执行一次最终历史刷新"
        )
    }

    func testExternalActivityOverridesLegacyTakenOverAndBlocksControlRPCs() async throws {
        let project = makeProject(id: "proj_external_read_only")
        let threadID = "thread-read-only"
        let history = makeSession(
            id: threadID,
            projectID: project.id,
            title: "Mac 运行中",
            status: SessionStatus.history.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            workspacePages: [project.id: SessionsPage(sessions: [history])],
            externalActivityResponses: [
                ExternalActivityResponse(
                    activities: [makeExternalActivity(
                        threadID: threadID,
                        projectID: project.id,
                        turnID: "turn-read-only",
                        revision: "rev-read-only"
                    )],
                    scannedAt: Date()
                )
            ]
        )
        let socket = MockWebSocketClient()
        let store = makeExternalActivityStore(
            project: project,
            session: history,
            client: client,
            socket: socket
        )
        store.selectedProjectID = project.id
        store.selectedSessionID = threadID
        store.sessionControlStateByID[threadID] = .takenOver

        let refresh = await store.refreshExternalActivities(client: client)
        XCTAssertTrue(refresh)
        let external = try XCTUnwrap(store.sessionsByID[threadID])
        XCTAssertEqual(store.controlState(for: external), .observing)
        XCTAssertFalse(store.canControlSession(external))
        XCTAssertFalse(store.supportsCodexThreadManagement(external))
        XCTAssertFalse(store.selectedSessionAllowsTakeOver)

        store.takeOverSession(external)
        store.connectWebSocket(external, allowNonRunning: true)
        store.interruptSelectedTurn()
        let didSend = await store.sendTurn(CodexAppServerTurnPayload(prompt: "不要发送"))
        let didGuide = await store.sendTurn(
            CodexAppServerTurnPayload(prompt: "不要引导"),
            runningDelivery: .guided
        )
        store.decideApproval(
            ApprovalSummary(id: "approval-external", title: "不要审批", kind: "command", count: 1),
            accept: true
        )
        XCTAssertFalse(didSend)
        XCTAssertFalse(didGuide)
        await store.stopSelectedSession()

        // terminal 快照到达后，最终历史补拉会暂时把行降为 history，但只读 tombstone 仍在。
        // 这一窗口也不能走“恢复历史会话并发送”的 createSession 分支。
        store.updateSession(threadID) { session in
            session.status = SessionStatus.history.rawValue
            session.activeTurnID = nil
        }
        let didResume = await store.sendTurn(CodexAppServerTurnPayload(prompt: "不要恢复"))
        XCTAssertFalse(didResume)

        XCTAssertTrue(socket.connectedSessionIDs.isEmpty)
        XCTAssertTrue(socket.sentTurns.isEmpty)
        XCTAssertTrue(socket.sentGuidance.isEmpty)
        XCTAssertTrue(socket.sentApprovals.isEmpty)
        XCTAssertEqual(socket.sentCtrlCCount, 0)
        XCTAssertTrue(client.createPayloads.isEmpty)
    }

    func testExternalActivityPollingStopsWhenOldAgentDDoesNotAdvertiseCapability() async {
        let project = makeProject(id: "proj_external_legacy")
        let history = makeSession(
            id: "thread-legacy",
            projectID: project.id,
            title: "旧 agentd",
            status: SessionStatus.history.rawValue,
            source: "codex"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            externalActivityResponses: [nil]
        )
        var sleepCalls = 0
        let store = makeExternalActivityStore(
            project: project,
            session: history,
            client: client,
            externalActivitySleep: { _ in sleepCalls += 1 }
        )
        let staleActivity = makeExternalActivity(
            threadID: history.id,
            projectID: project.id,
            turnID: "turn-old-agent",
            revision: "rev-old-agent"
        )
        store.externalActivityBySessionID[history.id] = staleActivity
        store.externalReadOnlySessionIDs.insert(history.id)
        store.updateSession(history.id) { session in
            session.status = SessionStatus.running.rawValue
            session.activeTurnID = staleActivity.turnID
        }

        await store.pollExternalActivitiesWhileVisible()

        XCTAssertEqual(client.externalActivityCallCount, 1)
        XCTAssertEqual(sleepCalls, 0)
        XCTAssertTrue(store.externalActivityCapabilityUnavailable)
        XCTAssertTrue(store.externalActivityBySessionID.isEmpty)
        XCTAssertEqual(store.sessionsByID[history.id]?.status, SessionStatus.history.rawValue)
        XCTAssertFalse(store.isExternalReadOnlySession(store.sessionsByID[history.id]!))
    }

    func testExternalActivityRetriesTerminalRefreshLeftByForegroundCancellation() async throws {
        let project = makeProject(id: "proj_external_terminal_retry")
        let threadID = "thread-terminal-retry"
        let history = makeSession(
            id: threadID,
            projectID: project.id,
            title: "待完成刷新",
            status: SessionStatus.history.rawValue,
            source: "codex",
            runtimeProvider: "codex",
            resumeID: threadID
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            workspacePages: [project.id: SessionsPage(sessions: [history])],
            historyPages: [threadID: HistoryMessagesPage(messages: [])],
            externalActivityResponses: [
                ExternalActivityResponse(activities: [], scannedAt: Date())
            ]
        )
        let store = makeExternalActivityStore(project: project, session: history, client: client)
        store.selectedProjectID = project.id
        store.selectedSessionID = threadID
        // 模拟上一次 apply 在清空 activity 后、最终补拉完成前因退后台被取消。
        store.externalReadOnlySessionIDs.insert(threadID)

        let refreshed = await store.refreshExternalActivities(client: client)

        XCTAssertTrue(refreshed)
        XCTAssertEqual(client.requestedMessageSessionIDs, [threadID])
        XCTAssertFalse(store.isExternalReadOnlySession(try XCTUnwrap(store.sessionsByID[threadID])))
    }

    private func makeExternalActivity(
        threadID: SessionID,
        projectID: String,
        turnID: TurnID,
        revision: String
    ) -> ExternalSessionActivity {
        ExternalSessionActivity(
            threadID: threadID,
            projectID: projectID,
            source: "codex_desktop",
            state: "running",
            turnID: turnID,
            revision: revision,
            lastActivityAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func makeExternalActivityStore(
        project: AgentProject,
        session: AgentSession,
        client: MockSessionStoreClient,
        socket: MockWebSocketClient = MockWebSocketClient(),
        externalActivitySleep: @escaping (UInt64) async -> Void = { _ in }
    ) -> SessionStore {
        let suiteName = "ExternalActivitySessionStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations())
        )
        appStore.endpoint = "http://127.0.0.1:8787"
        appStore.token = "test-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { socket },
            externalActivitySleep: externalActivitySleep
        )
        store.setProjectsIfChanged([project])
        store.setRecentWorkspacesIfChanged([AgentWorkspace(project: project)])
        store.setSidebarProjectsIfChanged([project])
        store.sessions = [historyAligned(session, project: project)]
        return store
    }

    private func historyAligned(_ session: AgentSession, project: AgentProject) -> AgentSession {
        AgentSession(
            id: session.id,
            projectID: project.id,
            project: project.name,
            dir: project.path,
            title: session.title,
            status: session.status,
            source: session.source,
            runtimeProvider: session.runtimeProvider,
            resumeID: session.resumeID,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            recencyAt: session.recencyAt,
            preview: session.preview,
            activeTurnID: session.activeTurnID
        )
    }
}
