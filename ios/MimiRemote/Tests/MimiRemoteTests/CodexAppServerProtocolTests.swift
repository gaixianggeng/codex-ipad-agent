import XCTest
@testable import MimiRemote

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
        XCTAssertEqual(params["model"]?.stringValue, "gpt-5.5")
        XCTAssertEqual(params["effort"]?.stringValue, "xhigh")
        XCTAssertEqual(params["approvalPolicy"]?.stringValue, "on-request")
        XCTAssertEqual(params["clientUserMessageId"]?.stringValue, "client-1")

        let sandbox = try XCTUnwrap(params["sandboxPolicy"]?.objectValue)
        XCTAssertEqual(sandbox["type"]?.stringValue, "dangerFullAccess")
        XCTAssertEqual(sandbox["networkAccess"]?.boolValue, false)
        XCTAssertNil(sandbox["writableRoots"])
    }

    func testTurnStartBuilderAddsCollaborationModeOnlyForPlanMode() throws {
        let project = AgentProject(id: "repo", name: "Repo", path: "/Users/me/repo")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])

        var planOptions = CodexAppServerTurnOptions.default
        planOptions.model = "gpt-5-codex"
        planOptions.reasoningEffort = .high
        planOptions.collaborationMode = .plan
        planOptions.planGuidanceEnabled = true
        let planPayload = CodexAppServerTurnPayload(prompt: "先做方案", options: planOptions)
        let planRequest = try builder.turnStart(threadID: "thread-1", projectID: project.id, payload: planPayload)
        let planParams = try XCTUnwrap(planRequest.params?.objectValue)
        let collaborationMode = try XCTUnwrap(planParams["collaborationMode"]?.objectValue)
        XCTAssertEqual(collaborationMode["mode"]?.stringValue, "plan")
        let settings = try XCTUnwrap(collaborationMode["settings"]?.objectValue)
        XCTAssertEqual(settings["model"]?.stringValue, "gpt-5-codex")
        XCTAssertEqual(settings["reasoning_effort"]?.stringValue, "high")
        XCTAssertEqual(settings["developer_instructions"], .null)

        let standardPayload = CodexAppServerTurnPayload(prompt: "直接做", options: .default)
        let standardRequest = try builder.turnStart(threadID: "thread-1", projectID: project.id, payload: standardPayload)
        XCTAssertNil(standardRequest.params?.objectValue?["collaborationMode"])
    }

    func testTurnSteerBuilderUsesActiveTurnPreconditionWithoutStartOptions() throws {
        let project = AgentProject(id: "repo", name: "Repo", path: "/Users/me/repo")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])
        var options = CodexAppServerTurnOptions.default
        options.collaborationMode = .plan
        options.model = "gpt-5-codex"

        let payload = CodexAppServerTurnPayload(prompt: "这条直接引导当前回复", options: options)
        let request = try builder.turnSteer(
            threadID: "thread-1",
            cwd: project.path,
            payload: payload,
            clientMessageID: "client-steer",
            expectedTurnID: "turn-active"
        )
        let params = try XCTUnwrap(request.params?.objectValue)

        XCTAssertEqual(request.method, "turn/steer")
        XCTAssertEqual(params["threadId"]?.stringValue, "thread-1")
        XCTAssertEqual(params["clientUserMessageId"]?.stringValue, "client-steer")
        XCTAssertEqual(params["expectedTurnId"]?.stringValue, "turn-active")
        XCTAssertEqual(params["input"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "这条直接引导当前回复")
        XCTAssertNil(params["cwd"])
        XCTAssertNil(params["collaborationMode"])
        XCTAssertNil(params["model"])
        XCTAssertNil(params["approvalPolicy"])
    }

    func testRequestBuilderForwardsStructuredInputAndAdvancedOptions() throws {
        let project = AgentProject(id: "repo", name: "Repo", path: "/Users/me/repo")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])
        var options = CodexAppServerTurnOptions.default
        options.model = "gpt-5-codex"
        options.modelProvider = "openai"
        options.serviceTier = "priority"
        options.reasoningEffort = .high
        options.reasoningSummary = .detailed
        options.approvalPolicy = .onFailure
        options.sandboxMode = .readOnly
        options.personality = .friendly
        options.config = .object(["feature": .bool(true)])
        options.baseInstructions = "base"
        options.developerInstructions = "dev"
        options.outputSchema = .object(["type": .string("object")])
        options.serviceName = "ios"
        options.sessionStartSource = "ipad"
        options.threadSource = "user"

        let threadStart = try builder.threadStart(projectID: project.id, options: options)
        let threadParams = try XCTUnwrap(threadStart.params?.objectValue)
        XCTAssertEqual(threadParams["model"]?.stringValue, "gpt-5-codex")
        XCTAssertEqual(threadParams["modelProvider"]?.stringValue, "openai")
        XCTAssertEqual(threadParams["serviceTier"]?.stringValue, "priority")
        XCTAssertEqual(threadParams["approvalPolicy"]?.stringValue, "on-failure")
        XCTAssertEqual(threadParams["sandbox"]?.stringValue, "read-only")
        XCTAssertEqual(threadParams["config"]?.objectValue?["feature"]?.boolValue, true)
        XCTAssertEqual(threadParams["baseInstructions"]?.stringValue, "base")
        XCTAssertEqual(threadParams["developerInstructions"]?.stringValue, "dev")
        XCTAssertEqual(threadParams["serviceName"]?.stringValue, "ios")

        let payload = CodexAppServerTurnPayload(input: [
            .text("看图并检查引用"),
            .image(url: "data:image/png;base64,AA==", detail: .high),
            .localImage(path: "/Users/me/repo/screens/a.png", detail: .original),
            .skill(name: "review", path: "/Users/me/.codex/skills/review/SKILL.md"),
            .mention(name: "README", path: "/Users/me/repo/README.md")
        ], options: options)
        let turnStart = try builder.turnStart(threadID: "thread-1", projectID: project.id, payload: payload, clientMessageID: "client-rich")
        let turnParams = try XCTUnwrap(turnStart.params?.objectValue)
        XCTAssertEqual(turnParams["model"]?.stringValue, "gpt-5-codex")
        XCTAssertEqual(turnParams["serviceTier"]?.stringValue, "priority")
        XCTAssertEqual(turnParams["effort"]?.stringValue, "high")
        XCTAssertEqual(turnParams["summary"]?.stringValue, "detailed")
        XCTAssertEqual(turnParams["approvalPolicy"]?.stringValue, "on-failure")
        XCTAssertEqual(turnParams["clientUserMessageId"]?.stringValue, "client-rich")
        XCTAssertNil(turnParams["modelProvider"])
        XCTAssertNil(turnParams["config"])
        XCTAssertNil(turnParams["baseInstructions"])
        let input = try XCTUnwrap(turnParams["input"]?.arrayValue)
        XCTAssertEqual(input.count, 5)
        XCTAssertEqual(input[0].objectValue?["type"]?.stringValue, "text")
        XCTAssertEqual(input[1].objectValue?["detail"]?.stringValue, "high")
        XCTAssertEqual(input[2].objectValue?["path"]?.stringValue, "/Users/me/repo/screens/a.png")
        XCTAssertEqual(input[3].objectValue?["name"]?.stringValue, "review")
        XCTAssertEqual(input[3].objectValue?["path"]?.stringValue, "/Users/me/.codex/skills/review/SKILL.md")
        let sandbox = try XCTUnwrap(turnParams["sandboxPolicy"]?.objectValue)
        XCTAssertEqual(sandbox["type"]?.stringValue, "readOnly")
        XCTAssertEqual(sandbox["networkAccess"]?.boolValue, false)
    }

    func testRequestBuilderAllowsFullAccessSandboxWithApproval() throws {
        let project = AgentProject(id: "repo", name: "Repo", path: "/Users/me/repo")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])
        var options = CodexAppServerTurnOptions.default
        options.sandboxMode = .dangerFullAccess

        let threadStart = try builder.threadStart(projectID: project.id, options: options)
        let threadParams = try XCTUnwrap(threadStart.params?.objectValue)
        XCTAssertEqual(threadParams["approvalPolicy"]?.stringValue, "on-request")
        XCTAssertEqual(threadParams["sandbox"]?.stringValue, "danger-full-access")

        let payload = CodexAppServerTurnPayload(prompt: "hi", options: options)
        let turnStart = try builder.turnStart(
            threadID: "thread-1",
            projectID: project.id,
            payload: payload,
            clientMessageID: nil
        )
        let turnParams = try XCTUnwrap(turnStart.params?.objectValue)
        let sandbox = try XCTUnwrap(turnParams["sandboxPolicy"]?.objectValue)
        XCTAssertEqual(turnParams["approvalPolicy"]?.stringValue, "on-request")
        XCTAssertEqual(sandbox["type"]?.stringValue, "dangerFullAccess")
        XCTAssertEqual(sandbox["networkAccess"]?.boolValue, false)
    }

    func testModelListBuilderAndFlexibleParser() throws {
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [])
        let request = builder.modelList()
        XCTAssertEqual(request.method, "model/list")
        XCTAssertEqual(request.params?.objectValue, [:])

        let parsed = CodexAppServerModelOption.parseListResult(.object([
            "models": .array([
                .string("gpt-5-codex"),
                .object([
                    "id": .string("gpt-5.1-codex"),
                    "label": .string("GPT-5.1 Codex"),
                    "provider": .string("openai"),
                    "isDefault": .bool(true)
                ]),
                .object([
                    "model": .string("gpt-5"),
                    "description": .string("general")
                ]),
                .object([
                    "model": .string("gpt-5"),
                    "provider": .string("azure")
                ])
            ])
        ]))

        XCTAssertEqual(parsed.first?.model, "gpt-5.1-codex")
        XCTAssertEqual(Set(parsed.map(\.id)), ["gpt-5.1-codex@openai", "gpt-5", "gpt-5@azure", "gpt-5-codex"])
        XCTAssertEqual(parsed.first?.title, "GPT-5.1 Codex")
        XCTAssertEqual(parsed.first?.provider, "openai")
        XCTAssertEqual(parsed.first?.isDefault, true)
    }

    func testRequestBuilderBuildsThreadGoalRequests() throws {
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [])

        let get = builder.threadGoalGet(threadID: "thread-1")
        XCTAssertEqual(get.method, "thread/goal/get")
        XCTAssertEqual(get.params?.objectValue?["threadId"]?.stringValue, "thread-1")

        let set = builder.threadGoalSet(
            threadID: "thread-1",
            objective: "ship ipad goal",
            status: .active,
            tokenBudget: 50_000
        )
        let setParams = try XCTUnwrap(set.params?.objectValue)
        XCTAssertEqual(set.method, "thread/goal/set")
        XCTAssertEqual(setParams["threadId"]?.stringValue, "thread-1")
        XCTAssertEqual(setParams["objective"]?.stringValue, "ship ipad goal")
        XCTAssertEqual(setParams["status"]?.stringValue, "active")
        XCTAssertEqual(setParams["tokenBudget"]?.intValue, 50_000)

        let clear = builder.threadGoalClear(threadID: "thread-1")
        XCTAssertEqual(clear.method, "thread/goal/clear")
        XCTAssertEqual(clear.params?.objectValue?["threadId"]?.stringValue, "thread-1")
    }

    func testRequestBuilderRejectsUnsafeStructuredInputAndOptions() throws {
        let project = AgentProject(id: "repo", name: "Repo", path: "/Users/me/repo")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])

        XCTAssertThrowsError(try builder.turnStart(
            threadID: "thread-1",
            projectID: project.id,
            payload: CodexAppServerTurnPayload(input: [.image(url: "file:///Users/me/repo/a.png")])
        ))

        XCTAssertThrowsError(try builder.turnStart(
            threadID: "thread-1",
            projectID: project.id,
            payload: CodexAppServerTurnPayload(input: [.localImage(path: "/Users/me/other/a.png")])
        ))

        XCTAssertThrowsError(try builder.turnStart(
            threadID: "thread-1",
            projectID: project.id,
            payload: CodexAppServerTurnPayload(input: [.localImage(path: "/Users/me/repo/../other/a.png")])
        ))

        var unsafe = CodexAppServerTurnOptions.default
        unsafe.networkAccess = true
        XCTAssertThrowsError(try builder.turnStart(
            threadID: "thread-1",
            projectID: project.id,
            payload: CodexAppServerTurnPayload(input: [.text("hi")], options: unsafe)
        ))

        var unsafeConfig = CodexAppServerTurnOptions.default
        unsafeConfig.config = .object(["approval_policy": .string("never")])
        XCTAssertThrowsError(try builder.threadStart(projectID: project.id, options: unsafeConfig))

        unsafeConfig.config = .object(["sandbox_mode": .string("danger-full-access")])
        XCTAssertThrowsError(try builder.threadStart(projectID: project.id, options: unsafeConfig))

        unsafeConfig.config = .object(["network_access": .bool(true)])
        XCTAssertThrowsError(try builder.threadStart(projectID: project.id, options: unsafeConfig))
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

    func testProjectorMapsUserInputServerRequestSeparatelyFromApproval() throws {
        let request = CodexAppServerServerRequest(
            id: .string("request-1"),
            method: "item/tool/requestUserInput",
            params: .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("input-1"),
                "questions": .array([
                    .object([
                        "id": .string("scope"),
                        "header": .string("范围"),
                        "question": .string("先做哪一部分？"),
                        "isOther": .bool(true),
                        "isSecret": .bool(false),
                        "options": .array([
                            .object(["label": .string("后端"), "description": .string("先落 API")])
                        ])
                    ])
                ])
            ])
        )
        var projector = CodexAppServerEventProjector()
        guard case .userInputRequest(let userInput, let metadata) = projector.project(request) else {
            return XCTFail("expected user input request")
        }
        XCTAssertEqual(metadata.sessionID, "thread-1")
        XCTAssertEqual(userInput.id, "input-1")
        XCTAssertEqual(userInput.questions.first?.id, "scope")
        XCTAssertEqual(userInput.questions.first?.options.first?.label, "后端")
    }

    func testProjectorMapsThreadGoalNotifications() throws {
        var projector = CodexAppServerEventProjector()
        let updated = CodexAppServerNotification(method: "thread/goal/updated", params: .object([
            "threadId": .string("thread-1"),
            "goal": .object([
                "threadId": .string("thread-1"),
                "objective": .string("完成 iPad 目标功能"),
                "status": .string("active"),
                "tokenBudget": .int(80_000),
                "tokensUsed": .int(12_000),
                "timeUsedSeconds": .int(360)
            ])
        ]))

        guard case .goalUpdated(let goal, let metadata) = projector.project(updated) else {
            return XCTFail("expected goal updated")
        }
        XCTAssertEqual(metadata.sessionID, "thread-1")
        XCTAssertEqual(goal.threadID, "thread-1")
        XCTAssertEqual(goal.objective, "完成 iPad 目标功能")
        XCTAssertEqual(goal.status, .active)
        XCTAssertEqual(goal.tokenBudget, 80_000)
        XCTAssertEqual(goal.tokensUsed, 12_000)
        XCTAssertEqual(goal.timeUsedSeconds, 360)

        let cleared = CodexAppServerNotification(method: "thread/goal/cleared", params: .object([
            "threadId": .string("thread-1")
        ]))
        guard case .goalCleared(let clearMetadata) = projector.project(cleared) else {
            return XCTFail("expected goal cleared")
        }
        XCTAssertEqual(clearMetadata.sessionID, "thread-1")
    }
}
