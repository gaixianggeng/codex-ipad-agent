import XCTest
@testable import MimiRemote

extension CodexAppServerProtocolTests {
    func testProjectorMapsLiveCollabReceiversWithoutUsingToolItemID() throws {
        let notification = CodexAppServerNotification(method: "item/completed", params: .object([
            "threadId": .string("parent-thread"),
            "turnId": .string("turn-1"),
            "item": .object([
                "id": .string("tool-item-is-not-thread"),
                "type": .string("collabAgentToolCall"),
                "tool": .string("review"),
                "receiverThreadIds": .array([
                    .string("child-a"),
                    .string("child-b"),
                    .string(" child-padded "),
                ]),
                "agentsStates": .object([
                    "child-a": .object([
                        "status": .string("running"),
                        "sessionId": .string("session-a"),
                        "canAcceptDirectInput": .bool(false),
                    ]),
                    "child-b": .object([
                        "status": .string("completed"),
                        "message": .string("done"),
                    ]),
                ]),
            ]),
        ]))

        var projector = CodexAppServerEventProjector()
        guard case .sessionContext(let context, let metadata) = projector.project(notification) else {
            return XCTFail("expected live session context")
        }
        XCTAssertEqual(metadata.sessionID, "parent-thread")
        XCTAssertEqual(context.subagents.map(\.id), ["child-a", "child-b"])
        XCTAssertFalse(context.subagents.contains { $0.id == "tool-item-is-not-thread" })
        XCTAssertFalse(context.subagents.contains { $0.id.contains("padded") })
        XCTAssertEqual(context.subagents[0].parentThreadID, "parent-thread")
        XCTAssertEqual(context.subagents[0].sessionID, "session-a")
        XCTAssertEqual(context.subagents[0].status, "running")
        XCTAssertEqual(context.subagents[0].canAcceptDirectInput, false)
        XCTAssertEqual(context.subagents[1].statusMessage, "done")
    }
}

@MainActor
extension ConversationDataFlowTests {
    func testSessionContextStoreMergesUpdatesAndAttachesSubagents() {
        let store = SessionContextStore()
        store.upsert(
            SessionContextSnapshot(
                sessionID: "thr_parent",
                threadID: "thr_parent",
                status: SessionContextStatus(type: "idle"),
                environment: SessionContextEnvironment(
                    id: "local",
                    kind: "local",
                    label: "本地",
                    cwd: "/tmp/parent",
                    provider: "openai"
                ),
                sources: [
                    SessionContextSource(
                        id: "session_source",
                        kind: "session",
                        label: "appServer"
                    ),
                ]
            ),
            fallbackSessionID: nil
        )
        store.upsert(
            SessionContextSnapshot(
                sessionID: "thr_parent",
                status: SessionContextStatus(
                    type: "active",
                    activeFlags: ["waitingOnApproval"]
                ),
                tasks: [
                    SessionContextTask(
                        id: "cmd_1",
                        kind: "command",
                        title: "go test ./...",
                        subtitle: "/tmp/parent",
                        status: "running"
                    ),
                ]
            ),
            fallbackSessionID: nil
        )
        store.upsert(
            SessionContextSnapshot(
                sessionID: "thr_child",
                threadID: "thr_child",
                subagents: [
                    SessionContextSubagent(
                        id: "thr_child",
                        parentThreadID: "thr_parent",
                        sessionID: "session_child",
                        nickname: "Noether",
                        role: "review",
                        status: "running",
                        canAcceptDirectInput: false
                    ),
                ]
            ),
            fallbackSessionID: nil
        )
        store.upsert(
            SessionContextSnapshot(
                sessionID: "thr_child",
                threadID: "thr_child",
                subagents: [
                    SessionContextSubagent(
                        id: "thr_child",
                        status: "completed",
                        statusMessage: "done",
                        canAcceptDirectInput: true
                    ),
                ]
            ),
            fallbackSessionID: nil
        )

        let parent = store.context(for: "thr_parent")
        XCTAssertEqual(parent?.status?.activeFlags, ["waitingOnApproval"])
        XCTAssertEqual(parent?.environment?.cwd, "/tmp/parent")
        XCTAssertEqual(parent?.tasks.first?.title, "go test ./...")
        XCTAssertEqual(parent?.subagents.first?.displayName, "Noether")
        XCTAssertEqual(parent?.subagents.first?.sessionID, "session_child")
        XCTAssertEqual(parent?.subagents.first?.status, "completed")
        XCTAssertEqual(parent?.subagents.first?.statusMessage, "done")
        XCTAssertEqual(parent?.subagents.first?.canAcceptDirectInput, false)
        XCTAssertEqual(
            store.context(for: "codex_thr_parent")?.subagents.first?.id,
            "thr_child"
        )
    }
}
