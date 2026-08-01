import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testLateThreadUnsubscribeCannotOverrideNewerSubscriptionLease() async throws {
        let project = AgentProject(
            id: "proj_unsubscribe_lease",
            name: "Unsubscribe Lease",
            path: "/tmp/unsubscribe-lease"
        )
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: {
                makeDirectAppServerConfig(
                    project: project,
                    allowedMethods: [
                        "initialize",
                        "initialized",
                        "thread/list",
                        "thread/resume",
                        "thread/unsubscribe"
                    ]
                )
            }
        )
        let threadID = "thr_unsubscribe_lease"
        let thread = #"{"id":"thr_unsubscribe_lease","sessionId":"thr_unsubscribe_lease","preview":"订阅代次","ephemeral":false,"modelProvider":"openai","createdAt":1780490900,"updatedAt":1780490901,"status":{"type":"idle"},"path":null,"cwd":"/tmp/unsubscribe-lease","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"订阅代次","turns":[]}"#

        let pageTask = Task {
            try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#
        )
        let list = try await waitForFakeAppServerRequest(transport, method: "thread/list", after: 1)
        transportResponse(transport, id: list.id, result: #"{"data":[\#(thread)],"nextCursor":null}"#)
        _ = try await pageTask.value

        let initialConnect = Task {
            try await runtime.connectForEvents(sessionID: threadID)
        }
        let initialResume = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/resume",
            after: 2
        )
        transportResponse(transport, id: initialResume.id, result: #"{"thread":\#(thread)}"#)
        try await initialConnect.value

        let unsubscribe = Task {
            try await runtime.unsubscribeThread(threadID: threadID)
        }
        let unsubscribeRequest = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/unsubscribe",
            after: 3
        )
        let messagesAfterUnsubscribe = await transport.sentMessages().count

        // 旧退订仍在等待响应时重新进入同一会话；新 lease 必须真的发送 resume。
        let reopen = Task {
            try await runtime.connectForEvents(sessionID: threadID)
        }
        let reopenResume = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/resume",
            after: messagesAfterUnsubscribe
        )
        transportResponse(transport, id: reopenResume.id, result: #"{"thread":\#(thread)}"#)
        try await reopen.value

        // 让旧 unsubscribe 最后返回，复现“迟到退订覆盖新订阅”。runtime 应按当前
        // generation 再确认一次 resume，使服务端最终状态与最新页面一致。
        let messagesBeforeLateResponse = await transport.sentMessages().count
        transportResponse(
            transport,
            id: unsubscribeRequest.id,
            result: #"{"status":"unsubscribed"}"#
        )
        let reassertedResume = try await waitForFakeAppServerRequest(
            transport,
            method: "thread/resume",
            after: messagesBeforeLateResponse
        )
        transportResponse(transport, id: reassertedResume.id, result: #"{"thread":\#(thread)}"#)

        let status = try await unsubscribe.value
        XCTAssertEqual(status, .unsubscribed)
        let requests = await transport.sentMessages().compactMap {
            try? decodeAppServerRequest($0)
        }
        XCTAssertEqual(requests.filter { $0.method == "thread/unsubscribe" }.count, 1)
        XCTAssertEqual(requests.filter { $0.method == "thread/resume" }.count, 3)
    }
}
