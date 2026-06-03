import XCTest
@testable import CodexAgentPad

final class CodexAppServerProtocolTests: XCTestCase {
    func testWireMessageClassifiesResponseNotificationAndServerRequest() throws {
        let decoder = JSONDecoder()

        let response = try decoder.decode(CodexAppServerMessage.self, from: Data(#"{"id":1,"result":{"ok":true}}"#.utf8))
        XCTAssertEqual(response, .response(CodexAppServerResponse(id: .int(1), result: .object(["ok": .bool(true)]), error: nil)))

        let notification = try decoder.decode(CodexAppServerMessage.self, from: Data(#"{"method":"turn/started","params":{"threadId":"t1"}}"#.utf8))
        XCTAssertEqual(notification, .notification(CodexAppServerNotification(method: "turn/started", params: .object(["threadId": .string("t1")]))))

        let serverRequest = try decoder.decode(CodexAppServerMessage.self, from: Data(#"{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"t1"}}"#.utf8))
        XCTAssertEqual(serverRequest, .serverRequest(CodexAppServerServerRequest(
            id: .string("approval-1"),
            method: "item/commandExecution/requestApproval",
            params: .object(["threadId": .string("t1")])
        )))
    }

    func testTurnStartBuilderUsesRemoteSafeDefaults() throws {
        let project = AgentProject(id: "repo", name: "Repo", path: "/Users/me/repo")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])
        let request = try builder.turnStart(
            threadID: "thread-1",
            projectID: "repo",
            prompt: "帮我看一下",
            clientMessageID: "client-1"
        )
        let params = try XCTUnwrap(request.params?.objectValue)
        XCTAssertEqual(request.method, "turn/start")
        XCTAssertEqual(params["cwd"]?.stringValue, "/Users/me/repo")
        XCTAssertEqual(params["approvalPolicy"]?.stringValue, "on-request")
        XCTAssertEqual(params["clientUserMessageId"]?.stringValue, "client-1")

        let sandbox = try XCTUnwrap(params["sandboxPolicy"]?.objectValue)
        XCTAssertEqual(sandbox["type"]?.stringValue, "workspaceWrite")
        XCTAssertEqual(sandbox["networkAccess"]?.boolValue, false)
        XCTAssertEqual(sandbox["writableRoots"]?.arrayValue?.first?.stringValue, "/Users/me/repo")
    }

    func testProjectorMapsAssistantDeltaAndCompletedItem() throws {
        let delta = CodexAppServerNotification(method: "item/agentMessage/delta", params: .object([
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "itemId": .string("item-1"),
            "delta": .string("hello")
        ]))
        var projector = CodexAppServerEventProjector()
        guard case .assistantDelta(let agentDelta, let metadata) = projector.project(delta) else {
            return XCTFail("expected assistant delta")
        }
        XCTAssertEqual(agentDelta.text, "hello")
        XCTAssertEqual(metadata.sessionID, "thread-1")
        XCTAssertEqual(metadata.messageID, "appserver:turn-1:item-1")

        let completed = CodexAppServerNotification(method: "item/completed", params: .object([
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "item": .object([
                "id": .string("item-1"),
                "type": .string("agentMessage"),
                "text": .string("hello world")
            ])
        ]))
        guard case .messageCompleted(let message, _) = projector.project(completed) else {
            return XCTFail("expected completed message")
        }
        XCTAssertEqual(message.id, "appserver:turn-1:item-1")
        XCTAssertEqual(message.sessionID, "thread-1")
        XCTAssertEqual(message.content, "hello world")
    }

    func testProjectorMapsApprovalServerRequest() throws {
        let request = CodexAppServerServerRequest(
            id: .int(9),
            method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("cmd-1"),
                "command": .string("go test ./..."),
                "reason": .string("验证改动")
            ])
        )
        var projector = CodexAppServerEventProjector()
        guard case .approvalRequest(let approval, let metadata) = projector.project(request) else {
            return XCTFail("expected approval request")
        }
        XCTAssertEqual(metadata.sessionID, "thread-1")
        XCTAssertEqual(approval.id, "cmd-1")
        XCTAssertEqual(approval.kind, "command")
        XCTAssertTrue(approval.title.contains("go test"))
        XCTAssertTrue(approval.body?.contains("验证改动") == true)
    }
}
