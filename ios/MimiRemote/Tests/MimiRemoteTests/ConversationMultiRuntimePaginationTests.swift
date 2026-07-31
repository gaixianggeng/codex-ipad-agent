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
        // 旧实现把“Codex 已耗尽”重新解码成 nil cursor，会在这里重拉 Codex 首屏。
        try await Task.sleep(nanoseconds: 50_000_000)
        let codexMessagesWhileLoadingSecond = await codexTransport.sentMessages()
        if codexMessagesWhileLoadingSecond.count > codexMessageCountAfterFirst {
            let repeatedCodexFirstList = try await waitForFakeAppServerRequest(
                codexTransport,
                method: "thread/list",
                after: codexMessageCountAfterFirst
            )
            transportResponse(codexTransport, id: repeatedCodexFirstList.id, result: appServerThreadListResult([
                appServerThreadJSON(id: "codex-new", cwd: project.path, source: "appServer", updatedAt: 1_780_494_000)
            ], nextCursor: nil))
        }
        let secondPage = try await secondTask.value
        let codexMessageCountAfterSecond = (await codexTransport.sentMessages()).count
        let claudeMessageCountAfterSecond = (await claudeTransport.sentMessages()).count

        XCTAssertEqual(codexMessageCountAfterSecond, codexMessageCountAfterFirst, "已耗尽的 Codex 不得用 nil cursor 重拉首屏")
        XCTAssertEqual(claudeMessageCountAfterSecond, claudeMessageCountAfterFirst, "Claude buffer 未消费完时不应提前请求下一页")
        XCTAssertEqual(secondPage.sessions.map(\.id), ["claude-buffer"])
        XCTAssertTrue(secondPage.hasMore)
        let secondCursor = try XCTUnwrap(secondPage.nextCursor)

        let thirdTask = Task {
            try await client.sessionsPage(workspace: workspace, cursor: secondCursor, limit: 2)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let codexMessagesWhileLoadingThird = await codexTransport.sentMessages()
        if codexMessagesWhileLoadingThird.count > codexMessageCountAfterSecond {
            let repeatedCodexFirstList = try await waitForFakeAppServerRequest(
                codexTransport,
                method: "thread/list",
                after: codexMessageCountAfterSecond
            )
            transportResponse(codexTransport, id: repeatedCodexFirstList.id, result: appServerThreadListResult([
                appServerThreadJSON(id: "codex-new", cwd: project.path, source: "appServer", updatedAt: 1_780_494_000)
            ], nextCursor: nil))
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

        let thirdPage = try await thirdTask.value
        let codexMessageCountAfterThird = (await codexTransport.sentMessages()).count
        XCTAssertEqual(codexMessageCountAfterThird, codexMessageCountAfterFirst)
        XCTAssertEqual(thirdPage.sessions.map(\.id), ["claude-old"])
        XCTAssertFalse(thirdPage.hasMore)
        XCTAssertNil(thirdPage.nextCursor)

        let allSessions = firstPage.sessions + secondPage.sessions + thirdPage.sessions
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
        try await Task.sleep(nanoseconds: 50_000_000)
        let claudeMessagesWhileLoadingSecond = await claudeTransport.sentMessages()
        if claudeMessagesWhileLoadingSecond.count > claudeMessageCountAfterFirst {
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

        XCTAssertEqual(codexMessageCountAfterSecond, codexMessageCountAfterFirst, "Codex buffer 未消费完时不应提前请求下一页")
        XCTAssertEqual(claudeMessageCountAfterSecond, claudeMessageCountAfterFirst, "已耗尽的 Claude 不得用 nil cursor 重拉首屏")
        XCTAssertEqual(secondPage.sessions.map(\.id), ["codex-buffer"])
        XCTAssertTrue(secondPage.hasMore)
        let secondCursor = try XCTUnwrap(secondPage.nextCursor)

        let thirdTask = Task {
            try await client.sessionsPage(projectID: project.id, cursor: secondCursor, limit: 2)
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
        try await Task.sleep(nanoseconds: 50_000_000)
        let claudeMessagesWhileLoadingThird = await claudeTransport.sentMessages()
        if claudeMessagesWhileLoadingThird.count > claudeMessageCountAfterSecond {
            let repeatedClaudeFirstList = try await waitForFakeAppServerRequest(
                claudeTransport,
                method: "thread/list",
                after: claudeMessageCountAfterSecond
            )
            transportResponse(claudeTransport, id: repeatedClaudeFirstList.id, result: appServerThreadListResult([
                appServerThreadJSON(id: "claude-new", cwd: project.path, source: "claude", updatedAt: 1_780_493_000)
            ], nextCursor: nil))
        }

        let thirdPage = try await thirdTask.value
        let claudeMessageCountAfterThird = (await claudeTransport.sentMessages()).count
        XCTAssertEqual(claudeMessageCountAfterThird, claudeMessageCountAfterFirst)
        XCTAssertEqual(thirdPage.sessions.map(\.id), ["codex-old"])
        XCTAssertFalse(thirdPage.hasMore)
        XCTAssertNil(thirdPage.nextCursor)

        let allSessions = firstPage.sessions + secondPage.sessions + thirdPage.sessions
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
}
