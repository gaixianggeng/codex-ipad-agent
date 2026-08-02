import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testMultiRuntimePaginationDoesNotRestartExhaustedCodexWhileClaudeContinues() async throws {
        let project = AgentProject(id: "proj_codex_exhausted", name: "Codex Exhausted", path: "/tmp/codex-exhausted")
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
        let workspace = AgentWorkspace(project: project)

        let firstTask = Task { try await client.sessionsPage(workspace: workspace, cursor: nil, limit: 2) }
        let codexInitialize = try await waitForFakeAppServerRequest(codexTransport, method: "initialize")
        transportResponse(codexTransport, id: codexInitialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let codexFirstList = try await waitForFakeAppServerRequest(codexTransport, method: "thread/list", after: 1)
        transportResponse(codexTransport, id: codexFirstList.id, result: appServerThreadListResult([
            appServerThreadJSON(id: "codex-new", cwd: project.path, source: "appServer", updatedAt: 1_780_494_000)
        ], nextCursor: nil))

        let claudeInitialize = try await waitForFakeAppServerRequest(claudeTransport, method: "initialize")
        transportResponse(claudeTransport, id: claudeInitialize.id, result: #"{"userAgent":"fake-claude","platformFamily":"macos"}"#)
        let claudeFirstList = try await waitForFakeAppServerRequest(claudeTransport, method: "thread/list", after: 1)
        transportResponse(claudeTransport, id: claudeFirstList.id, result: appServerThreadListResult([
            appServerThreadJSON(id: "claude-new", cwd: project.path, source: "claude", updatedAt: 1_780_493_000),
            appServerThreadJSON(id: "claude-buffer", cwd: project.path, source: "claude", updatedAt: 1_780_492_000)
        ], nextCursor: "claude-next"))

        let firstPage = try await firstTask.value
        XCTAssertEqual(firstPage.sessions.map(\.id), ["codex-new", "claude-new"])
        let firstCursor = try XCTUnwrap(firstPage.nextCursor)
        let codexMessageCountAfterFirst = (await codexTransport.sentMessages()).count
        let claudeMessageCountAfterFirst = (await claudeTransport.sentMessages()).count

        let secondTask = Task {
            try await client.sessionsPage(workspace: workspace, cursor: firstCursor, limit: 2)
        }
        let claudeSecondList = try await waitForFakeAppServerRequest(
            claudeTransport,
            method: "thread/list",
            after: claudeMessageCountAfterFirst
        )
        XCTAssertEqual(claudeSecondList.params?.objectValue?["cursor"]?.stringValue, "claude-next")
        transportResponse(claudeTransport, id: claudeSecondList.id, result: appServerThreadListResult([
            appServerThreadJSON(id: "claude-old", cwd: project.path, source: "claude", updatedAt: 1_780_491_000)
        ], nextCursor: nil))

        let secondPage = try await secondTask.value
        let codexMessageCountAfterSecond = (await codexTransport.sentMessages()).count
        XCTAssertEqual(codexMessageCountAfterSecond, codexMessageCountAfterFirst, "已耗尽的 Codex 不得用 nil cursor 重拉首屏")
        XCTAssertEqual(secondPage.sessions.map(\.id), ["claude-buffer", "claude-old"])
        XCTAssertFalse(secondPage.hasMore)
        XCTAssertNil(secondPage.nextCursor)

        let allSessions = firstPage.sessions + secondPage.sessions
        XCTAssertEqual(Set(allSessions.map(\.id)).count, allSessions.count, "连续显示更多不能重复 session ID")
        XCTAssertEqual(
            allSessions.map(SessionIndexStore.orderingDate),
            allSessions.map(SessionIndexStore.orderingDate).sorted(by: >),
            "跨 Runtime 的连续分页必须保持稳定的全局更新时间递减"
        )
    }

    func testMultiRuntimeLegacyCompositeCursorTreatsMissingRuntimeAsExhausted() async throws {
        let project = AgentProject(id: "proj_legacy_cursor", name: "Legacy Cursor", path: "/tmp/legacy-cursor")
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
        // 旧版 String? 的 synthesized Encodable 会省略 nil key；这里模拟 Codex 已耗尽、
        // Claude 仍可继续的真实 legacy composite cursor。
        let legacyJSON = #"{"claude":"claude-next","codexBuffer":[],"claudeBuffer":[]}"#
        let legacyCursor = Data(legacyJSON.utf8).base64EncodedString()

        let pageTask = Task {
            try await client.sessionsPage(projectID: project.id, cursor: legacyCursor, limit: 2)
        }
        let claudeInitialize = try await waitForFakeAppServerRequest(claudeTransport, method: "initialize")
        transportResponse(
            claudeTransport,
            id: claudeInitialize.id,
            result: #"{"userAgent":"fake-claude","platformFamily":"macos"}"#
        )
        let claudeList = try await waitForFakeAppServerRequest(claudeTransport, method: "thread/list", after: 1)
        XCTAssertEqual(claudeList.params?.objectValue?["cursor"]?.stringValue, "claude-next")
        transportResponse(claudeTransport, id: claudeList.id, result: appServerThreadListResult([
            appServerThreadJSON(
                id: "claude-legacy-old",
                cwd: project.path,
                source: "claude",
                updatedAt: 1_780_491_000
            )
        ], nextCursor: nil))

        let page = try await pageTask.value
        let codexMessages = await codexTransport.sentMessages()
        XCTAssertTrue(codexMessages.isEmpty, "旧 composite 缺失 Codex key 时不得用 nil cursor 重拉首屏")
        XCTAssertEqual(page.sessions.map(\.id), ["claude-legacy-old"])
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.nextCursor)
    }

    func testMultiRuntimeUnavailableClaudeChannelReturnsWithoutDroppingContinuation() async throws {
        let project = AgentProject(
            id: "proj_claude_temporarily_unavailable",
            name: "Claude Temporarily Unavailable",
            path: "/tmp/claude-temporarily-unavailable"
        )
        let config = makeDirectAppServerConfig(project: project)
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
        // 模拟上一页仍有 Claude continuation，但下一次请求时 channel 已从 config 消失。
        // Codex key 缺失表示该侧已耗尽，双方 buffer 也为空。
        let legacyJSON = #"{"claude":"claude-next","codexBuffer":[],"claudeBuffer":[]}"#
        let cursor = Data(legacyJSON.utf8).base64EncodedString()

        let page = try await client.sessionsPage(projectID: project.id, cursor: cursor, limit: 2)

        XCTAssertTrue(page.sessions.isEmpty)
        XCTAssertTrue(page.hasMore, "临时不可用不能永久丢弃未消费的 Claude continuation")
        let nextCursor = try XCTUnwrap(page.nextCursor)
        let decodedCursor = try XCTUnwrap(Data(base64Encoded: nextCursor))
        XCTAssertTrue(String(decoding: decodedCursor, as: UTF8.self).contains("claude-next"))
        let codexMessages = await codexTransport.sentMessages()
        let claudeMessages = await claudeTransport.sentMessages()
        XCTAssertTrue(codexMessages.isEmpty)
        XCTAssertTrue(claudeMessages.isEmpty)
    }

    func testMultiRuntimeUnavailableClaudeDefersCodexBufferUntilChannelRecovers() async throws {
        let project = AgentProject(
            id: "proj_claude_unavailable_buffered_codex",
            name: "Claude Unavailable Buffered Codex",
            path: "/tmp/claude-unavailable-buffered-codex"
        )
        let codexBuffered = makeSession(
            id: "codex-buffered-old",
            projectID: project.id,
            title: "Codex buffered",
            status: "history",
            source: "codex",
            updatedAt: Date(timeIntervalSince1970: 1_780_491_000)
        )
        let sessionEncoder = JSONEncoder()
        // Composite cursor 的生产编码器使用 ISO-8601；测试也必须沿用同一日期格式，
        // 否则整个 payload 会被兼容逻辑当成 Codex 的 opaque cursor。
        sessionEncoder.dateEncodingStrategy = .iso8601
        let encodedSession = try JSONSerialization.jsonObject(
            with: sessionEncoder.encode(codexBuffered)
        )
        let legacyPayload: [String: Any] = [
            "claude": "claude-next",
            "codexBuffer": [encodedSession],
            "claudeBuffer": [Any]()
        ]
        let legacyCursor = try JSONSerialization.data(withJSONObject: legacyPayload).base64EncodedString()
        let unavailableConfig = makeDirectAppServerConfig(project: project)
        let unavailableCodexTransport = FakeCodexAppServerTransport()
        let unavailableClaudeTransport = FakeCodexAppServerTransport()
        let unavailableClient = MultiRuntimeSessionAPIClient(
            codexRuntime: CodexAppServerSessionRuntime(
                endpoint: "http://127.0.0.1:8787",
                token: "outer-token",
                runtimeProvider: "codex",
                transportFactory: { unavailableCodexTransport },
                configProvider: { unavailableConfig }
            ),
            claudeRuntime: CodexAppServerSessionRuntime(
                endpoint: "http://127.0.0.1:8787",
                token: "outer-token",
                runtimeProvider: "claude",
                transportFactory: { unavailableClaudeTransport },
                configProvider: { unavailableConfig }
            )
        )

        let deferredPage = try await unavailableClient.sessionsPage(
            projectID: project.id,
            cursor: legacyCursor,
            limit: 2
        )

        XCTAssertTrue(deferredPage.sessions.isEmpty, "未知 Claude head 前不能越序输出较旧 Codex buffer")
        XCTAssertTrue(deferredPage.hasMore)
        let deferredCursor = try XCTUnwrap(deferredPage.nextCursor)
        let decodedDeferredCursor = try XCTUnwrap(Data(base64Encoded: deferredCursor))
        let decodedDeferredText = String(decoding: decodedDeferredCursor, as: UTF8.self)
        XCTAssertTrue(decodedDeferredText.contains("claude-next"))
        XCTAssertTrue(decodedDeferredText.contains(codexBuffered.id))
        let unavailableCodexMessages = await unavailableCodexTransport.sentMessages()
        let unavailableClaudeMessages = await unavailableClaudeTransport.sentMessages()
        XCTAssertTrue(unavailableCodexMessages.isEmpty)
        XCTAssertTrue(unavailableClaudeMessages.isEmpty)

        let recoveredConfig = makeDirectAppServerConfig(
            project: project,
            channels: [makeClaudeChannelMetadata()]
        )
        let recoveredCodexTransport = FakeCodexAppServerTransport()
        let recoveredClaudeTransport = FakeCodexAppServerTransport()
        let recoveredClient = MultiRuntimeSessionAPIClient(
            codexRuntime: CodexAppServerSessionRuntime(
                endpoint: "http://127.0.0.1:8787",
                token: "outer-token",
                runtimeProvider: "codex",
                transportFactory: { recoveredCodexTransport },
                configProvider: { recoveredConfig }
            ),
            claudeRuntime: CodexAppServerSessionRuntime(
                endpoint: "http://127.0.0.1:8787",
                token: "outer-token",
                runtimeProvider: "claude",
                transportFactory: { recoveredClaudeTransport },
                configProvider: { recoveredConfig }
            )
        )
        let recoveredTask = Task {
            try await recoveredClient.sessionsPage(
                projectID: project.id,
                cursor: deferredCursor,
                limit: 2
            )
        }
        let claudeInitialize = try await waitForFakeAppServerRequest(
            recoveredClaudeTransport,
            method: "initialize"
        )
        transportResponse(
            recoveredClaudeTransport,
            id: claudeInitialize.id,
            result: #"{"userAgent":"fake-claude","platformFamily":"macos"}"#
        )
        let claudeList = try await waitForFakeAppServerRequest(
            recoveredClaudeTransport,
            method: "thread/list",
            after: 1
        )
        XCTAssertEqual(claudeList.params?.objectValue?["cursor"]?.stringValue, "claude-next")
        transportResponse(
            recoveredClaudeTransport,
            id: claudeList.id,
            result: appServerThreadListResult([
                appServerThreadJSON(
                    id: "claude-recovered-new",
                    cwd: project.path,
                    source: "claude",
                    updatedAt: 1_780_492_000
                )
            ], nextCursor: nil)
        )

        let recoveredPage = try await recoveredTask.value

        XCTAssertEqual(recoveredPage.sessions.map(\.id), ["claude-recovered-new", codexBuffered.id])
        XCTAssertFalse(recoveredPage.hasMore)
        XCTAssertNil(recoveredPage.nextCursor)
        let recoveredCodexMessages = await recoveredCodexTransport.sentMessages()
        XCTAssertTrue(recoveredCodexMessages.isEmpty)
    }

    func testMultiRuntimePreservesBase64JSONOpaqueCodexCursor() async throws {
        let project = AgentProject(id: "proj_opaque_cursor", name: "Opaque Cursor", path: "/tmp/opaque-cursor")
        let config = makeDirectAppServerConfig(project: project)
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
        let opaqueCursor = Data(#"{"after":"opaque-server-value"}"#.utf8).base64EncodedString()

        let pageTask = Task {
            try await client.sessionsPage(projectID: project.id, cursor: opaqueCursor, limit: 2)
        }
        let initialize = try await waitForFakeAppServerRequest(codexTransport, method: "initialize")
        transportResponse(
            codexTransport,
            id: initialize.id,
            result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#
        )
        let list = try await waitForFakeAppServerRequest(codexTransport, method: "thread/list", after: 1)
        XCTAssertEqual(list.params?.objectValue?["cursor"]?.stringValue, opaqueCursor)
        transportResponse(codexTransport, id: list.id, result: appServerThreadListResult([
            appServerThreadJSON(
                id: "codex-opaque-old",
                cwd: project.path,
                source: "appServer",
                updatedAt: 1_780_491_000
            )
        ], nextCursor: nil))

        let page = try await pageTask.value
        let claudeMessages = await claudeTransport.sentMessages()
        XCTAssertTrue(claudeMessages.isEmpty)
        XCTAssertEqual(page.sessions.map(\.id), ["codex-opaque-old"])
        XCTAssertFalse(page.hasMore)
    }

    func testMultiRuntimePaginationDoesNotRestartExhaustedClaudeWhileCodexContinues() async throws {
        let project = AgentProject(id: "proj_claude_exhausted", name: "Claude Exhausted", path: "/tmp/claude-exhausted")
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

        let firstTask = Task { try await client.sessionsPage(projectID: project.id, cursor: nil, limit: 2) }
        let codexInitialize = try await waitForFakeAppServerRequest(codexTransport, method: "initialize")
        transportResponse(codexTransport, id: codexInitialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let codexFirstList = try await waitForFakeAppServerRequest(codexTransport, method: "thread/list", after: 1)
        transportResponse(codexTransport, id: codexFirstList.id, result: appServerThreadListResult([
            appServerThreadJSON(id: "codex-new", cwd: project.path, source: "appServer", updatedAt: 1_780_494_000),
            appServerThreadJSON(id: "codex-buffer", cwd: project.path, source: "appServer", updatedAt: 1_780_492_000)
        ], nextCursor: "codex-next"))

        let claudeInitialize = try await waitForFakeAppServerRequest(claudeTransport, method: "initialize")
        transportResponse(claudeTransport, id: claudeInitialize.id, result: #"{"userAgent":"fake-claude","platformFamily":"macos"}"#)
        let claudeFirstList = try await waitForFakeAppServerRequest(claudeTransport, method: "thread/list", after: 1)
        transportResponse(claudeTransport, id: claudeFirstList.id, result: appServerThreadListResult([
            appServerThreadJSON(id: "claude-new", cwd: project.path, source: "claude", updatedAt: 1_780_493_000)
        ], nextCursor: nil))

        let firstPage = try await firstTask.value
        XCTAssertEqual(firstPage.sessions.map(\.id), ["codex-new", "claude-new"])
        let firstCursor = try XCTUnwrap(firstPage.nextCursor)
        let codexMessageCountAfterFirst = (await codexTransport.sentMessages()).count
        let claudeMessageCountAfterFirst = (await claudeTransport.sentMessages()).count

        let secondTask = Task {
            try await client.sessionsPage(projectID: project.id, cursor: firstCursor, limit: 2)
        }
        let codexSecondList = try await waitForFakeAppServerRequest(
            codexTransport,
            method: "thread/list",
            after: codexMessageCountAfterFirst
        )
        XCTAssertEqual(codexSecondList.params?.objectValue?["cursor"]?.stringValue, "codex-next")
        transportResponse(codexTransport, id: codexSecondList.id, result: appServerThreadListResult([
            appServerThreadJSON(id: "codex-old", cwd: project.path, source: "appServer", updatedAt: 1_780_491_000)
        ], nextCursor: nil))

        let secondPage = try await secondTask.value
        let claudeMessageCountAfterSecond = (await claudeTransport.sentMessages()).count
        XCTAssertEqual(claudeMessageCountAfterSecond, claudeMessageCountAfterFirst, "已耗尽的 Claude 不得用 nil cursor 重拉首屏")
        XCTAssertEqual(secondPage.sessions.map(\.id), ["codex-buffer", "codex-old"])
        XCTAssertFalse(secondPage.hasMore)
        XCTAssertNil(secondPage.nextCursor)

        let allSessions = firstPage.sessions + secondPage.sessions
        XCTAssertEqual(Set(allSessions.map(\.id)).count, allSessions.count)
        XCTAssertEqual(
            allSessions.map(SessionIndexStore.orderingDate),
            allSessions.map(SessionIndexStore.orderingDate).sorted(by: >)
        )
    }

    func testMultiRuntimePaginationDrainsBufferAfterBothRuntimesAreExhausted() async throws {
        let project = AgentProject(id: "proj_both_exhausted", name: "Both Exhausted", path: "/tmp/both-exhausted")
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

        let firstTask = Task { try await client.sessionsPage(projectID: project.id, cursor: nil, limit: 2) }
        let codexInitialize = try await waitForFakeAppServerRequest(codexTransport, method: "initialize")
        transportResponse(codexTransport, id: codexInitialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let codexFirstList = try await waitForFakeAppServerRequest(codexTransport, method: "thread/list", after: 1)
        transportResponse(codexTransport, id: codexFirstList.id, result: appServerThreadListResult([
            appServerThreadJSON(id: "codex-new", cwd: project.path, source: "appServer", updatedAt: 1_780_494_000),
            appServerThreadJSON(id: "codex-buffer", cwd: project.path, source: "appServer", updatedAt: 1_780_492_000)
        ], nextCursor: nil))

        let claudeInitialize = try await waitForFakeAppServerRequest(claudeTransport, method: "initialize")
        transportResponse(claudeTransport, id: claudeInitialize.id, result: #"{"userAgent":"fake-claude","platformFamily":"macos"}"#)
        let claudeFirstList = try await waitForFakeAppServerRequest(claudeTransport, method: "thread/list", after: 1)
        transportResponse(claudeTransport, id: claudeFirstList.id, result: appServerThreadListResult([
            appServerThreadJSON(id: "claude-new", cwd: project.path, source: "claude", updatedAt: 1_780_493_000)
        ], nextCursor: nil))

        let firstPage = try await firstTask.value
        XCTAssertEqual(firstPage.sessions.map(\.id), ["codex-new", "claude-new"])
        XCTAssertTrue(firstPage.hasMore, "Runtime 已耗尽时仍须先排空 composite cursor 里的剩余 buffer")
        let firstCursor = try XCTUnwrap(firstPage.nextCursor)
        let codexMessageCountAfterFirst = (await codexTransport.sentMessages()).count
        let claudeMessageCountAfterFirst = (await claudeTransport.sentMessages()).count

        let secondTask = Task {
            try await client.sessionsPage(projectID: project.id, cursor: firstCursor, limit: 2)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let claudeMessagesWhileDrainingBuffer = await claudeTransport.sentMessages()
        if claudeMessagesWhileDrainingBuffer.count > claudeMessageCountAfterFirst {
            let repeatedClaudeFirstList = try await waitForFakeAppServerRequest(
                claudeTransport,
                method: "thread/list",
                after: claudeMessageCountAfterFirst
            )
            transportResponse(claudeTransport, id: repeatedClaudeFirstList.id, result: appServerThreadListResult([
                appServerThreadJSON(id: "claude-new", cwd: project.path, source: "claude", updatedAt: 1_780_493_000)
            ], nextCursor: nil))
        }

        let secondPage = try await secondTask.value
        let codexMessageCountAfterSecond = (await codexTransport.sentMessages()).count
        let claudeMessageCountAfterSecond = (await claudeTransport.sentMessages()).count
        XCTAssertEqual(codexMessageCountAfterSecond, codexMessageCountAfterFirst)
        XCTAssertEqual(claudeMessageCountAfterSecond, claudeMessageCountAfterFirst)
        XCTAssertEqual(secondPage.sessions.map(\.id), ["codex-buffer"])
        XCTAssertFalse(secondPage.hasMore)
        XCTAssertNil(secondPage.nextCursor, "双方 exhausted 且 buffer 排空后必须隐藏“显示更多”")

        let allSessions = firstPage.sessions + secondPage.sessions
        XCTAssertEqual(Set(allSessions.map(\.id)).count, allSessions.count)
        XCTAssertEqual(
            allSessions.map(SessionIndexStore.orderingDate),
            allSessions.map(SessionIndexStore.orderingDate).sorted(by: >)
        )
    }

    func testMultiRuntimePaginationSkipsEmptyPagesFromBothRuntimesWhileCursorsContinue() async throws {
        let project = AgentProject(id: "proj_both_empty_pages", name: "Both Empty Pages", path: "/tmp/both-empty-pages")
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

        let pageTask = Task { try await client.sessionsPage(projectID: project.id, cursor: nil, limit: 2) }
        let codexInitialize = try await waitForFakeAppServerRequest(codexTransport, method: "initialize")
        transportResponse(codexTransport, id: codexInitialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let codexFirstList = try await waitForFakeAppServerRequest(codexTransport, method: "thread/list", after: 1)
        let codexFirstMessageCount = (await codexTransport.sentMessages()).count
        transportResponse(codexTransport, id: codexFirstList.id, result: appServerThreadListResult([], nextCursor: "codex-next"))

        let codexSecondList = try await waitForFakeAppServerRequest(
            codexTransport,
            method: "thread/list",
            after: codexFirstMessageCount
        )
        XCTAssertEqual(codexSecondList.params?.objectValue?["cursor"]?.stringValue, "codex-next")
        transportResponse(codexTransport, id: codexSecondList.id, result: appServerThreadListResult([
            appServerThreadJSON(id: "codex-visible", cwd: project.path, source: "appServer", updatedAt: 1_780_494_000)
        ], nextCursor: nil))

        let claudeInitialize = try await waitForFakeAppServerRequest(claudeTransport, method: "initialize")
        transportResponse(claudeTransport, id: claudeInitialize.id, result: #"{"userAgent":"fake-claude","platformFamily":"macos"}"#)
        let claudeFirstList = try await waitForFakeAppServerRequest(claudeTransport, method: "thread/list", after: 1)
        let claudeFirstMessageCount = (await claudeTransport.sentMessages()).count
        transportResponse(claudeTransport, id: claudeFirstList.id, result: appServerThreadListResult([], nextCursor: "claude-next"))

        let claudeSecondList = try await waitForFakeAppServerRequest(
            claudeTransport,
            method: "thread/list",
            after: claudeFirstMessageCount
        )
        XCTAssertEqual(claudeSecondList.params?.objectValue?["cursor"]?.stringValue, "claude-next")
        transportResponse(claudeTransport, id: claudeSecondList.id, result: appServerThreadListResult([
            appServerThreadJSON(id: "claude-visible", cwd: project.path, source: "claude", updatedAt: 1_780_493_000)
        ], nextCursor: nil))

        let page = try await pageTask.value
        XCTAssertEqual(page.sessions.map(\.id), ["codex-visible", "claude-visible"])
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.nextCursor)
    }

    func testMultiRuntimePaginationSkipsSingleRuntimeEmptyPageWhileCursorContinues() async throws {
        let project = AgentProject(id: "proj_single_empty_page", name: "Single Empty Page", path: "/tmp/single-empty-page")
        let config = makeDirectAppServerConfig(project: project)
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

        let pageTask = Task { try await client.sessionsPage(projectID: project.id, cursor: nil, limit: 2) }
        let initialize = try await waitForFakeAppServerRequest(codexTransport, method: "initialize")
        transportResponse(codexTransport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let firstList = try await waitForFakeAppServerRequest(codexTransport, method: "thread/list", after: 1)
        let firstMessageCount = (await codexTransport.sentMessages()).count
        transportResponse(codexTransport, id: firstList.id, result: appServerThreadListResult([], nextCursor: "codex-next"))

        let secondList = try await waitForFakeAppServerRequest(
            codexTransport,
            method: "thread/list",
            after: firstMessageCount
        )
        XCTAssertEqual(secondList.params?.objectValue?["cursor"]?.stringValue, "codex-next")
        transportResponse(codexTransport, id: secondList.id, result: appServerThreadListResult([
            appServerThreadJSON(id: "codex-after-empty", cwd: project.path, source: "appServer", updatedAt: 1_780_494_000)
        ], nextCursor: nil))

        let page = try await pageTask.value
        XCTAssertEqual(page.sessions.map(\.id), ["codex-after-empty"])
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.nextCursor)
        let claudeMessages = await claudeTransport.sentMessages()
        XCTAssertTrue(claudeMessages.isEmpty)
    }

    func testMultiRuntimePaginationStopsWhenEmptyPageRepeatsCursor() async throws {
        let project = AgentProject(id: "proj_repeated_empty_cursor", name: "Repeated Empty Cursor", path: "/tmp/repeated-empty-cursor")
        let config = makeDirectAppServerConfig(project: project)
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

        let pageTask = Task { try await client.sessionsPage(projectID: project.id, cursor: nil, limit: 2) }
        let initialize = try await waitForFakeAppServerRequest(codexTransport, method: "initialize")
        transportResponse(codexTransport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let firstList = try await waitForFakeAppServerRequest(codexTransport, method: "thread/list", after: 1)
        let firstMessageCount = (await codexTransport.sentMessages()).count
        transportResponse(codexTransport, id: firstList.id, result: appServerThreadListResult([], nextCursor: "repeat-cursor"))

        let repeatedList = try await waitForFakeAppServerRequest(
            codexTransport,
            method: "thread/list",
            after: firstMessageCount
        )
        XCTAssertEqual(repeatedList.params?.objectValue?["cursor"]?.stringValue, "repeat-cursor")
        transportResponse(codexTransport, id: repeatedList.id, result: appServerThreadListResult([], nextCursor: "repeat-cursor"))

        let page = try await pageTask.value
        XCTAssertTrue(page.sessions.isEmpty)
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.nextCursor)
        let listRequestCount = (await codexTransport.sentMessages()).compactMap { message in
            try? decodeAppServerRequest(message)
        }.filter { $0.method == "thread/list" }.count
        XCTAssertEqual(listRequestCount, 2, "重复 cursor 只能重试一次，不能形成空页死循环")
        let claudeMessages = await claudeTransport.sentMessages()
        XCTAssertTrue(claudeMessages.isEmpty)
    }

    func testMultiRuntimePaginationBoundsAdvancingEmptyPagesAndPreservesContinuation() async throws {
        let project = AgentProject(id: "proj_empty_page_budget", name: "Empty Page Budget", path: "/tmp/empty-page-budget")
        let config = makeDirectAppServerConfig(project: project)
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

        let firstPageTask = Task { try await client.sessionsPage(projectID: project.id, cursor: nil, limit: 2) }
        let initialize = try await waitForFakeAppServerRequest(codexTransport, method: "initialize")
        transportResponse(codexTransport, id: initialize.id, result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#)
        let firstList = try await waitForFakeAppServerRequest(codexTransport, method: "thread/list", after: 1)
        var messageCount = (await codexTransport.sentMessages()).count
        transportResponse(codexTransport, id: firstList.id, result: appServerThreadListResult([], nextCursor: "empty-1"))

        // 初始页之外最多跨过 8 个空 continuation 页；第 9 个 cursor 必须留给下一次调用。
        for index in 1...8 {
            let list = try await waitForFakeAppServerRequest(
                codexTransport,
                method: "thread/list",
                after: messageCount
            )
            XCTAssertEqual(list.params?.objectValue?["cursor"]?.stringValue, "empty-\(index)")
            messageCount = (await codexTransport.sentMessages()).count
            transportResponse(
                codexTransport,
                id: list.id,
                result: appServerThreadListResult([], nextCursor: "empty-\(index + 1)")
            )
        }

        let firstPage = try await firstPageTask.value
        XCTAssertTrue(firstPage.sessions.isEmpty)
        XCTAssertTrue(firstPage.hasMore)
        let continuation = try XCTUnwrap(firstPage.nextCursor)
        let firstCallListCount = (await codexTransport.sentMessages()).compactMap { message in
            try? decodeAppServerRequest(message)
        }.filter { $0.method == "thread/list" }.count
        XCTAssertEqual(firstCallListCount, 9, "单次调用只能包含初始页和 8 个空 continuation 页")

        let secondPageTask = Task {
            try await client.sessionsPage(projectID: project.id, cursor: continuation, limit: 2)
        }
        let resumedList = try await waitForFakeAppServerRequest(
            codexTransport,
            method: "thread/list",
            after: messageCount
        )
        XCTAssertEqual(resumedList.params?.objectValue?["cursor"]?.stringValue, "empty-9")
        transportResponse(codexTransport, id: resumedList.id, result: appServerThreadListResult([
            appServerThreadJSON(id: "codex-after-budget", cwd: project.path, source: "appServer", updatedAt: 1_780_494_000)
        ], nextCursor: nil))

        let secondPage = try await secondPageTask.value
        XCTAssertEqual(secondPage.sessions.map(\.id), ["codex-after-budget"])
        XCTAssertFalse(secondPage.hasMore)
        XCTAssertNil(secondPage.nextCursor)
    }

}
