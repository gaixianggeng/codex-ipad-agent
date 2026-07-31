import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testChildOwnedHistoryTurnsFiltersOnlyProvablyInheritedSubagentPrefix() async {
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test"
        )
        let thread: [String: CodexAppServerJSONValue] = [
            "id": .string("child-thread"),
            "parentThreadId": .string("parent-thread"),
            "createdAt": .int(200),
            "threadSource": .string("subagent"),
        ]
        let turns: [[String: CodexAppServerJSONValue]] = [
            ["id": .string("inherited-turn"), "startedAt": .int(100)],
            ["id": .string("same-second-turn"), "startedAt": .int(200)],
            ["id": .string("missing-time-turn")],
            ["id": .string("child-turn"), "startedAt": .int(201)],
        ]

        let filtered = await runtime.childOwnedHistoryTurns(in: thread, turns: turns)
        let sourceOnlyFiltered = await runtime.childOwnedHistoryTurns(
            in: [
                "id": .string("source-only-child"),
                "createdAt": .int(200),
                "source": .object(["subAgent": .object(["thread_spawn": .object([:])])]),
            ],
            turns: turns
        )

        XCTAssertEqual(
            filtered.compactMap { $0["id"]?.stringValue },
            ["same-second-turn", "missing-time-turn", "child-turn"]
        )
        XCTAssertEqual(
            sourceOnlyFiltered.compactMap { $0["id"]?.stringValue },
            ["same-second-turn", "missing-time-turn", "child-turn"]
        )
    }

    func testChildOwnedHistoryTurnsFailsOpenForOrdinaryForkAndIncompleteMetadata() async {
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test"
        )
        let preCreationTurn: [[String: CodexAppServerJSONValue]] = [
            ["id": .string("pre-creation-turn"), "startedAt": .int(100)],
        ]
        let ordinaryFork: [String: CodexAppServerJSONValue] = [
            "id": .string("ordinary-fork"),
            "forkedFromId": .string("root-thread"),
            "createdAt": .int(200),
            "source": .string("vscode"),
            "threadSource": .string("user"),
        ]
        let childWithoutCreatedAt: [String: CodexAppServerJSONValue] = [
            "id": .string("child-without-created-at"),
            "parentThreadId": .string("parent-thread"),
            "threadSource": .string("subagent"),
        ]

        let ordinaryForkResult = await runtime.childOwnedHistoryTurns(
            in: ordinaryFork,
            turns: preCreationTurn
        )
        let missingMetadataResult = await runtime.childOwnedHistoryTurns(
            in: childWithoutCreatedAt,
            turns: preCreationTurn
        )

        XCTAssertEqual(ordinaryForkResult.compactMap { $0["id"]?.stringValue }, ["pre-creation-turn"])
        XCTAssertEqual(missingMetadataResult.compactMap { $0["id"]?.stringValue }, ["pre-creation-turn"])
    }

    func testFullThreadReadHidesInheritedSubagentPrefix() async throws {
        let project = AgentProject(id: "subagent-full", name: "Subagent Full", path: "/tmp/subagent-full")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let pageTask = Task {
            try await client.messagesPage(sessionID: "child-thread", before: nil, limit: 50)
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#
        )
        let read = try await waitForFakeAppServerRequest(transport, method: "thread/read")
        XCTAssertEqual(read.params?.objectValue?["threadId"]?.stringValue, "child-thread")
        XCTAssertEqual(read.params?.objectValue?["includeTurns"]?.boolValue, true)
        transportResponse(
            transport,
            id: read.id,
            result: #"{"thread":{"id":"child-thread","sessionId":"child-thread","parentThreadId":"parent-thread","forkedFromId":"parent-thread","preview":"child","ephemeral":false,"modelProvider":"openai","createdAt":200,"updatedAt":220,"status":{"type":"idle"},"path":null,"cwd":"/tmp/subagent-full","cliVersion":"0.0.0","source":{"subAgent":{"thread_spawn":{}}},"threadSource":"subagent","agentNickname":"Curie","name":null,"turns":[{"id":"inherited-turn","startedAt":100,"status":"interrupted","items":[{"type":"userMessage","id":"parent-user","content":[{"type":"text","text":"parent request"}]},{"type":"agentMessage","id":"parent-commentary","text":"parent commentary","phase":"commentary"},{"type":"commandExecution","id":"parent-command","command":"echo parent","cwd":"/tmp","status":"completed","commandActions":[]}]},{"id":"child-turn","startedAt":201,"completedAt":220,"status":"completed","items":[{"type":"agentMessage","id":"child-result","text":"child result","phase":"final_answer"}]}]}}"#
        )

        let page = try await pageTask.value

        XCTAssertEqual(page.messages.map(\.content), ["child result"])
        XCTAssertFalse(page.context?.tasks.contains { $0.id == "parent-command" } == true)
    }

    func testPagedTurnHistoryUsesCachedParentMetadataToHideInheritedPrefix() async throws {
        let project = AgentProject(id: "subagent-paged", name: "Subagent Paged", path: "/tmp/subagent-paged")
        let transport = FakeCodexAppServerTransport()
        let allowedMethods = [
            "initialize",
            "initialized",
            "thread/read",
            "thread/turns/list",
        ]
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(project: project, allowedMethods: allowedMethods)
            }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let hydrateTask = Task {
            try await client.session(id: "child-thread", afterSeq: nil)
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#
        )
        let metadataRead = try await waitForFakeAppServerRequest(transport, method: "thread/read")
        XCTAssertEqual(metadataRead.params?.objectValue?["includeTurns"]?.boolValue, false)
        transportResponse(
            transport,
            id: metadataRead.id,
            result: #"{"thread":{"id":"child-thread","sessionId":"child-thread","parentThreadId":"parent-thread","forkedFromId":"parent-thread","preview":"child","ephemeral":false,"modelProvider":"openai","createdAt":200,"updatedAt":220,"status":{"type":"idle"},"path":null,"cwd":"/tmp/subagent-paged","cliVersion":"0.0.0","source":{"subAgent":{"thread_spawn":{}}},"threadSource":"subagent","agentNickname":"Curie","name":null,"turns":[]}}"#
        )
        _ = try await hydrateTask.value

        let sentBeforePage = await transport.sentMessages().count
        let pageTask = Task {
            try await client.messagesPage(sessionID: "child-thread", before: nil, limit: 50)
        }
        let turnsRequest = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/turns/list",
            after: sentBeforePage
        )
        transportResponse(
            transport,
            id: turnsRequest.id,
            result: #"{"data":[{"id":"child-turn","startedAt":201,"completedAt":220,"status":"completed","items":[{"type":"agentMessage","id":"child-result","text":"child result","phase":"final_answer"}]},{"id":"inherited-turn","startedAt":100,"status":"interrupted","items":[{"type":"userMessage","id":"parent-user","content":[{"type":"text","text":"parent request"}]},{"type":"agentMessage","id":"parent-commentary","text":"parent commentary","phase":"commentary"}]}],"nextCursor":null}"#
        )

        let page = try await pageTask.value
        let requests = await transport.sentMessages().compactMap { try? decodeAppServerRequest($0) }

        XCTAssertEqual(page.messages.map(\.content), ["child result"])
        XCTAssertEqual(requests.filter { $0.method == "thread/read" }.count, 1)
        XCTAssertEqual(requests.filter { $0.method == "thread/turns/list" }.count, 1)
    }
}
