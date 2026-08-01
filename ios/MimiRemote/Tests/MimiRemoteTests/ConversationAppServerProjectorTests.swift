import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testCodexAppServerProjectorKeepsLiveToolActionAndLifecycleSemantics() throws {
        var projector = CodexAppServerEventProjector()

        let started = try decodeAppServerNotification(#"{"method":"item/started","params":{"threadId":"thr_tools","turnId":"turn_tools","item":{"type":"dynamicToolCall","id":"task_list","namespace":"codex_app","tool":"list_threads"}}}"#)
        guard case .processItemCompleted(let runningMessage, let runningContext, let runningMetadata) = try XCTUnwrap(projector.project(started)) else {
            return XCTFail("Tool started 应立即投影为可见过程行")
        }
        XCTAssertEqual(runningMessage.activityPayload?.displayTitle, L10n.text("ui.query_task_list"))
        XCTAssertEqual(runningMessage.activityPayload?.displayStatusText, L10n.text("ui.in_progress"))
        XCTAssertEqual(runningMessage.activityPayload?.toolPresentationKind, .independentTaskQuery)
        XCTAssertEqual(runningContext?.tasks.first?.status, "inProgress")

        let completed = try decodeAppServerNotification(#"{"method":"item/completed","params":{"threadId":"thr_tools","turnId":"turn_tools","item":{"type":"dynamicToolCall","id":"task_list","namespace":"codex_app","tool":"list_threads","status":"completed"}}}"#)
        guard case .processItemCompleted(let completedMessage, _, let completedMetadata) = try XCTUnwrap(projector.project(completed)) else {
            return XCTFail("Tool completed 应原位更新过程行")
        }
        XCTAssertEqual(completedMessage.id, runningMessage.id)
        XCTAssertEqual(completedMetadata.messageID, runningMetadata.messageID)
        XCTAssertEqual(completedMessage.activityPayload?.displayStatusText, L10n.text("ui.completed_status"))

        let terminalCases: [(id: String, tool: String, status: String, statusKey: String)] = [
            ("task_start", "create_thread", "failed", "ui.failed_status"),
            ("task_wait", "wait_threads", "timed_out", "ui.timed_out_status"),
            ("task_resume", "send_message_to_thread", "interrupted", "ui.interrupted_status"),
        ]
        for terminalCase in terminalCases {
            let event = try decodeAppServerNotification(
                #"{"method":"item/completed","params":{"threadId":"thr_tools","turnId":"turn_tools","item":{"type":"dynamicToolCall","id":"\#(terminalCase.id)","namespace":"codex_app","tool":"\#(terminalCase.tool)","status":"\#(terminalCase.status)"}}}"#
            )
            guard case .processItemCompleted(let message, _, _) = try XCTUnwrap(projector.project(event)) else {
                return XCTFail("Expected visible \(terminalCase.tool) event")
            }
            XCTAssertEqual(message.activityPayload?.displayStatusText, L10n.text(terminalCase.statusKey))
            XCTAssertTrue(message.activityPayload?.accessibilityDescription.contains(L10n.text(terminalCase.statusKey)) == true)
            XCTAssertNotEqual(message.activityPayload?.displayTitle, L10n.text("ui.call_tool"))
        }
    }
}
