import XCTest
@testable import CodexAgentPad

@MainActor
final class ConversationDataFlowTests: XCTestCase {
    func testHistoryMergeDeduplicatesLocalEchoByRoleAndContent() {
        let store = ConversationStore()
        let sessionID = "sess_data_flow"
        let now = Date()

        // 本地回显先进入对话列表，后端历史确认到达后必须合并到同一条消息语义上。
        store.appendUser("帮我检查测试结构", sessionID: sessionID)
        store.setHistory([
            CodexHistoryMessage(role: "user", content: "帮我检查测试结构", createdAt: now.addingTimeInterval(-2)),
            CodexHistoryMessage(role: "assistant", content: "已检查。", createdAt: now.addingTimeInterval(-1))
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(messages.filter { $0.role == .user && $0.content == "帮我检查测试结构" }.count, 1)
        XCTAssertTrue(store.hasLoadedHistory(sessionID: sessionID))
    }

    func testStructuredHistoryConfirmsLocalEchoByClientMessageID() {
        let store = ConversationStore()
        let sessionID = "sess_structured_history"
        let clientMessageID = "client-history-1"

        store.appendLocalUser("帮我检查历史会话", sessionID: sessionID, clientMessageID: clientMessageID, sendStatus: .sending)
        store.setHistory([
            CodexHistoryMessage(
                id: "msg_history_1",
                role: "user",
                content: "帮我检查历史会话",
                createdAt: Date(timeIntervalSince1970: 1),
                clientMessageID: clientMessageID,
                revision: 1,
                sendStatus: .confirmed
            )
        ], sessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.stableID, "msg_history_1")
        XCTAssertEqual(messages.first?.clientMessageID, clientMessageID)
        XCTAssertEqual(messages.first?.sendStatus, .confirmed)
        XCTAssertEqual(messages.first?.revision, 1)
    }

    func testAssistantStreamUpdatesExistingAssistantRow() async throws {
        let store = ConversationStore()
        let sessionID = "sess_stream_merge"

        store.appendUser("开始", sessionID: sessionID)
        store.ingestTerminalOutput("│ • 第一段回复\n", sessionID: sessionID)
        try await Task.sleep(nanoseconds: 1_100_000_000)

        var messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.last?.role, .assistant)
        XCTAssertEqual(messages.last?.content, "第一段回复")

        // 第二段 assistant 输出应该复用最后一条 assistant 行，避免流式 delta 重放造成重复气泡。
        store.ingestTerminalOutput("│ • 第二段回复\n继续内容\n", sessionID: sessionID)
        try await Task.sleep(nanoseconds: 1_100_000_000)

        messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.last?.role, .assistant)
        XCTAssertTrue(messages.last?.content.contains("第二段回复") == true)
        XCTAssertTrue(messages.last?.content.contains("继续内容") == true)
        XCTAssertFalse(messages.last?.content.contains("第一段回复") == true)
    }

    func testRepeatedAssistantCandidateDoesNotDuplicateRows() async throws {
        let store = ConversationStore()
        let sessionID = "sess_replay"

        store.ingestTerminalOutput("│ • 可重放的回复\n", sessionID: sessionID)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(store.messages(for: sessionID).count, 1)

        // 重连后同一段输出可能再次到达；内容未变化时 reducer 不应增加新消息。
        store.ingestTerminalOutput("│ • 可重放的回复\n", sessionID: sessionID)
        try await Task.sleep(nanoseconds: 1_100_000_000)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, .assistant)
        XCTAssertEqual(messages.first?.content, "可重放的回复")
    }

    func testAgentEventDecodesLegacyAndStructuredAssistantDelta() throws {
        let decoder = JSONDecoder()

        let output = try decoder.decode(AgentEvent.self, from: Data(#"{"type":"output","data":"hello"}"#.utf8))
        if case .output(let data) = output {
            XCTAssertEqual(data, "hello")
        } else {
            XCTFail("Expected output event")
        }

        let assistantDelta = try decoder.decode(
            AgentEvent.self,
            from: Data(#"{"type":"assistant_delta","delta":{"text":"结构化增量","role":"assistant","kind":"message"}}"#.utf8)
        )
        if case .assistantDelta(let delta, _) = assistantDelta {
            XCTAssertEqual(delta.text, "结构化增量")
        } else {
            XCTFail("Expected assistant delta event")
        }
    }

    func testStructuredAssistantDeltaKeepsStableMetadata() throws {
        let decoder = JSONDecoder()

        let event = try decoder.decode(
            StructuredAgentEvent.self,
            from: Data(#"{"type":"assistant_delta","seq":42,"session_id":"sess_1","turn_id":"turn_1","item_id":"item_1","message_id":"msg_1","revision":3,"delta":{"text":"hello","role":"assistant","kind":"message"}}"#.utf8)
        )

        if case .assistantDelta(let delta, let meta) = event {
            XCTAssertEqual(delta.text, "hello")
            XCTAssertEqual(meta.seq, 42)
            XCTAssertEqual(meta.sessionID, "sess_1")
            XCTAssertEqual(meta.turnID, "turn_1")
            XCTAssertEqual(meta.itemID, "item_1")
            XCTAssertEqual(meta.messageID, "msg_1")
            XCTAssertEqual(meta.revision, 3)
        } else {
            XCTFail("Expected structured assistant delta")
        }
    }

    func testMessagePageResponseMapsToLegacyHistoryMessages() throws {
        let json = """
        {
          "page": {
            "session_id": "sess_1",
            "messages": [
              {
                "id": "msg_1",
                "session_id": "sess_1",
                "client_message_id": "client_1",
                "turn_id": "turn_1",
                "item_id": "item_1",
                "role": "user",
                "kind": "message",
                "content": "本地回显",
                "seq": 7,
                "revision": 1,
                "send_status": "confirmed"
              }
            ],
            "next_cursor": "next",
            "previous_cursor": "prev",
            "has_more_before": true,
            "has_more_after": false,
            "snapshot_seq": 9
          }
        }
        """

        let response = try JSONDecoder().decode(MessagesResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.messages.count, 1)
        XCTAssertEqual(response.messages.first?.id, "msg_1")
        XCTAssertEqual(response.messages.first?.clientMessageID, "client_1")
        XCTAssertEqual(response.messages.first?.seq, 7)
        XCTAssertEqual(response.messages.first?.revision, 1)
        XCTAssertEqual(response.messages.first?.sendStatus, .confirmed)
        XCTAssertEqual(response.nextCursor, "next")
        XCTAssertEqual(response.previousCursor, "prev")
        XCTAssertEqual(response.hasMoreBefore, true)
    }

    func testSparseSessionRowsDecodeWithSafeDefaultsAndPaginationCursor() throws {
        let json = """
        {
          "rows": [
            {
              "id": "sess_sparse",
              "project_id": "proj_1"
            }
          ],
          "next_cursor": "cursor_next",
          "has_more": true
        }
        """

        let response = try JSONDecoder().decode(SessionsResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.rows.count, 1)
        XCTAssertEqual(response.rows.first?.title, "未命名会话")
        XCTAssertEqual(response.rows.first?.status, .unknown)
        XCTAssertEqual(response.rows.first?.source, "codex")
        XCTAssertEqual(response.rows.first?.revision, 0)
        XCTAssertEqual(response.sessions.first?.id, "sess_sparse")
        XCTAssertEqual(response.sessions.first?.projectID, "proj_1")
        XCTAssertEqual(response.sessions.first?.source, "codex")
        XCTAssertEqual(response.nextCursor, "cursor_next")
        XCTAssertEqual(response.hasMore, true)
    }

    func testLegacyMessagesResponsePreservesCursorAndClientMessageIDFallback() throws {
        let json = """
        {
          "messages": [
            {
              "role": "user",
              "content": "本地回显",
              "client_message_id": "client_echo_1"
            }
          ],
          "next_cursor": "newer",
          "previous_cursor": "older",
          "has_more_before": true
        }
        """

        let response = try JSONDecoder().decode(MessagesResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.messages.count, 1)
        XCTAssertEqual(response.messages.first?.id, "client_echo_1")
        XCTAssertEqual(response.messages.first?.clientMessageID, "client_echo_1")
        XCTAssertEqual(response.messages.first?.sendStatus, nil)
        XCTAssertEqual(response.nextCursor, "newer")
        XCTAssertEqual(response.previousCursor, "older")
        XCTAssertEqual(response.hasMoreBefore, true)
    }

    func testSparseMessagePageDefaultsToEmptyBoundedPage() throws {
        let response = try JSONDecoder().decode(
            MessagesResponse.self,
            from: Data(#"{"page":{"session_id":"sess_empty"}}"#.utf8)
        )

        XCTAssertEqual(response.page?.sessionID, "sess_empty")
        XCTAssertEqual(response.messages, [])
        XCTAssertEqual(response.page?.hasMoreBefore, false)
        XCTAssertEqual(response.page?.hasMoreAfter, false)
        XCTAssertEqual(response.nextCursor, nil)
        XCTAssertEqual(response.previousCursor, nil)
    }

    func testStructuredAssistantDeltaMergesByStableItemAndSeq() {
        let store = ConversationStore()
        let sessionID = "sess_structured"

        store.applyAssistantDelta(
            AgentDelta(text: "Hel", role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: 1,
                sessionID: sessionID,
                turnID: "turn_1",
                itemID: "item_1",
                messageID: nil,
                clientMessageID: nil,
                revision: 1,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )
        store.applyAssistantDelta(
            AgentDelta(text: "lo", role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: 2,
                sessionID: sessionID,
                turnID: "turn_1",
                itemID: "item_1",
                messageID: nil,
                clientMessageID: nil,
                revision: 2,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )
        store.applyAssistantDelta(
            AgentDelta(text: "lo", role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: 2,
                sessionID: sessionID,
                turnID: "turn_1",
                itemID: "item_1",
                messageID: nil,
                clientMessageID: nil,
                revision: 2,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, .assistant)
        XCTAssertEqual(messages.first?.content, "Hello")
        XCTAssertEqual(messages.first?.stableID, "item_1")
    }

    func testAssistantDeltaIgnoresOlderRevisionForSameStableItem() {
        let store = ConversationStore()
        let sessionID = "sess_revision"

        store.applyAssistantDelta(
            AgentDelta(text: "新版本", role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: nil,
                sessionID: sessionID,
                turnID: "turn_1",
                itemID: "item_revision",
                messageID: nil,
                clientMessageID: nil,
                revision: 2,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )
        store.applyAssistantDelta(
            AgentDelta(text: "旧版本", role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: nil,
                sessionID: sessionID,
                turnID: "turn_1",
                itemID: "item_revision",
                messageID: nil,
                clientMessageID: nil,
                revision: 1,
                createdAt: nil
            ),
            fallbackSessionID: sessionID
        )

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "新版本")
        XCTAssertEqual(messages.first?.revision, 2)
    }

    func testLocalEchoCanBeConfirmedByClientMessageID() {
        let store = ConversationStore()
        let sessionID = "sess_echo"
        let clientMessageID = "client-1"

        store.appendLocalUser("帮我跑测试", sessionID: sessionID, clientMessageID: clientMessageID, sendStatus: .sending)
        store.updateSendStatus(clientMessageID: clientMessageID, sessionID: sessionID, status: .sent)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.clientMessageID, clientMessageID)
        XCTAssertEqual(messages.first?.sendStatus, .sent)
    }

    func testCompletedMessageConfirmsLocalEchoByClientMessageIDWithoutDuplicate() throws {
        let store = ConversationStore()
        let sessionID = "sess_confirm"
        let clientMessageID = "client-confirm-1"
        store.appendLocalUser("帮我跑测试", sessionID: sessionID, clientMessageID: clientMessageID, sendStatus: .sending)

        let message = try JSONDecoder().decode(
            AgentMessage.self,
            from: Data("""
            {
              "id": "msg_server_1",
              "session_id": "\(sessionID)",
              "client_message_id": "\(clientMessageID)",
              "role": "user",
              "content": "帮我跑测试",
              "revision": 1,
              "send_status": "confirmed"
            }
            """.utf8)
        )

        store.completeMessage(message, metadata: .empty, fallbackSessionID: sessionID)

        let messages = store.messages(for: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.clientMessageID, clientMessageID)
        XCTAssertEqual(messages.first?.stableID, "msg_server_1")
        XCTAssertEqual(messages.first?.content, "帮我跑测试")
        XCTAssertEqual(messages.first?.sendStatus, .confirmed)
        XCTAssertEqual(messages.first?.revision, 1)

        let replay = try JSONDecoder().decode(
            AgentMessage.self,
            from: Data("""
            {
              "id": "msg_server_1",
              "session_id": "\(sessionID)",
              "role": "user",
              "content": "帮我跑测试",
              "revision": 2,
              "send_status": "confirmed"
            }
            """.utf8)
        )
        store.completeMessage(replay, metadata: .empty, fallbackSessionID: sessionID)

        let replayedMessages = store.messages(for: sessionID)
        XCTAssertEqual(replayedMessages.count, 1)
        XCTAssertEqual(replayedMessages.first?.stableID, "msg_server_1")
        XCTAssertEqual(replayedMessages.first?.revision, 2)
    }

    func testStructuredEventsDecodeFallbackPayloadsAndApprovalContext() throws {
        let decoder = JSONDecoder()

        let legacyDelta = try decoder.decode(
            StructuredAgentEvent.self,
            from: Data(#"{"type":"assistant_delta","data":"兼容增量","seq":8,"session_id":"sess_1","message_id":"msg_1"}"#.utf8)
        )
        if case .assistantDelta(let delta, let meta) = legacyDelta {
            XCTAssertEqual(delta.text, "兼容增量")
            XCTAssertEqual(meta.seq, 8)
            XCTAssertEqual(meta.messageID, "msg_1")
        } else {
            XCTFail("Expected assistant delta")
        }

        let approval = try decoder.decode(
            StructuredAgentEvent.self,
            from: Data(#"{"type":"approval_request","approval":{"id":"approval_1","title":"运行命令","body":"go test ./...","kind":"command","risk":"medium"},"seq":9,"session_id":"sess_1"}"#.utf8)
        )
        if case .approvalRequest(let request, let meta) = approval {
            XCTAssertEqual(request.id, "approval_1")
            XCTAssertEqual(request.kind, "command")
            XCTAssertEqual(request.risk, "medium")
            XCTAssertEqual(meta.seq, 9)
        } else {
            XCTFail("Expected approval request")
        }
    }

    func testAgentSessionDecodesStableServerIdentifiers() throws {
        let json = """
        {
          "id": "sess_1",
          "project_id": "proj_1",
          "project": "Codex iPad Agent",
          "dir": "/tmp/project",
          "title": "数据流测试",
          "status": "running",
          "source": "codex",
          "resume_id": "thread_1",
          "created_at": "2026-05-31T10:00:00Z",
          "updated_at": "2026-05-31T10:01:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let session = try decoder.decode(AgentSession.self, from: Data(json.utf8))

        XCTAssertEqual(session.id, "sess_1")
        XCTAssertEqual(session.projectID, "proj_1")
        XCTAssertEqual(session.resumeID, "thread_1")
        XCTAssertTrue(session.isRunning)
    }

    func testSessionStoreAutoAttachKeepsExplicitHistorySelection() async {
        let project = makeProject(id: "proj_1")
        let selectedHistory = makeSession(id: "codex_selected", projectID: project.id, title: "用户点选的历史", status: "history", source: "codex", resumeID: "selected")
        let latestRunning = makeSession(id: "sess_latest", projectID: project.id, title: "最新运行会话", status: "running", source: "agentd")
        let client = MockSessionStoreClient(projects: [project], sessions: [latestRunning, selectedHistory])
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        XCTAssertNil(store.selectedSessionID)
        await store.selectSession(selectedHistory)
        await store.refreshAll(autoAttach: true)

        XCTAssertEqual(client.requestedProjectIDs.compactMap { $0 }, [project.id, project.id])
        XCTAssertEqual(store.selectedSessionID, selectedHistory.id)
        XCTAssertEqual(store.selectedProjectID, project.id)
        XCTAssertTrue(conversationStore.hasLoadedHistory(sessionID: selectedHistory.id))
    }

    func testSelectingHistorySessionKeepsSelectionWhenMessages404() async {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_missing", projectID: project.id, title: "缺失 rollout", status: "history", source: "codex", resumeID: "missing")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            messagesError: AgentAPIError.server(status: 404, message: "读取 Codex 历史失败")
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

        XCTAssertEqual(client.requestedMessageSessionIDs, [history.id])
        XCTAssertEqual(store.selectedSessionID, history.id)
        XCTAssertFalse(conversationStore.hasLoadedHistory(sessionID: history.id))
        XCTAssertTrue(store.statusMessage?.contains("HTTP 404") == true)
    }

    func testSendingPromptToCodexHistoryResumesAndKeepsLocalHiMessage() async throws {
        let project = makeProject(id: "proj_1")
        let history = makeSession(id: "codex_history", projectID: project.id, title: "历史", status: "history", source: "codex", resumeID: "history")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [history],
            createSessionResponse: try makeCreateSessionResponse(session: history)
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
        await store.sendPrompt("hi")

        XCTAssertEqual(client.createPayloads.count, 1)
        XCTAssertEqual(client.createPayloads.first?.resumeID, history.resumeID)
        XCTAssertEqual(client.createPayloads.first?.prompt, "hi")
        let messages = conversationStore.messages(for: history.id)
        XCTAssertTrue(messages.contains { $0.role == .user && $0.content == "历史问题" })
        XCTAssertTrue(messages.contains { $0.role == .assistant && $0.content == "历史回答" })
        XCTAssertTrue(messages.contains { $0.role == .user && $0.content == "hi" && $0.sendStatus == .sent })
    }

    func testSessionStoreProjectSelectionRefreshesProjectHistoryWithoutSelectingLatest() async {
        let firstProject = makeProject(id: "proj_1")
        let freshHistory = makeSession(id: "codex_fresh", projectID: firstProject.id, title: "刷新后的历史", status: "history", source: "codex", resumeID: "fresh")
        let client = MockSessionStoreClient(
            projects: [firstProject],
            sessions: [],
            projectSessions: [firstProject.id: [freshHistory]]
        )
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.selectProject(firstProject)

        XCTAssertEqual(client.requestedProjectIDs, [firstProject.id])
        XCTAssertEqual(store.filteredSessions.map(\.id), [freshHistory.id])
        XCTAssertNil(store.selectedSessionID)
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

    func testSessionStoreOnlyShowsThreeProjectSessionsByDefault() async {
        let project = makeProject(id: "proj_1")
        let sessions = (0..<5).map { index in
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

        await store.refreshAll(autoAttach: false)

        XCTAssertEqual(store.visibleSessions(forProjectID: project.id).map(\.id), ["codex_0", "codex_1", "codex_2"])
        XCTAssertEqual(store.hiddenSessionCount(forProjectID: project.id), 2)

        store.toggleSessionListExpansion(projectID: project.id)
        XCTAssertEqual(store.visibleSessions(forProjectID: project.id).count, 5)
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

    func testRefreshCurrentContextConsumesRunningRecentOutput() async throws {
        let project = makeProject(id: "proj_1")
        let running = makeSession(id: "sess_running", projectID: project.id, title: "运行中", status: "running", source: "agentd")
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [running],
            sessionResponses: [
                running.id: try makeSessionResponse(session: running, recentOutput: "│ • 从 Mac 回来的回复\n")
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
        store.selectedProjectID = project.id
        store.selectedSessionID = running.id
        await store.refreshCurrentContext()
        try await Task.sleep(nanoseconds: 1_100_000_000)

        XCTAssertEqual(client.requestedSessionIDs, [running.id])
        XCTAssertTrue(conversationStore.messages(for: running.id).contains { $0.role == .assistant && $0.content == "从 Mac 回来的回复" })
    }

    func testRunningSessionAloneDoesNotShowForegroundActivity() async {
        let project = makeProject(id: "proj_1")
        let running = makeSession(id: "sess_running", projectID: project.id, title: "运行中", status: "running", source: "agentd")
        let client = MockSessionStoreClient(projects: [project], sessions: [running])
        let store = SessionStore(
            appStore: AppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client }
        )

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        store.selectedSessionID = running.id

        XCTAssertNil(store.selectedForegroundActivity)
    }

    func testSendingPromptCreatesWaitingForegroundActivity() async throws {
        let project = makeProject(id: "proj_1")
        let created = makeSession(id: "sess_created", projectID: project.id, title: "新会话", status: "running", source: "agentd")
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

        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        let accepted = await store.sendPrompt("帮我检查项目")

        XCTAssertTrue(accepted)
        XCTAssertEqual(store.selectedForegroundActivity, .waitingForAssistant)
    }
}

private final class MockSessionStoreClient: SessionStoreAPIClient {
    let projectsResult: [AgentProject]
    let sessionsResult: [AgentSession]
    let projectSessions: [String: [AgentSession]]
    let createSessionResponse: CreateSessionResponse?
    let sessionResponses: [String: SessionResponse]
    let messagesResult: [CodexHistoryMessage]
    let messagesError: Error?
    var requestedProjectIDs: [String?] = []
    var requestedSessionIDs: [String] = []
    var requestedMessageSessionIDs: [String] = []
    var createPayloads: [CreateSessionRequest] = []

    init(
        projects: [AgentProject],
        sessions: [AgentSession],
        projectSessions: [String: [AgentSession]] = [:],
        createSessionResponse: CreateSessionResponse? = nil,
        sessionResponses: [String: SessionResponse] = [:],
        messagesResult: [CodexHistoryMessage]? = nil,
        messagesError: Error? = nil
    ) {
        self.projectsResult = projects
        self.sessionsResult = sessions
        self.projectSessions = projectSessions
        self.createSessionResponse = createSessionResponse
        self.sessionResponses = sessionResponses
        self.messagesResult = messagesResult ?? [
            CodexHistoryMessage(role: "user", content: "历史问题", createdAt: Date(timeIntervalSince1970: 1)),
            CodexHistoryMessage(role: "assistant", content: "历史回答", createdAt: Date(timeIntervalSince1970: 2))
        ]
        self.messagesError = messagesError
    }

    func projects() async throws -> [AgentProject] {
        projectsResult
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        requestedProjectIDs.append(projectID)
        if let projectID, let sessions = projectSessions[projectID] {
            return sessions
        }
        return sessionsResult
    }

    func session(id: String) async throws -> SessionResponse {
        requestedSessionIDs.append(id)
        guard let response = sessionResponses[id] else {
            throw MockError.unimplemented
        }
        return response
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        createPayloads.append(payload)
        guard let createSessionResponse else {
            throw MockError.unimplemented
        }
        return createSessionResponse
    }

    func stopSession(id: String) async throws {
        throw MockError.unimplemented
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        requestedMessageSessionIDs.append(sessionID)
        if let messagesError {
            throw messagesError
        }
        return messagesResult
    }

    func websocketURL(sessionID: String) throws -> URL {
        URL(string: "ws://127.0.0.1/\(sessionID)")!
    }
}

private enum MockError: Error {
    case unimplemented
}

private func makeProject(id: String) -> AgentProject {
    AgentProject(id: id, name: id, path: "/tmp/\(id)")
}

private func makeCreateSessionResponse(session: AgentSession) throws -> CreateSessionResponse {
    let json = """
    {
      "session": {
        "id": "\(session.id)",
        "project_id": "\(session.projectID)",
        "project": "\(session.project)",
        "dir": "\(session.dir)",
        "title": "\(session.title)",
        "status": "\(session.status)",
        "source": "\(session.source)",
        "resume_id": "\(session.resumeID ?? "")",
        "created_at": "2026-06-01T10:00:00Z",
        "updated_at": "2026-06-01T10:00:01Z"
      },
      "ws_url": "/api/sessions/\(session.id)/ws"
    }
    """
    return try AgentAPIClient.decoder.decode(CreateSessionResponse.self, from: Data(json.utf8))
}

private func makeSessionResponse(session: AgentSession, recentOutput: String?) throws -> SessionResponse {
    let escapedRecentOutput: String
    if let recentOutput {
        let data = try JSONEncoder().encode(recentOutput)
        escapedRecentOutput = String(decoding: data, as: UTF8.self)
    } else {
        escapedRecentOutput = "null"
    }
    let json = """
    {
      "session": {
        "id": "\(session.id)",
        "project_id": "\(session.projectID)",
        "project": "\(session.project)",
        "dir": "\(session.dir)",
        "title": "\(session.title)",
        "status": "\(session.status)",
        "source": "\(session.source)",
        "resume_id": "\(session.resumeID ?? "")",
        "created_at": "2026-06-01T10:00:00Z",
        "updated_at": "2026-06-01T10:00:01Z"
      },
      "recent_output": \(escapedRecentOutput)
    }
    """
    return try AgentAPIClient.decoder.decode(SessionResponse.self, from: Data(json.utf8))
}

private func makeSession(
    id: String,
    projectID: String,
    title: String,
    status: String,
    source: String,
    resumeID: String? = nil,
    updatedAt: Date = Date(timeIntervalSince1970: 2)
) -> AgentSession {
    AgentSession(
        id: id,
        projectID: projectID,
        project: projectID,
        dir: "/tmp/\(projectID)",
        title: title,
        status: status,
        source: source,
        resumeID: resumeID,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: updatedAt
    )
}
