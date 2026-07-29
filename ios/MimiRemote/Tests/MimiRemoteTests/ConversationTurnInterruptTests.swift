import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testTurnInterruptUsesExpectedTurnWhenRuntimeCacheIsMissing() async throws {
        let project = AgentProject(
            id: "proj_interrupt_expected_turn",
            name: "Interrupt Expected Turn",
            path: "/tmp/interrupt-expected-turn"
        )
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            turnInterruptRecoveryDelaysNanoseconds: [],
            configProvider: {
                makeDirectAppServerConfig(
                    project: project,
                    allowedMethods: ["initialize", "initialized", "turn/interrupt"]
                )
            }
        )

        let interruptTask = Task {
            try await runtime.interruptActiveTurn(
                sessionID: "thr_interrupt_expected_turn",
                expectedTurnID: "turn_from_composer"
            )
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#
        )
        let interruptRequest = try await waitForFakeAppServerRequest(
            transport,
            method: "turn/interrupt",
            after: 1
        )
        XCTAssertEqual(
            interruptRequest.params?.objectValue?["threadId"]?.stringValue,
            "thr_interrupt_expected_turn"
        )
        XCTAssertEqual(
            interruptRequest.params?.objectValue?["turnId"]?.stringValue,
            "turn_from_composer"
        )
        transportResponse(transport, id: interruptRequest.id, result: #"{}"#)

        try await interruptTask.value
    }
}
